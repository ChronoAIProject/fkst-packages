local base_ids = require("devloop.base_ids")
local common = require("departments.observability.common")
local config = require("devloop.config")
local contract_sha256 = require("contract.sha256")
local contract_time = require("contract.time")
local transition_version = require("contract.transition_version")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local decompose = require("devloop.decompose")
local devloop_state = require("devloop.state")
local conv_reconcile = require("devloop.convergence.reconcile")
local entity_view = require("devloop.github_proxy_entity_view")
local marker_facts = require("devloop.markers.facts")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local parsers_pr = require("devloop.parsers.pr")
local forge_strings = require("forge.strings")
local request_shared = require("devloop.requests.shared")
local sweep_bounds = require("devloop.sweep_bounds")

local M = {}

local retirement_receipt_pattern = "<!%-%- fkst:github%-devloop%-ops:terminal%-retirement%-receipt:v1.-%-%->"
local result_marker_pattern = "<!%-%- fkst:github%-devloop:result:v1.-%-%->"
local state_marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"

local function ineligible(reason, elapsed_minutes)
  return {
    decision = "ineligible",
    reason = reason,
    elapsed_minutes = elapsed_minutes,
  }
end

local function exact_marker_value(value, limit)
  local text = tostring(value or "")
  if text == "" or #text > limit or marker_shared.safe_marker_attr(text, limit) ~= text then
    return nil
  end
  return text
end

local function recorded_decline_reason(comments, proposal_id, terminal_version)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(result_marker_pattern) do
      local marker_proposal = marker_shared.marker_attr(marker, "proposal")
      local marker_identity = marker_shared.marker_attr(marker, "lineage")
        or marker_shared.marker_attr(marker, "dedup")
      local decision = marker_shared.marker_attr(marker, "decision")
      local reason = marker_shared.marker_attr(marker, "reason")
      if marker_proposal == proposal_id
        and marker_identity == terminal_version
        and decision == "reject"
        and reason == "premise-refuted" then
        return reason
      end
    end
  end
  return nil
end

local function declined_terminal_marker_position(comments, proposal_id, terminal_version)
  for index, comment in ipairs(comments or {}) do
    if parsers_misc._is_trusted_comment(comment) then
      for marker in parsers_misc._comment_body(comment):gmatch(state_marker_pattern) do
        if marker_shared.marker_attr(marker, "proposal") == proposal_id
          and marker_shared.marker_attr(marker, "state") == "declined"
          and marker_shared.marker_attr(marker, "version") == terminal_version then
          return index, parsers_misc._comment_created_at(comment)
        end
      end
    end
  end
  return nil, nil
end

local function has_post_terminal_non_bot_comment(comments, terminal_marker_index)
  local trusted_bot = forge_strings.canonical_login(parsers_misc.trusted_bot_login())
  for index, comment in ipairs(comments or {}) do
    if index > terminal_marker_index then
      local author = forge_strings.canonical_login(parsers_misc._comment_author_login(comment))
      if forge_strings.canonical_login(author) ~= forge_strings.canonical_login(trusted_bot) then
        return true
      end
    end
  end
  return false
end

local function has_post_terminal_non_bot_comment_after(comments, terminal_created_at)
  local terminal_seconds = contract_time.iso_timestamp_epoch_seconds(terminal_created_at)
  if terminal_seconds == nil then
    return true
  end
  local trusted_bot = forge_strings.canonical_login(parsers_misc.trusted_bot_login())
  for _, comment in ipairs(comments or {}) do
    local author = forge_strings.canonical_login(parsers_misc._comment_author_login(comment))
    if author ~= trusted_bot then
      local comment_seconds = contract_time.iso_timestamp_epoch_seconds(
        parsers_misc._comment_created_at(comment)
      )
      if comment_seconds == nil or comment_seconds >= terminal_seconds then
        return true
      end
    end
  end
  return false
end

