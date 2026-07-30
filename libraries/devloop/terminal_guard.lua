local strings = require("contract.strings")
local source_refs = require("contract.source_ref")
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local forge_validators = require("devloop.forge_validators")

local M = {}

local source_states = {
  blocked = true,
  reviewing = true,
  fixing = true,
  ["merge-ready"] = true,
  merging = true,
}

function M.build(opts)
  local fields = opts or {}
  return {
    schema = "github-devloop.terminal-guard.v1",
    proposal_id = fields.proposal_id,
    source_state = fields.source_state,
    source_version = fields.source_version,
    terminal_state = "blocked",
    terminal_version = fields.terminal_version or fields.source_version,
    head_sha = fields.head_sha,
  }
end

function M.for_decompose(decompose)
  return M.build({
    proposal_id = decompose.proposal_id,
    source_state = "blocked",
    source_version = decompose.version,
    terminal_version = decompose.version,
    head_sha = decompose.head_sha,
  })
end

function M.is_supported(guard, phase)
  if type(guard) ~= "table"
    or guard.schema ~= "github-devloop.terminal-guard.v1"
    or not strings.is_path_safe_key(guard.proposal_id, devloop_base._max_key_len)
    or not strings.is_bounded_string(guard.source_version, devloop_base._max_dedup_len)
    or guard.terminal_state ~= "blocked"
    or not strings.is_bounded_string(guard.terminal_version, devloop_base._max_dedup_len)
    or not forge_validators.is_git_sha(guard.head_sha) then
    return false
  end
  if phase == "source" then
    return source_states[guard.source_state] == true
  end
  return phase == "terminal"
end

local function current_head_sha(pr)
  return pr and (pr.head_sha or pr.head_ref_oid) or nil
end

local function same_repo(repo, pr)
  if pr == nil or pr.is_cross_repository ~= false then
    return false
  end
  if pr.is_target_repository ~= nil then
    return pr.is_target_repository == true
  end
  return pr.head_repository ~= nil
    and tostring(pr.head_repository):lower() == tostring(repo):lower()
end

function M.evaluate(guard, repo, pr, comments, trust_set, phase)
  local current = devloop_state.terminal_guard_state(comments, guard and guard.proposal_id, trust_set)
  if not M.is_supported(guard, phase) then
    return false, "guard-invalid", current
  end
  if tostring(pr and pr.state or ""):lower() ~= "open" then
    return false, "pr-not-open", current
  end
  if not same_repo(repo, pr) then
    return false, "pr-not-same-repo", current
  end
  local head_sha = current_head_sha(pr)
  if not forge_validators.is_git_sha(head_sha) then
    return false, "head-missing", current
  end
  if tostring(head_sha):lower() ~= tostring(guard.head_sha):lower() then
    return false, "head-advanced", current
  end
  local expected_state = phase == "source" and guard.source_state or guard.terminal_state
  local expected_version = phase == "source" and guard.source_version or guard.terminal_version
  if current.state ~= expected_state then
    return false, "state-advanced", current
  end
  if tostring(current.version or "") ~= tostring(expected_version or "") then
    return false, "version-advanced", current
  end
  return true, "ok", current
end

function M.refusal_payload(guard, repo, pr_number, pr, current, reason, source_ref, origin, request_dedup_key)
  local current_head = current_head_sha(pr)
  return {
    schema = "github-devloop.terminal-refused.v1",
    proposal_id = guard.proposal_id,
    pr_number = pr_number,
    bound_version = guard.terminal_version,
    bound_head_sha = guard.head_sha,
    current_head_sha = current_head,
    current_state = current and current.state or nil,
    current_version = current and current.version or nil,
    reason = reason,
    origin = origin,
    dedup_key = base_ids.dedup_key({
      "terminal-refused",
      tostring(origin),
      tostring(request_dedup_key),
      tostring(reason),
      tostring(current_head),
    }),
    source_ref = base_ids.normalize_source_ref(source_ref),
  }
end

function M.is_supported_refusal(payload)
  local repo, issue_number = base_ids.parse_proposal_id(payload and payload.proposal_id)
  return type(payload) == "table"
    and payload.schema == "github-devloop.terminal-refused.v1"
    and repo ~= nil
    and issue_number ~= nil
    and forge_validators.is_positive_pr_number(payload.pr_number)
    and strings.is_bounded_string(payload.bound_version, devloop_base._max_dedup_len)
    and forge_validators.is_git_sha(payload.bound_head_sha)
    and strings.is_bounded_string(payload.reason, 80)
    and strings.is_bounded_string(payload.origin, 80)
    and strings.is_bounded_string(payload.dedup_key, devloop_base._max_dedup_len)
    and source_refs.has_bounded_source_ref(payload.source_ref, devloop_base._max_key_len)
end

return M
