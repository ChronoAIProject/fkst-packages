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

local ai_sentinel = "⟦AI:FKST⟧"
local rereview_state_modes = {
  blocked = "direct",
  ["review-meta"] = "direct",
  reviewing = "stall-required",
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

local function parse_command(body)
  local line = first_command_line(body)
  local command = line:match("^fkst:%s*([%w_-]+)")
  if command == "rereview" or command == "reready" or command == "reintake" or command == "reimplement" then
    return {
      command = command,
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
        local key = command_key(comment, index)
        if expected_key == nil or key == tostring(expected_key) then
          latest = {
            command = parsed.command,
            key = key,
            author_login = parsers_misc._comment_author_login(comment),
            created_at = parsers_misc._comment_created_at(comment),
            body = parsers_misc._comment_body(comment),
            blocker_number = parsed.blocker_number,
          }
        end
      else
        devloop_logging.log_line("info", "operator_command", "IGNORED", {
          "command=" .. tostring(parsed.command),
          "reason=untrusted-author",
          "ignored_author=" .. tostring(parsers_misc._comment_author_login(comment) or ""),
          "trusted_bot=" .. tostring(devloop_base.trusted_bot_login()),
        })
      end
    end
  end
  return latest
end

function C.operator_rereview_version(current_version, head_sha)
  if not forge_validators.is_git_sha(head_sha) then
    error("github-devloop: invalid operator rereview head sha")
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

function C.reintake_has_active_devloop_state(labels, comments, proposal_id)
  return devloop_state.reintake_has_active_devloop_state(labels, comments, proposal_id)
end

function C.reintake_effect_updated_at(issue, command, comments, proposal_id)
  return devloop_state.reintake_effect_updated_at(issue, command, comments, proposal_id)
end

function C.reintake_source_refs_match(left, right, limit)
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
      and command.command ~= "reintake"
      and command.command ~= "reimplement"
      and command.command ~= "dependency-waiver") then
    error("github-devloop: invalid operator command marker")
  end
  if outcome ~= "applied" and outcome ~= "refused" then
    error("github-devloop: invalid operator command outcome")
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

function C.build_operator_issue_dependency_waiver_comment_request(M, repo, issue_number, command, proposal_id, version, blocker_number, source_ref)
  local waiver_marker = M.dependency_waiver_marker(proposal_id, version, blocker_number, "operator-waiver")
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

function C.build_operator_issue_reintake_comment_request(repo, issue_number, command, candidate, source_ref)
  local marker = C.operator_command_marker(command, "applied", "reintake")
  return entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = repo,
    number = issue_number,
  }, "github-devloop operator command accepted: reintake"
    .. "\n\n" .. marker
    .. "\n" .. ai_sentinel, base_ids.dedup_key({
    "operator-command",
    "comment",
    tostring(command.key),
    "applied",
    tostring(candidate and candidate.dedup_key or "reintake"),
  }), source_ref)
end

function C.build_operator_command_intent_request(target, command_name, dedup_key, source_ref, correlation_marker)
  if type(target) ~= "table"
    or (target.kind ~= "issue" and target.kind ~= "pr")
    or (command_name ~= "rereview" and command_name ~= "reintake")
    or not strings.is_bounded_string(dedup_key, devloop_base._max_dedup_len)
    or not strings.is_bounded_string(correlation_marker, devloop_base._max_body_len) then
    error("github-devloop: invalid operator command intent")
  end
  return entity_lib.build_entity_comment_request(
    target,
    "fkst: " .. command_name .. "\n\n" .. correlation_marker .. "\n" .. ai_sentinel,
    dedup_key,
    source_ref
  )
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