local function delegation_for_parent_terminal(issue, proposal_id, terminal_version)
  local delegation = marker_facts.pr_delegation_fact(issue.comments, proposal_id)
  if delegation == nil then
    return nil, false
  end
  local expected_terminal_version = transition_version.next_blocked(
    delegation.version,
    "child-pr-blocked"
  )
  if expected_terminal_version ~= terminal_version then
    return nil, true
  end
  return delegation, false
end

local function delegated_proof_digest(delegation, link, pr_state, fix_reconcile, decomposed, proof)
  local fields = {
    delegation.proposal_id,
    delegation.pr_proposal_id,
    delegation.pr_number,
    delegation.version,
    delegation.delegation,
    link.proposal_id,
    link.pr_number,
    link.branch,
    link.impl_version,
    link.base_branch,
    pr_state.state,
    pr_state.version,
    fix_reconcile.round,
    fix_reconcile.action,
    fix_reconcile.dedup_key,
    decomposed.proposal_id,
    decomposed.version,
    decomposed.pr_number,
    decomposed.count,
  }
  for _, child in ipairs(proof.facts or {}) do
    table.insert(fields, tostring(child.index) .. ":" .. tostring(child.issue_number or "unknown"))
  end
  for index, value in ipairs(fields) do
    fields[index] = tostring(value or "")
  end
  return contract_sha256.hex(table.concat(fields, "\n"))
end

local function retirement_receipt_marker(fact)
  if fact.terminal_authority == "delegated-fix-reconcile:v1" then
    return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
      .. fact.proposal_id
      .. '" terminal_state="blocked" terminal_version="' .. fact.terminal_version
      .. '" terminal_authority="delegated-fix-reconcile:v1" action="drop"'
      .. ' delegated_pr="' .. tostring(fact.delegated_pr_number)
      .. '" pr_terminal_version="' .. fact.pr_terminal_version
      .. '" decomposed_count="' .. tostring(fact.decomposed_count)
      .. '" proof_digest="' .. fact.proof_digest
      .. '" dwell_minutes="' .. tostring(fact.dwell_minutes)
      .. '" operator_handling_check="no-post-terminal-human-comment-on-parent-or-pr" -->'
  end
  if fact.terminal_authority == "reconcile:v1" then
    return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
      .. fact.proposal_id
      .. '" terminal_state="blocked" terminal_version="' .. fact.terminal_version
      .. '" terminal_authority="reconcile:v1" action="drop"'
      .. ' terminal_cause="no-semantic-progress" dwell_minutes="' .. tostring(fact.dwell_minutes)
      .. '" decompose_check="no-proposal-pr-delegation-or-terminal-lineage-decomposed"'
      .. ' operator_handling_check="no-post-terminal-human-comment" -->'
  end
  return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
    .. fact.proposal_id
    .. '" terminal_state="declined" terminal_version="' .. fact.terminal_version
    .. '" -->'
end

local function retirement_receipt_visible(comments, fact)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(retirement_receipt_pattern) do
      if marker_shared.marker_attr(marker, "proposal") == fact.proposal_id
        and marker_shared.marker_attr(marker, "terminal_state") == fact.terminal_state
        and marker_shared.marker_attr(marker, "terminal_version") == fact.terminal_version then
        if fact.terminal_authority ~= "reconcile:v1" then
          if fact.terminal_authority ~= "delegated-fix-reconcile:v1" then
            return true
          end
          if marker_shared.marker_attr(marker, "terminal_authority") == "delegated-fix-reconcile:v1"
            and marker_shared.marker_attr(marker, "action") == "drop"
            and marker_shared.marker_attr(marker, "delegated_pr") == tostring(fact.delegated_pr_number)
            and marker_shared.marker_attr(marker, "pr_terminal_version") == fact.pr_terminal_version
            and marker_shared.marker_attr(marker, "decomposed_count") == tostring(fact.decomposed_count)
            and marker_shared.marker_attr(marker, "proof_digest") == fact.proof_digest
            and marker_shared.marker_attr(marker, "dwell_minutes") == tostring(fact.dwell_minutes)
            and marker_shared.marker_attr(marker, "operator_handling_check")
              == "no-post-terminal-human-comment-on-parent-or-pr" then
            return true
          end
        end
        if marker_shared.marker_attr(marker, "terminal_authority") == "reconcile:v1"
          and marker_shared.marker_attr(marker, "action") == "drop"
          and marker_shared.marker_attr(marker, "terminal_cause") == "no-semantic-progress"
          and marker_shared.marker_attr(marker, "dwell_minutes") == tostring(fact.dwell_minutes)
          and marker_shared.marker_attr(marker, "decompose_check")
            == "no-proposal-pr-delegation-or-terminal-lineage-decomposed"
          and marker_shared.marker_attr(marker, "operator_handling_check") == "no-post-terminal-human-comment" then
          return true
        end
      end
    end
  end
  return false
