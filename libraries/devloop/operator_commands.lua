local entity_lib = require("devloop.entity")
local devloop_state = require("devloop.state")
local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local parsers_misc = require("devloop.parsers.misc")
local C = {}
local strings = require("contract.strings")
local transition_version = require("contract.transition_version")
local forge_validators = require("devloop.forge_validators")
local devloop_logging = require("devloop.logging")
local source_refs = require("contract.source_ref")
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local conv_reconcile = require("devloop.convergence.reconcile")
local marker_facts = require("devloop.markers.facts")
local pr_partition = require("devloop.restart.issue.pr_partition_contract")

local ai_sentinel = "⟦AI:FKST⟧"
local rereview_state_modes = {
  blocked = "direct",
  ["review-meta"] = "direct",
  reviewing = "stall-required",
}
local output_obligation_command_pattern = "<!%-%- fkst:github%-devloop%-ops:output%-obligation%-command:v1.-%-%->"
local output_obligation_escalation_pattern = "<!%-%- fkst:github%-devloop%-ops:output%-obligation%-escalation:v1.-%-%->"
local output_obligation_source_routes = {
  blocked = "blocked",
}

local function command_key(comment, fallback_index)
  if type(comment) == "table" and comment.id ~= nil and tostring(comment.id) ~= "" then
    return base_ids.dedup_key({
      "operator-command",
      tostring(comment.id),
    })
  end
  local created = parsers_misc._comment_created_at(comment) or "unknown-time"
  local author = parsers_misc._comment_author_login(comment) or "unknown-author"
  return base_ids.dedup_key({
    "operator-command",
    tostring(author),
    tostring(created),
    tostring(fallback_index or 0),
    parsers_misc._comment_body(comment),
  })
end

local function first_command_line(body)
  for line in tostring(body or ""):gmatch("[^\r\n]+") do
    local trimmed = strings.trim(line):lower()
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

local function marker_attr(marker, name)
  return tostring(marker or ""):match(tostring(name) .. '="([^"]*)"')
end

local function parse_output_obligation_command(body, command)
  local found = nil
  for marker in tostring(body or ""):gmatch(output_obligation_command_pattern) do
    if found ~= nil then
      return { invalid = true }
    end
    found = marker
  end
  if found == nil then
    return nil
  end
  local decision = marker_attr(found, "decision")
  local escalation_dedup = marker_attr(found, "escalation_dedup")
  local terminal_version = marker_attr(found, "terminal_version")
  local pr_number = marker_attr(found, "pr")
  local head_sha = marker_attr(found, "head_sha")
  local target_version = marker_attr(found, "target_version")
  if command ~= "rereview"
    or decision ~= "rereview"
    or not strings.is_bounded_string(escalation_dedup, devloop_base._max_dedup_len)
    or not strings.is_bounded_string(terminal_version, devloop_base._max_dedup_len)
    or not forge_validators.is_positive_pr_number(pr_number)
    or not forge_validators.is_git_sha(head_sha)
    or not strings.is_bounded_string(target_version, devloop_base._max_dedup_len) then
    return { invalid = true }
  end
  return {
    invalid = false,
    decision = decision,
    escalation_dedup = escalation_dedup,
    terminal_version = terminal_version,
    pr_number = tonumber(pr_number),
    head_sha = head_sha,
    target_version = target_version,
  }
end

local function output_obligation_command_key(authority)
  if type(authority) ~= "table" or authority.invalid == true then
    return nil
  end
  local parts = {
    "operator-command",
    "output-obligation",
    authority.escalation_dedup,
    authority.terminal_version,
    authority.decision,
  }
  table.insert(parts, authority.pr_number)
  table.insert(parts, authority.head_sha)
  table.insert(parts, authority.target_version)
  return base_ids.dedup_key(parts)
end

