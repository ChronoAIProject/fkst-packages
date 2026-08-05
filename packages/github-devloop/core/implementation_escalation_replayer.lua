local base_ids = require("devloop.base_ids")
local devloop_logging = require("devloop.logging")
local implementation_escalation = require("devloop.implementation_escalation")
local replay_fields = require("devloop.replay_fields")

local R = {}

local function replay_payload(issue, state, facts)
  local checkpoint = facts["implement-checkpoint"]
  local evidence = facts["implementation-escalation"]
  if checkpoint == nil or evidence == nil then
    return nil
  end
  local payload = implementation_escalation.build_payload({
    proposal_id = facts.proposal_id,
    version = state.version,
    branch = checkpoint.branch,
    source_ref = issue.source_ref,
  }, evidence)
  if not implementation_escalation.is_supported_payload(payload)
    or checkpoint.attempt ~= evidence.attempt
    or checkpoint.head_sha ~= evidence.head_sha then
    return nil
  end
  return payload
end

function R.install(M)
  local function replay(dept, issue, state, _row, facts)
    local proposal_id = facts.proposal_id
    local payload = facts.implementation_escalation_payload
      or replay_payload(issue, state, facts)
    if payload == nil then
      devloop_logging.log_cas_decision(dept, proposal_id, state,
        "implementation-escalating", "implementation-escalating",
        "skip-pending(escalation-evidence)",
        "trusted implementation checkpoint and escalation evidence are not visible")
      return false
    end

    local decomposition = facts["implementation-decomposition"]
    local linkage = facts["implementation-child-linkage"]
    if decomposition == nil or linkage == nil then
      devloop_logging.log_cas_decision(dept, proposal_id, state,
        "implementation-escalating", "implementation-escalating",
        "applied(replay)",
        "implementation decomposition plan or complete child linkage is not visible")
      return replay_fields.replay_raise_effects(
        devloop_logging.log_apply,
        devloop_logging.log_raise,
        dept,
        proposal_id,
        "implementation-escalating",
        state.version,
        { add = {}, remove = {} },
        {
          {
            queue = "github-devloop-decompose.devloop_implementation_decompose",
            payload = payload,
          },
        })
    end

    local gate = facts.dependency_gate
    if type(gate) ~= "table" then
      devloop_logging.log_cas_decision(dept, proposal_id, state,
        "implementation-escalating", "implementation-escalating",
        "skip-pending(dependency-gate)",
        "declared dependency gate fact is not visible")
      return false
    end
    local to_state = gate.ok and "ready" or "dependency_wait"
    local to_version = M.ready_split_version(state.version)
    local label_dedup_key = base_ids.dedup_key({
      "implementation-escalation",
      "complete",
      tostring(proposal_id),
      tostring(to_version),
      tostring(to_state),
    })
    devloop_logging.log_cas_decision(dept, proposal_id, state,
      "implementation-escalating", to_state,
      "applied(decomposition-complete)",
      tostring(gate.reason or "implementation child dependency gate derived"))
    M.raise_ready_split_effects(
      dept,
      issue,
      proposal_id,
      state.version,
      to_state,
      to_version,
      gate,
      label_dedup_key)
    return true
  end

  return {
    ["implementation-escalating"] = replay,
  }
end

return R