end

local function retirement_receipt_request(repo, issue_number, fact)
  local source_ref = base_ids.issue_source_ref(repo, issue_number)
  local body
  if fact.terminal_authority == "delegated-fix-reconcile:v1" then
    body = table.concat({
      "github-devloop terminal retirement: delegated fix-reconcile drop",
      "",
      "Terminal state: `blocked`",
      "Terminal authority: `delegated-fix-reconcile:v1`",
      "Parent terminal marker version: `" .. fact.terminal_version .. "`",
      "Delegated PR: `#" .. tostring(fact.delegated_pr_number) .. "`",
      "PR terminal marker version: `" .. fact.pr_terminal_version .. "`",
      "Fix reconcile action: `drop`",
      "Decomposition count: `" .. tostring(fact.decomposed_count) .. "`",
      "Proof digest: `" .. fact.proof_digest .. "`",
      "Required dwell: `" .. tostring(fact.dwell_minutes) .. " minutes`",
      "Elapsed dwell: `" .. tostring(fact.elapsed_minutes) .. " minutes`",
      "Operator-handling check: `no non-bot comment after terminal reconcile on the parent issue or delegated PR`",
      "",
      retirement_receipt_marker(fact),
      request_shared.ai_sentinel,
    }, "\n")
  elseif fact.terminal_authority == "reconcile:v1" then
    body = table.concat({
      "github-devloop terminal retirement: reconcile drop",
      "",
      "Terminal state: `blocked`",
      "Terminal authority: `reconcile:v1`",
      "Reconcile action: `drop`",
      "Terminal cause: `no-semantic-progress`",
      "Proposal: `" .. fact.proposal_id .. "`",
      "Terminal marker version: `" .. fact.terminal_version .. "`",
      "Required dwell: `" .. tostring(fact.dwell_minutes) .. " minutes`",
      "Elapsed dwell: `" .. tostring(fact.elapsed_minutes) .. " minutes`",
      "Decompose check: `no trusted pr-delegation for this proposal; no decomposed:v1 for this terminal version lineage`",
      "Operator-handling check: `no non-bot comment after the reconcile terminal comment`",
      "",
      retirement_receipt_marker(fact),
      request_shared.ai_sentinel,
    }, "\n")
  else
    body = table.concat({
      "github-devloop terminal retirement: declined",
      "",
      "Terminal state: `declined`",
      "Terminal marker version: `" .. fact.terminal_version .. "`",
      "Decline reason: `" .. fact.decline_reason .. "`",
      "Elapsed dwell: `" .. tostring(fact.elapsed_minutes) .. " minutes`",
      "",
      "The re-adjudication path is reopening with a corrected premise or new evidence.",
      "",
      retirement_receipt_marker(fact),
      request_shared.ai_sentinel,
    }, "\n")
  end
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = body,
    dedup_key = base_ids.dedup_key({
      "terminal-retirement",
      fact.terminal_state,
      fact.proposal_id,
      fact.terminal_version,
      fact.proof_digest,
    }),
    source_ref = source_ref,
  }