local function parse_command(body)
  local line = first_command_line(body)
  local command = line:match("^fkst:%s*([%w_-]+)")
  if command == "rereview" or command == "reready" or command == "reimplement" then
    return {
      command = command,
      output_obligation = parse_output_obligation_command(body, command),
    }
  end
  if command == "dependency-waiver" then
    local number = tonumber(line:match("^fkst:%s*dependency%-waiver%s+(%d+)%s*$") or "")
    if forge_validators.is_positive_pr_number(number) then
      return {
        command = command,
        blocker_number = math.floor(number),
      }
    end
  end
  return nil
end

function C.operator_command_fact(comments, command_name, expected_key)
  if type(comments) ~= "table" then
    return nil
  end
  local latest = nil
  for index, comment in ipairs(comments) do
    local parsed = parse_command(parsers_misc._comment_body(comment))
    if parsed ~= nil and parsed.command == command_name then
      if parsers_misc._is_trusted_comment(comment) then
        local key = output_obligation_command_key(parsed.output_obligation)
          or command_key(comment, index)
        if expected_key == nil or key == tostring(expected_key) then
          latest = {
            command = parsed.command,
            key = key,
            author_login = parsers_misc._comment_author_login(comment),
            created_at = parsers_misc._comment_created_at(comment),
            body = parsers_misc._comment_body(comment),
            blocker_number = parsed.blocker_number,
            output_obligation = parsed.output_obligation,
          }
        end
      else
        devloop_logging.log_line("info", "operator_command", "IGNORED", {
          "command=" .. tostring(parsed.command),
          "reason=untrusted-author",
          "ignored_author=" .. tostring(parsers_misc._comment_author_login(comment) or ""),
          "trusted_bot=" .. tostring(parsers_misc.trusted_bot_login()),
        })
      end
    end
  end
  return latest
end

function C.operator_rereview_version(current_version, head_sha)
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop: operator-rereview-head-sha-invalid: invalid operator rereview head sha")
  end
  return transition_version.next_rereview(current_version, head_sha)
end

local function is_stalled_reviewing(current_pr, origin, pr_number, state)
  if state.state ~= "reviewing" or not forge_validators.is_git_sha(current_pr.head_sha) then
    return false
  end
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    origin.repo,
    pr_number,
    state.version,
    current_pr.head_sha
  )
  local review_version = transition_version.safe_version_segment(state.version)
  local sr_digest = convergence_shared.source_ref_digest(entity_lib.pr_source_ref(origin.repo, pr_number))
  local facts = conv_rounds.review_converge_round_facts_for_heartbeat(
    current_pr.comments,
    review_proposal_id,
    origin.proposal_id,
    review_version,
    current_pr.head_sha,
    sr_digest
  )
  local round = conv_rounds.max_converge_round(facts)
  return conv_rounds.is_true_stall(facts, round)
end

function C.rereview_precondition(current_pr, origin, pr_number, state)
  if type(current_pr) ~= "table" or type(origin) ~= "table" or type(state) ~= "table" then
    return false, "invalid-state"
  end
  local state_mode = rereview_state_modes[state.state]
  if state_mode == nil then
    return false, "invalid-state"
  end
  if state_mode == "stall-required"
    and not is_stalled_reviewing(current_pr, origin, pr_number, state) then
    return false, "active-reviewing"
  end
  if tostring(current_pr.state or ""):lower() ~= "open" then
    return false, "pr-closed"
  end
  if not forge_validators.is_git_sha(current_pr.head_sha) then
    return false, "head-missing"
  end
  return true, "ok"
end

function C.output_obligation_rereview_command_precondition(command, pr_number, current_pr, state)
  local authority = type(command) == "table" and command.output_obligation or nil
  if authority == nil then
    return true, "ok", nil
  end
  if authority.invalid == true
    or authority.decision ~= "rereview"
    or tostring(authority.pr_number or "") ~= tostring(pr_number or "")
    or authority.head_sha ~= tostring(current_pr and current_pr.head_sha or "")
    or not forge_validators.is_git_sha(authority.head_sha)
    or not strings.is_bounded_string(authority.target_version, devloop_base._max_dedup_len) then
    return false, "command-authority-changed", nil
  end
  local expected_version = C.operator_rereview_version(state and state.version, authority.head_sha)
  if authority.target_version ~= expected_version then
    return false, "command-authority-changed", nil
  end
  return true, "ok", authority.target_version
