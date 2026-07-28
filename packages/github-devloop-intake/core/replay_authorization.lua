local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local intake_replay_activation = require("devloop.intake_replay_activation")
local m_claims = require("devloop.claims")

local S = {}

function S.terminal_precondition(source_ref)
  local normalized = base_ids.normalize_source_ref(source_ref)
  local snapshot, observe_reason = intake_replay_activation.read_observe_snapshot()
  if snapshot == nil then
    return nil, observe_reason, nil
  end
  local terminal, reason = intake_replay_activation.terminal_precondition(snapshot, normalized)
  return terminal, reason, snapshot
end

function S.successor_key(proposal_id, terminal)
  return base_ids.dedup_key({
    "intake-replay",
    tostring(proposal_id),
    tostring(terminal.delivery_id),
    tostring(terminal.attempts),
  })
end

function S.once_key(successor_key)
  return "github-devloop-intake/intake-replay/" .. tostring(successor_key)
end

function S.authorize(current, proposal_id, source_ref, opts)
  local options = opts or {}
  if type(current) ~= "table" or current.state ~= "OPEN" then
    return nil, "not-open"
  end
  if options.has_trusted_progress == true then
    return nil, "trusted-progress-visible"
  end
  if m_claims.claim_mode_active() ~= "assignee" then
    return nil, "claim-mode-not-assignee"
  end
  local owner = m_claims.claim_owner()
  if m_claims.issue_claim_state(current.assignees, owner, current.labels) ~= "self" then
    return nil, "not-self-only-assignee"
  end
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil or issue_number == nil then
    return nil, "source-ref-unmatchable"
  end

  local normalized = base_ids.normalize_source_ref(source_ref)
  local snapshot, observe_reason
  if options.observe_snapshot ~= nil then
    snapshot, observe_reason = intake_replay_activation.validate_snapshot(options.observe_snapshot)
  else
    snapshot, observe_reason = intake_replay_activation.read_observe_snapshot()
  end
  if snapshot == nil then
    return nil, observe_reason
  end
  if intake_replay_activation.matching_live_delivery(snapshot, normalized) ~= nil then
    return nil, "live-delivery-present"
  end
  local terminal = options.terminal
  if terminal ~= nil and not intake_replay_activation.is_terminal_tombstone(terminal, normalized) then
    return nil, "terminal-dlq-absent"
  end
  terminal = terminal or intake_replay_activation.latest_terminal_tombstone(snapshot, normalized)
  if terminal == nil then
    return nil, "terminal-dlq-absent"
  end

  local successor_key = S.successor_key(proposal_id, terminal)
  return {
    repo = repo,
    issue_number = issue_number,
    terminal = terminal,
    successor_key = successor_key,
    once_key = S.once_key(successor_key),
  }, nil
end

function S.install(M)
  M.intake_replay_authorize = function(...) return S.authorize(...) end
  M.intake_replay_terminal_precondition = function(...) return S.terminal_precondition(...) end
  M.intake_replay_successor_key = S.successor_key
  M.intake_replay_once_key = S.once_key
end

return S