end

local function retirement_dwell(marker_index, marker_created_at, now_seconds)
  local marker_seconds = contract_time.iso_timestamp_epoch_seconds(marker_created_at)
  local current_seconds = tonumber(now_seconds)
  if marker_seconds == nil or current_seconds == nil or current_seconds < marker_seconds then
    return nil, ineligible("terminal-clock-invalid")
  end
  local elapsed_minutes = math.floor((current_seconds - marker_seconds) / 60)
  if elapsed_minutes < common.terminal_retirement_dwell_minutes then
    return nil, ineligible("retirement-dwell-active", elapsed_minutes)
  end
  return {
    marker_index = marker_index,
    elapsed_minutes = elapsed_minutes,
  }
end

local function declined_retirement_fact(issue, proposal_id, terminal_version, now_seconds)
  local marker_index, marker_created_at = declined_terminal_marker_position(
    issue.comments,
    proposal_id,
    terminal_version
  )
  local dwell, failure = retirement_dwell(marker_index, marker_created_at, now_seconds)
  if dwell == nil then
    return nil, failure
  end
  local decline_reason = recorded_decline_reason(issue.comments, proposal_id, terminal_version)
  if decline_reason == nil then
    return nil, ineligible("decline-reason-missing", dwell.elapsed_minutes)
  end
  if has_post_terminal_non_bot_comment(issue.comments, dwell.marker_index) then
    return nil, ineligible("post-terminal-non-bot-comment", dwell.elapsed_minutes)
  end
  return {
    proposal_id = proposal_id,
    terminal_state = "declined",
    terminal_version = terminal_version,
    decline_reason = decline_reason,
    elapsed_minutes = dwell.elapsed_minutes,
  }
end

local function delegated_reconcile_drop_retirement_fact(
  issue,
  proposal_id,
  terminal_version,
  now_seconds,
  delegated
)
  local delegation, mismatch = delegation_for_parent_terminal(issue, proposal_id, terminal_version)
  if delegation == nil then
    return nil, ineligible(mismatch
      and "reconcile-terminal-pr-delegation-mismatch"
      or "reconcile-terminal-fact-missing")
  end
  local pr = type(delegated) == "table" and delegated.pr or nil
  if type(pr) ~= "table" then
    return nil, ineligible("delegated-pr-unavailable")
  end
  if tostring(pr.state or ""):upper() ~= "OPEN" then
    return nil, ineligible("delegated-pr-state-mismatch")
  end
  local link = marker_facts.pr_link_fact(pr.comments, proposal_id)
  if link == nil
    or link.pr_number ~= delegation.pr_number
    or transition_version.strip_suffixes(link.impl_version)
      ~= transition_version.strip_suffixes(delegation.version) then
    return nil, ineligible("delegated-pr-link-missing")
  end
  local fix_reconcile = conv_reconcile.fix_reconcile_fact(
    pr.comments,
    proposal_id,
    nil
  )
  if fix_reconcile == nil or fix_reconcile.action ~= "drop" then
    return nil, ineligible("delegated-fix-reconcile-missing")
  end
  local pr_terminal_version = fix_reconcile.version
  local milestone_opts = {
    domain = "github-devloop-pr",
    lineage_base = pr_terminal_version,
  }
  if transition_version.strip_suffixes(pr_terminal_version)
      ~= transition_version.strip_suffixes(delegation.version)
    or not devloop_state.reached(pr.comments, proposal_id, "blocked", milestone_opts)
    or not devloop_state.has_state_marker(pr.comments, proposal_id, "blocked", pr_terminal_version)
    or devloop_state.reached(pr.comments, proposal_id, "closed-unmerged", milestone_opts) then
    return nil, ineligible("delegated-pr-state-mismatch")
  end
  local pr_state = {
    state = "blocked",
    version = pr_terminal_version,
  }
  local decomposed = decompose.decomposed_fact(
    pr.comments,
    proposal_id,
    pr_state.version,
    delegation.pr_number
  )
  if decomposed == nil then
    return nil, ineligible("delegated-decomposed-missing")
  end
  local _, _, proof = decompose.decompose_children_complete(
    nil,
    type(delegated) == "table" and delegated.child_issues or nil,
    proposal_id,
    pr_state.version,
    delegation.pr_number,
    decomposed.count
  )
  if type(proof) ~= "table" or proof.exact ~= true then
    return nil, ineligible("delegated-decomposition-proof-incomplete")
  end
  local dwell, failure = retirement_dwell(
    fix_reconcile.comment_index,
    fix_reconcile.comment_created_at,
    now_seconds
  )
  if dwell == nil then
    return nil, failure
  end
  if has_post_terminal_non_bot_comment(pr.comments, dwell.marker_index)
    or has_post_terminal_non_bot_comment_after(issue.comments, fix_reconcile.comment_created_at) then
    return nil, ineligible("post-terminal-non-bot-comment", dwell.elapsed_minutes)
  end
  return {
    proposal_id = proposal_id,
    terminal_state = "blocked",
    terminal_version = terminal_version,
    terminal_authority = "delegated-fix-reconcile:v1",
    delegated_pr_number = delegation.pr_number,
    pr_terminal_version = pr_state.version,
    decomposed_count = decomposed.count,
    proof_digest = delegated_proof_digest(
      delegation,
      link,
      pr_state,
      fix_reconcile,
      decomposed,
      proof
    ),
    dwell_minutes = common.terminal_retirement_dwell_minutes,
    elapsed_minutes = dwell.elapsed_minutes,
  }