end

local function output_obligation_pr_state_routes()
  local routes = {}
  for _, state in ipairs(pr_partition.pr_phase_states()) do
    routes[state] = {
      kind = "phase",
      recovery = "active",
      state = state,
    }
  end
  for _, state in ipairs(pr_partition.pr_terminal_states()) do
    routes[state] = {
      kind = "terminal",
      recovery = "quiescent",
      state = state,
    }
  end
  routes.blocked.recovery = "rereview"
  routes["review-meta"].recovery = "rereview"
  routes.reviewing.recovery = "rereview"
  return routes
end

local output_obligation_pr_routes = output_obligation_pr_state_routes()

local function same_source_ref(left, right)
  local ok_left, normalized_left = pcall(base_ids.normalize_source_ref, left)
  local ok_right, normalized_right = pcall(base_ids.normalize_source_ref, right)
  return ok_left
    and ok_right
    and normalized_left.kind == normalized_right.kind
    and normalized_left.ref == normalized_right.ref
end

function C.output_obligation_source_lineage_fact(fact, source_issue)
  if not same_source_ref(source_issue and source_issue.source_ref, fact and fact.source_ref) then
    return nil
  end
  local allowed_from_states = {}
  for _, state in ipairs(devloop_state.lifecycle_state_order()) do
    if #devloop_state.state_successors(state) > 0 then
      allowed_from_states[state] = true
    end
  end
  local source_fact = conv_reconcile.timeout_reconcile_fact_for_terminal_version_from_states(
    source_issue.comments,
    fact.proposal_id,
    fact.terminal_version,
    allowed_from_states
  )
  if source_fact == nil
    or source_fact.reason_class ~= fact.reason_class
    or not same_source_ref(source_fact.source_ref, fact.source_ref) then
    return nil
  end
  return source_fact
end

function C.output_obligation_current_source_terminal_matches(fact, source_issue)
  local current = devloop_state.route_current(
    source_issue and source_issue.comments,
    fact and fact.proposal_id,
    output_obligation_source_routes
  )
  return current.route == "blocked"
    and tostring(current.version or "") == tostring(fact and fact.terminal_version or "")
end

function C.output_obligation_linked_pr_generation(source_fact, row)
  local link = type(row) == "table" and row.link or nil
  local _, proposal_pr_number = entity_lib.parse_pr_proposal_id(link and link.pr_proposal_id)
  if type(link) ~= "table"
    or link.kind ~= "delegation"
    or not forge_validators.is_positive_pr_number(row.number)
    or not forge_validators.is_positive_pr_number(link.pr_number)
    or tostring(link.pr_number) ~= tostring(row.number)
    or tostring(proposal_pr_number or "") ~= tostring(row.number) then
    return nil, "linked-pr-incoherent"
  end
  if tostring(link.version or "") ~= tostring(source_fact and source_fact.from_version or "") then
    return "other", nil
  end
  return "same", nil
end

function C.output_obligation_coherent_pr(fact, row)
  local current_pr = type(row) == "table" and row.current or nil
  local link = type(row) == "table" and row.link or nil
  if type(current_pr) ~= "table" or type(link) ~= "table" then
    return nil, "linked-pr-incoherent"
  end
  local origin = marker_facts.pr_origin_fact(current_pr.comments)
  local routed = devloop_state.route_current(current_pr.comments, fact.proposal_id, output_obligation_pr_routes)
  local route = routed.route
  if origin == nil
    or origin.proposal_id ~= fact.proposal_id
    or origin.repo ~= fact.source_repo
    or tostring(origin.issue_number or "") ~= tostring(fact.source_issue_number or "")
    or tostring(link.version or "") ~= tostring(origin.impl_version or "")
    or tostring(link.pr_proposal_id or "") ~= entity_lib.pr_proposal_id(fact.source_repo, row.number)
    or tostring(current_pr.head_ref_name or "") ~= tostring(origin.branch or "")
    or tostring(current_pr.base_ref_name or "") ~= tostring(origin.base_branch or "")
    or tostring(current_pr.head_repository or ""):lower() ~= tostring(fact.source_repo or ""):lower()
    or current_pr.is_cross_repository == true
    or not forge_validators.is_git_sha(current_pr.head_sha)
    or type(route) ~= "table" then
    return nil, "linked-pr-incoherent"
  end
  return {
    row = row,
    origin = origin,
    current = {
      state = route.state,
      version = routed.version,
      marker_created_at = routed.marker_created_at,
    },
    route = route,
    current_pr = current_pr,
  }, nil
