local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")

local S = {}

local target_queue = "github-devloop-intake.devloop_intake_candidate"
local target_dept = "github-devloop-intake-default.intake_judge"

local function source_ref_value(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  return source_ref.ref or source_ref.reference
end

local function source_ref_kind(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  local kind = source_ref.kind
  if kind == "file_watch" then
    return "file"
  end
  if type(kind) == "string" then
    return string.lower(kind)
  end
  return kind
end

local function matches_lineage(row, source_ref)
  return type(row) == "table"
    and row.queue == target_queue
    and row.dept == target_dept
    and type(row.source) == "table"
    and source_ref_kind(row.source) == source_ref_kind(source_ref)
    and source_ref_value(row.source) == source_ref_value(source_ref)
end

local function read_lineage(source_ref)
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    return nil, "observe-unavailable"
  end
  local ok, result = pcall(function()
    return fkst.observe({
      lineage = {
        queue = target_queue,
        dept = target_dept,
        source_ref = source_ref,
      },
    })
  end)
  if not ok then
    return nil, "observe-unavailable:" .. tostring(result)
  end
  if type(result) ~= "table" then
    return nil, "observe-unavailable"
  end
  return result, nil
end

local function is_terminal_tombstone(row, source_ref)
  return matches_lineage(row, source_ref)
    and type(row.delivery_id) == "string"
    and row.delivery_id ~= ""
    and tonumber(row.attempts) ~= nil
    and tonumber(row.attempts) >= 1
    and row.permanent == true
    and row.replayable == false
end

function S.terminal_precondition(source_ref)
  local normalized = base_ids.normalize_source_ref(source_ref)
  local lineage, observe_reason = read_lineage(normalized)
  if lineage == nil then
    return nil, observe_reason, nil
  end
  if matches_lineage(lineage.live_delivery, normalized) then
    return nil, "live-delivery-present", lineage
  end
  local terminal = lineage.terminal_dead_letter
  if not is_terminal_tombstone(terminal, normalized) then
    return nil, "terminal-dlq-absent", lineage
  end
  return terminal, nil, lineage
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
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil or issue_number == nil then
    return nil, "source-ref-unmatchable"
  end
  local claim_contract = m_claims.new_label_claim_contract(
    base_ids.issue_source_ref(repo, issue_number)
  )
  if m_claims.issue_claim_state(
      current.assignees, claim_contract.owner, current.labels, claim_contract) ~= "self" then
    return nil, "not-self-only-assignee"
  end

  local normalized = base_ids.normalize_source_ref(source_ref)
  local lineage, observe_reason
  if options.lineage ~= nil then
    lineage = options.lineage
  else
    lineage, observe_reason = read_lineage(normalized)
  end
  if type(lineage) ~= "table" then
    return nil, observe_reason
  end
  if matches_lineage(lineage.live_delivery, normalized) then
    return nil, "live-delivery-present"
  end
  local terminal = options.terminal or lineage.terminal_dead_letter
  if not is_terminal_tombstone(terminal, normalized) then
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