end

local function reconcile_drop_retirement_fact(issue, proposal_id, terminal_version, now_seconds, delegated)
  local delegation, mismatch = delegation_for_parent_terminal(issue, proposal_id, terminal_version)
  if delegation ~= nil or mismatch then
    return delegated_reconcile_drop_retirement_fact(
      issue,
      proposal_id,
      terminal_version,
      now_seconds,
      delegated
    )
  end
  local reconcile_fact = conv_reconcile.reconcile_fact_for_terminal_version(
    issue.comments,
    proposal_id,
    terminal_version
  )
  if reconcile_fact == nil then
    return nil, ineligible("reconcile-terminal-fact-missing")
  end
  if reconcile_fact.action ~= "drop" then
    return nil, ineligible("reconcile-terminal-action-unsupported")
  end
  if reconcile_fact.terminal_cause ~= "no-semantic-progress" then
    return nil, ineligible("reconcile-terminal-cause-unsupported")
  end
  local dwell, failure = retirement_dwell(
    reconcile_fact.comment_index,
    reconcile_fact.comment_created_at,
    now_seconds
  )
  if dwell == nil then
    return nil, failure
  end
  if marker_facts.pr_delegation_fact(issue.comments, proposal_id) ~= nil then
    return nil, ineligible("reconcile-terminal-pr-delegation-present", dwell.elapsed_minutes)
  end
  if decompose.decomposed_fact(issue.comments, proposal_id, terminal_version) ~= nil then
    return nil, ineligible("reconcile-terminal-decomposed-present", dwell.elapsed_minutes)
  end
  if has_post_terminal_non_bot_comment(issue.comments, dwell.marker_index) then
    return nil, ineligible("post-terminal-non-bot-comment", dwell.elapsed_minutes)
  end
  return {
    proposal_id = proposal_id,
    terminal_state = "blocked",
    terminal_version = terminal_version,
    terminal_authority = "reconcile:v1",
    reconcile_action = reconcile_fact.action,
    terminal_cause = reconcile_fact.terminal_cause,
    dwell_minutes = common.terminal_retirement_dwell_minutes,
    elapsed_minutes = dwell.elapsed_minutes,
  }