end

function C.output_obligation_same_lineage_prs_quiescent(fact, source_fact, snapshot, excluded_pr_number)
  for _, row in ipairs(snapshot and snapshot.prs or {}) do
    local generation, generation_reason = C.output_obligation_linked_pr_generation(source_fact, row)
    if generation == nil then
      return false, generation_reason
    end
    if generation == "same" and tostring(row.number) ~= tostring(excluded_pr_number or "") then
      local coherent, reason = C.output_obligation_coherent_pr(fact, row)
      if coherent == nil then
        return false, reason
      end
      if coherent.route.kind == "phase" then
        return false, "linked-pr-active"
      end
      if coherent.route.kind ~= "terminal" then
        return false, "linked-pr-incoherent"
      end
    end
  end
  return true, nil
end

function C.output_obligation_live_command_authorization(fact, source_issue, snapshot, source_fact)
  if not C.output_obligation_current_source_terminal_matches(fact, source_issue) then
    return nil, "source-terminal-changed"
  end
  local target = nil
  local active = false
  for _, row in ipairs(snapshot and snapshot.prs or {}) do
    local generation, generation_reason = C.output_obligation_linked_pr_generation(source_fact, row)
    if generation == nil then
      return nil, generation_reason
    end
    if generation == "same" then
      local coherent, reason = C.output_obligation_coherent_pr(fact, row)
      if coherent == nil then
        return nil, reason
      end
      local admissible = false
      if coherent.route.recovery == "rereview" then
        admissible = C.rereview_precondition(
          coherent.current_pr,
          coherent.origin,
          row.number,
          coherent.current
        )
      end
      if admissible then
        if target ~= nil then
          return nil, "multiple-rereview-targets"
        end
        target = coherent
      elseif coherent.route.kind == "phase" then
        active = true
      elseif coherent.route.kind ~= "terminal" then
        return nil, "linked-pr-incoherent"
      end
    end
  end
  if active then
    return nil, "linked-pr-active"
  end
  if target ~= nil then
    return {
      decision = "rereview",
      target = target,
      target_version = C.operator_rereview_version(
        target.current.version,
        target.current_pr.head_sha
      ),
    }, nil
  end
  return {
    decision = "lineage-not-planned",
    kind = "not_planned",
    reason = "source-lineage-abandoned-no-live-pr",
  }, nil
end

function C.source_refs_match(left, right, limit)
  if not source_refs.has_bounded_source_ref(left, limit or devloop_base._max_key_len)
    or not source_refs.has_bounded_source_ref(right, limit or devloop_base._max_key_len) then
    return false
  end
  return tostring(left.kind) == tostring(right.kind)
    and tostring(left.ref) == tostring(right.ref)
end

function C.operator_command_response_fact(comments, command)
  if type(comments) ~= "table" or type(command) ~= "table" then
    return nil
  end
  local marker = '<!-- fkst:github-devloop:operator-command:v1 command="'
    .. tostring(command.command)
    .. '" key="' .. tostring(command.key)
    .. '"'
  local latest = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for candidate in parsers_misc._comment_body(comment):gmatch("<!%-%- fkst:github%-devloop:operator%-command:v1.-%-%->") do
      if candidate:find(marker, 1, true) ~= nil then
        latest = {
          outcome = candidate:match(' outcome="([^"]+)"'),
          reason = candidate:match(' reason="([^"]+)"'),
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
      end
    end
  end
  return latest
end

function C.has_operator_command_response(comments, command)
  return C.operator_command_response_fact(comments, command) ~= nil
end

function C.operator_command_response_count(comments, command_name, outcome, reason)
  if type(comments) ~= "table" then
    return 0
  end
  local count = 0
  local prefix = '<!-- fkst:github-devloop:operator-command:v1 command="'
    .. tostring(command_name)
    .. '" '
  local outcome_attr = outcome ~= nil and ('outcome="' .. tostring(outcome) .. '"') or nil
  local reason_attr = reason ~= nil
    and ('reason="' .. strings.sanitize_key(reason, false):gsub("/", "-") .. '"')
    or nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch("<!%-%- fkst:github%-devloop:operator%-command:v1.-%-%->") do
      if marker:find(prefix, 1, true) ~= nil
        and (outcome_attr == nil or marker:find(outcome_attr, 1, true) ~= nil)
        and (reason_attr == nil or marker:find(reason_attr, 1, true) ~= nil) then
        count = count + 1
      end
    end
  end
  return count
end

function C.operator_command_marker(command, outcome, reason)
  if type(command) ~= "table"
    or (command.command ~= "rereview"
      and command.command ~= "reready"
      and command.command ~= "reimplement"
      and command.command ~= "dependency-waiver") then
    error("github-devloop: operator-command-marker-invalid: invalid operator command marker")
  end
  if outcome ~= "applied" and outcome ~= "refused" then
    error("github-devloop: operator-command-outcome-invalid: invalid operator command outcome")
  end
  local safe_reason = strings.sanitize_key(reason or outcome, false):gsub("/", "-")
  return '<!-- fkst:github-devloop:operator-command:v1 command="' .. tostring(command.command)
    .. '" key="' .. tostring(command.key)
    .. '" outcome="' .. tostring(outcome)
    .. '" reason="' .. tostring(safe_reason)
    .. '" -->'
end

function C.build_operator_issue_rereview_comment_request(repo, issue_number, command, proposal, source_ref)
  local marker = C.operator_command_marker(command, "applied", "rereview")
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command accepted: rereview"
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "applied",
    tostring(proposal and proposal.dedup_key or ""),
  }), source_ref)
end

function C.build_operator_issue_reready_comment_request(repo, issue_number, command, outcome_reason, source_ref)
  local marker = C.operator_command_marker(command, "applied", outcome_reason or "reready")
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command accepted: reready"
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "applied",
    tostring(outcome_reason or "reready"),
  }), source_ref)
end

function C.build_operator_issue_reimplement_comment_request(repo, issue_number, command, attempt, source_ref)
  local marker = C.operator_command_marker(command, "applied", "reimplement")
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command accepted: reimplement"
    .. "\n\nRetry attempt: " .. tostring(attempt)
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "applied",
    "reimplement",
    tostring(attempt),
  }), source_ref)
end

function C.build_operator_issue_dependency_waiver_comment_request(dependency_waiver_marker, repo, issue_number, command, proposal_id, version, blocker_number, source_ref)
  local waiver_marker = dependency_waiver_marker(proposal_id, version, blocker_number, "operator-waiver")
  local command_marker = C.operator_command_marker(command, "applied", "dependency-waiver")
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command accepted: dependency-waiver"
    .. "\n\n" .. waiver_marker
    .. "\n" .. command_marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "applied",
    "dependency-waiver",
    tostring(version),
    tostring(blocker_number),
  }), source_ref)
end

function C.build_output_obligation_command_guard(fact, decision, fields)
  local target = fields or {}
  if type(fact) ~= "table"
    or decision ~= "rereview" then
    error("github-devloop: output-obligation-command-guard-invalid: invalid output obligation command guard")
  end
  return {
    schema = "github-devloop.output-obligation-command-guard.v1",
    decision = decision,
    fact = {
      proposal_id = fact.proposal_id,
      terminal_version = fact.terminal_version,
      dedup_key = fact.dedup_key,
      reason_class = fact.reason_class,
      source_ref = base_ids.normalize_source_ref(fact.source_ref),
      source_repo = fact.source_repo,
      source_issue_number = fact.source_issue_number,
      escalation_repo = fact.escalation_repo,
      escalation_issue_number = fact.escalation_issue_number,
      escalation_source_ref = base_ids.normalize_source_ref(fact.escalation_source_ref),
    },
    target = {
      pr_number = target.pr_number,
      head_sha = target.head_sha,
      target_version = target.target_version,
    },
  }