end

local function observed_reconcile_drop_candidate(entity)
  local observed_state = type(entity) == "table" and entity.state or nil
  local observed_issue = type(entity) == "table" and entity.parent_issue or nil
  local delegation = observed_issue and observed_state
    and delegation_for_parent_terminal(
      observed_issue,
      entity.proposal_id,
      observed_state.version
    )
    or nil
  if delegation ~= nil then
    return true
  end
  local fact = conv_reconcile.reconcile_fact_for_terminal_version(
    observed_issue and observed_issue.comments,
    entity and entity.proposal_id,
    observed_state and observed_state.version
  )
  return fact ~= nil
    and fact.action == "drop"
    and fact.terminal_cause == "no-semantic-progress"
end

local terminal_retirement_kinds = {
  declined = {
    derive_fact = declined_retirement_fact,
    observed_candidate = function() return true end,
  },
  blocked = {
    derive_fact = reconcile_drop_retirement_fact,
    observed_candidate = observed_reconcile_drop_candidate,
  },
}

function M.decide(issue, expected, now_seconds, delegated)
  if type(issue) ~= "table" then
    return ineligible("issue-missing")
  end
  if tostring(issue.state or ""):upper() ~= "OPEN" then
    return ineligible("issue-not-open")
  end
  local expected_state = type(expected) == "table" and expected.state or nil
  local retirement_kind = terminal_retirement_kinds[expected_state]
  if retirement_kind == nil then
    return ineligible("not-declined")
  end
  local proposal_id = exact_marker_value(expected.proposal_id, base_ids.max_key_len)
  local terminal_version = exact_marker_value(expected.version, base_ids.max_dedup_len)
  if proposal_id == nil or terminal_version == nil then
    return ineligible("terminal-identity-invalid")
  end
  if not devloop_state.is_current_state(issue.comments, proposal_id, expected_state, terminal_version) then
    return ineligible("terminal-changed")
  end

  local fact, failure = retirement_kind.derive_fact(
    issue,
    proposal_id,
    terminal_version,
    now_seconds,
    delegated
  )
  if fact == nil then
    return failure
  end
  if retirement_receipt_visible(issue.comments, fact) then
    return {
      decision = "eligible",
      action = "close",
      fact = fact,
    }
  end
  return {
    decision = "eligible",
    action = "receipt",
    fact = fact,
    request = retirement_receipt_request(expected.repo, expected.issue_number, fact),
  }
end

local function log_retirement(expected, decision, action, mode, reason)
  log.info(table.concat({
    "github-devloop",
    "dept=observability",
    "tag=TERMINAL_RETIREMENT",
    "proposal=" .. tostring(expected and expected.proposal_id or "unknown"),
    "terminal_state=" .. tostring(expected and expected.state or "unknown"),
    "terminal_version=" .. tostring(expected and expected.version or "unknown"),
    "decision=" .. tostring(decision or "ineligible"),
    "action=" .. tostring(action or "skip"),
    "mode=" .. tostring(mode or "dry-run"),
    "reason=" .. tostring(reason or "none"),
  }, " "))
end

local function read_delegated_evidence(github, repo, issue, expected, limits, deadline)
  local delegation = delegation_for_parent_terminal(
    issue,
    expected.proposal_id,
    expected.version
  )
  if delegation == nil then
    return nil
  end
  if not sweep_bounds.sweep_has_budget(deadline) then
    return nil, "deadline-before-delegated-pr-read"
  end
  local pr_view = devloop_commands.gh_pr_view_origin(
    repo,
    delegation.pr_number,
    sweep_bounds.sweep_call_timeout(limits, deadline),
    github
  )
  if type(pr_view) ~= "table" or pr_view.exit_code ~= 0 then
    return {}, nil
  end
  local pr = parsers_pr.parse_pr_view_origin(pr_view.stdout)
  if not sweep_bounds.sweep_has_budget(deadline) then
    return nil, "deadline-before-decomposition-proof-read"
  end
  local child_list = devloop_commands.gh_issue_list_decompose_children(
    repo,
    expected.proposal_id,
    sweep_bounds.sweep_call_timeout(limits, deadline),
    github
  )
  if type(child_list) ~= "table" or child_list.exit_code ~= 0 then
    return { pr = pr }, nil
  end
  return {
    pr = pr,
    child_issues = decompose.parse_decompose_child_issue_list(child_list.stdout),
  }, nil