end

local function output_obligation_guard_fact(guard)
  local fact = type(guard) == "table" and guard.fact or nil
  if type(guard) ~= "table"
    or guard.schema ~= "github-devloop.output-obligation-command-guard.v1"
    or guard.decision ~= "rereview"
    or type(fact) ~= "table"
    or not strings.is_bounded_string(fact.proposal_id, devloop_base._max_key_len)
    or not strings.is_bounded_string(fact.terminal_version, devloop_base._max_dedup_len)
    or not strings.is_bounded_string(fact.dedup_key, devloop_base._max_dedup_len)
    or fact.reason_class ~= "state-output-obligation-timeout"
    or not base_ids.issue_ref_round_trips(fact.source_repo, fact.source_issue_number)
    or not base_ids.issue_ref_round_trips(fact.escalation_repo, fact.escalation_issue_number)
    or not same_source_ref(fact.source_ref, base_ids.issue_source_ref(
      fact.source_repo,
      fact.source_issue_number
    ))
    or not same_source_ref(fact.escalation_source_ref, base_ids.issue_source_ref(
      fact.escalation_repo,
      fact.escalation_issue_number
    )) then
    return nil
  end
  return fact
end

local function output_obligation_escalation_matches(issue, fact, bot_login)
  if type(issue) ~= "table"
    or tostring(issue.state or ""):upper() ~= "OPEN"
    or parsers_misc.canonical_login(parsers_misc._comment_author_login(issue))
      ~= parsers_misc.canonical_login(bot_login)
    or not devloop_base.is_intake_held(issue.labels) then
    return false
  end
  local found = nil
  for marker in tostring(issue.body or ""):gmatch(output_obligation_escalation_pattern) do
    if found ~= nil then
      return false
    end
    found = marker
  end
  return found ~= nil
    and marker_attr(found, "proposal") == fact.proposal_id
    and marker_attr(found, "terminal_version") == fact.terminal_version
    and marker_attr(found, "dedup") == fact.dedup_key
    and marker_attr(found, "reason_class") == fact.reason_class
    and marker_attr(found, "parent") == fact.source_ref.ref
end

local function output_obligation_command_effect_matches(guard, fact, effect)
  if type(effect) ~= "table"
    or tostring(effect.repo or ""):lower() ~= tostring(fact.source_repo or ""):lower() then
    return false
  end
  local command = parse_command(effect.body)
  local authority = type(command) == "table" and command.output_obligation or nil
  if command == nil
    or command.command ~= "rereview"
    or type(authority) ~= "table"
    or authority.invalid == true
    or authority.decision ~= guard.decision
    or authority.escalation_dedup ~= fact.dedup_key
    or authority.terminal_version ~= fact.terminal_version then
    return false
  end
  local target = type(guard.target) == "table" and guard.target or nil
  return type(target) == "table"
    and effect.kind == "pr"
    and tostring(effect.number or "") == tostring(target.pr_number or "")
    and authority.pr_number == target.pr_number
    and authority.head_sha == target.head_sha
    and authority.target_version == target.target_version
end