end

function M.reconcile(github, repo, entity, limits, deadline)
  local observed_state = type(entity) == "table" and entity.state or nil
  local observed_issue = type(entity) == "table" and entity.parent_issue or nil
  local retirement_kind = type(observed_state) == "table"
    and terminal_retirement_kinds[observed_state.state]
    or nil
  if type(observed_state) ~= "table"
    or retirement_kind == nil
    or tostring(observed_issue and observed_issue.state or ""):upper() ~= "OPEN" then
    return nil
  end
  if not retirement_kind.observed_candidate(entity) then
    return nil
  end
  local expected = {
    proposal_id = entity.proposal_id,
    repo = repo,
    issue_number = entity.issue_number,
    state = observed_state.state,
    version = observed_state.version,
  }
  if not sweep_bounds.sweep_has_budget(deadline) then
    log_retirement(expected, "ineligible", "defer", config.write_mode(), "deadline")
    return nil
  end
  if type(github) ~= "table" or type(github.read_issue) ~= "function" then
    error("github-devloop-ops: terminal-retirement-github-port-missing: observability retirement requires a GitHub adapter")
  end

  local fresh_issue = github.read_issue(base_ids.issue_source_ref(repo, entity.issue_number), {
    force_fresh = true,
    timeout = sweep_bounds.sweep_call_timeout(limits, deadline),
    consumer = "github-devloop-ops.terminal-retirement",
  })
  local delegated, delegated_defer = read_delegated_evidence(
    github,
    repo,
    fresh_issue,
    expected,
    limits,
    deadline
  )
  if delegated_defer ~= nil then
    log_retirement(expected, "ineligible", "defer", config.write_mode(), delegated_defer)
    return nil
  end
  local decision = M.decide(fresh_issue, expected, now(), delegated)
  local mode = config.write_mode()
  if decision.decision ~= "eligible" then
    log_retirement(expected, decision.decision, "skip", mode, decision.reason)
    return nil
  end
  if mode ~= "real" then
    log_retirement(expected, decision.decision, "would-retire", mode, decision.action)
    return nil
  end
  if decision.action == "receipt" then
    log_retirement(expected, decision.decision, "receipt", mode, "retirement-eligible")
    return {
      queue = "github-proxy.github_issue_comment_request",
      payload = decision.request,
      fact = decision.fact,
    }
  end
  if decision.action ~= "close" then
    error("github-devloop-ops: terminal-retirement-decision-invalid: eligible decision has no supported action")
  end
  if not sweep_bounds.sweep_has_budget(deadline) then
    log_retirement(expected, decision.decision, "defer", mode, "deadline-after-fresh-read")
    return nil
  end
  local timeout = sweep_bounds.sweep_call_timeout(limits, deadline)
  if timeout < 1 then
    log_retirement(expected, decision.decision, "defer", mode, "deadline-after-fresh-read")
    return nil
  end
  local closed = github.issue_close(repo, entity.issue_number, { kind = "not_planned" }, timeout)
  if type(closed) ~= "table" or closed.exit_code ~= 0 then
    error("github-devloop-ops: terminal-retirement-close-failed: issue close failed: "
      .. tostring(closed and closed.stderr or "missing result"))
  end
  entity_view.invalidate_entity_after_write(repo, "issue", entity.issue_number)
  log_retirement(expected, decision.decision, "close", mode, "receipt-visible")
  return nil
end

return M