function C.output_obligation_command_write_authorized(github, guard, bot_login, effect)
  local fact = output_obligation_guard_fact(guard)
  if fact == nil or type(github) ~= "table" or type(github.read_issue) ~= "function" then
    return false, "invalid-command-guard", false
  end
  if not output_obligation_command_effect_matches(guard, fact, effect) then
    return false, "command-effect-changed", false
  end
  parsers_misc.configure_trusted_bot_login(bot_login)
  local source_issue = github.read_issue(fact.source_ref, {
    force_fresh = true,
    timeout = 30,
    consumer = "github-proxy.output-obligation-command-source-guard",
  })
  local escalation_issue = github.read_issue(fact.escalation_source_ref, {
    force_fresh = true,
    timeout = 30,
    consumer = "github-proxy.output-obligation-command-escalation-guard",
  })
  if not output_obligation_escalation_matches(escalation_issue, fact, bot_login) then
    return false, "escalation-changed", true
  end
  if tostring(source_issue and source_issue.state or ""):upper() ~= "OPEN" then
    return false, "source-changed", true
  end
  local source_fact = C.output_obligation_source_lineage_fact(fact, source_issue)
  if source_fact == nil then
    return false, "source-lineage-changed", true
  end
  local snapshot = entity_lib.linked_pr_delegation_surface_snapshot(
    devloop_base._max_dedup_len,
    fact.source_repo,
    fact.proposal_id,
    source_issue.comments,
    { github = github, timeout = 30 }
  )
  local authorization, reason = C.output_obligation_live_command_authorization(
    fact,
    source_issue,
    snapshot,
    source_fact
  )
  if authorization == nil or authorization.decision ~= guard.decision then
    return false, reason or "command-decision-changed", true
  end
  local target = guard.target or {}
  if tostring(target.pr_number or "") ~= tostring(authorization.target.row.number)
    or target.head_sha ~= authorization.target.current_pr.head_sha
    or target.target_version ~= authorization.target_version then
    return false, "command-target-changed", true
  end
  return true, "ok", false
end

function C.output_obligation_command_requires_guard(body)
  return tostring(body or ""):find(
    "<!-- fkst:github-devloop-ops:output-obligation-command:v1",
    1,
    true
  ) ~= nil
end

function C.build_output_obligation_command_write_refusal_body(body, reason)
  local parsed = parse_command(body)
  local key = parsed and output_obligation_command_key(parsed.output_obligation) or nil
  if parsed == nil or key == nil then
    error("github-devloop: output-obligation-command-refusal-invalid: invalid output obligation command refusal")
  end
  local command = {
    command = parsed.command,
    key = key,
  }
  local command_body = tostring(body or ""):gsub("%s*" .. ai_sentinel .. "%s*$", "")
  local safe_reason = devloop_base.neutralize_untrusted_comment_text(reason or "authority-changed")
  return command_body
    .. "\n\ngithub-devloop operator command refused at write guard: " .. safe_reason
    .. "\n\n" .. C.operator_command_marker(command, "refused", reason)
    .. "\n" .. ai_sentinel
end

function C.build_operator_command_intent_request(target, command_name, dedup_key, source_ref, correlation_marker, command_guard)
  if type(target) ~= "table"
    or target.kind ~= "pr"
    or command_name ~= "rereview"
    or not strings.is_bounded_string(dedup_key, devloop_base._max_dedup_len)
    or not strings.is_bounded_string(correlation_marker, devloop_base._max_body_len)
    or output_obligation_guard_fact(command_guard) == nil then
    error("github-devloop: operator-command-intent-invalid: invalid operator command intent")
  end
  local request = entity_lib.build_entity_comment_request(
    target,
    "fkst: " .. command_name .. "\n\n" .. correlation_marker .. "\n" .. ai_sentinel,
    dedup_key,
    source_ref
  )
  request.command_guard = command_guard
  return request
end

function C.build_operator_command_refusal_request(repo, pr_number, command, reason, source_ref)
  local safe_reason = devloop_base.neutralize_untrusted_comment_text(reason or "invalid command state")
  local marker = C.operator_command_marker(command, "refused", reason)
  return entity_lib.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, "github-devloop operator command refused: " .. safe_reason
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "refused",
    tostring(reason or "invalid"),
  }), source_ref)
end

function C.build_operator_issue_command_refusal_request(repo, issue_number, command, reason, source_ref)
  local safe_reason = devloop_base.neutralize_untrusted_comment_text(reason or "invalid command state")
  local marker = C.operator_command_marker(command, "refused", reason)
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command refused: " .. safe_reason
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "refused",
    tostring(reason or "invalid"),
  }), source_ref)
end

return C
