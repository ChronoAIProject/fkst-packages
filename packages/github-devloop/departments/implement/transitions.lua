local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_base = require("devloop.base")
local m_facts = require("devloop.markers.facts")
local operator_commands = require("devloop.operator_commands")

local M = {}

function M.expected_state_matches(state, expected)
  local expected_state = expected
  local version = nil
  if type(expected) == "table" then
    expected_state = expected.state
    version = expected.version
    if version == nil then
      version = expected.target_version
    end
  end
  if version == nil then
    return tostring(state.state or "") == tostring(expected_state)
  end
  return tostring(state.state or "") == tostring(expected_state)
    and tostring(state.version or "") == tostring(version or "")
end

local function expected_transition_versions(expected_states, default_version)
  local source_version = default_version
  local target_version = nil
  for _, expected in ipairs(expected_states or {}) do
    if type(expected) == "table" then
      if expected.version ~= nil then
        source_version = expected.version
      end
      if expected.target_version ~= nil then
        target_version = expected.target_version
      end
    end
  end
  return source_version, target_version
end

function M.activation_intent(expected_states, marker_version, operator_reentry, phase, accepted_handoff)
  local source_version, target_version = expected_transition_versions(expected_states, marker_version)
  local expected = expected_states and expected_states[1]
  local source_state = type(expected) == "table" and expected.state or expected
  local semantic_variant = ({ ready = "implementation_kicked_off", ["impl-failed"] = "retry-implementation" })[source_state]
  local source_boundary = nil
  if source_state == "blocked" then
    source_boundary = operator_reentry and operator_reentry.terminal_reason == "implementing-timeout-without-pr"
      and "implementing-timeout-without-pr" or "open-pr"
    semantic_variant = source_boundary == "open-pr"
      and "reimplement_blocked_open_pr"
      or "reimplement_blocked_implementing_timeout_without_pr"
  end
  return {
    semantic_variant = semantic_variant,
    source_boundary = source_boundary,
    target = "implementing",
    incoming_version = source_version,
    target_version = target_version,
    phase = phase,
    retry = source_state ~= "ready",
    handoff = accepted_handoff and { status = "valid" } or nil,
    accepted_handoff = accepted_handoff or nil,
  }
end

function M.expected_states_include(expected_states, state_name)
  for _, expected in ipairs(expected_states or {}) do
    local expected_state = type(expected) == "table" and expected.state or expected
    if tostring(expected_state or "") == tostring(state_name or "") then
      return true
    end
  end
  return false
end

function M.operator_blocked_reimplement_allowed(ready, current, state)
  local reentry = ready and ready.operator_reentry
  if type(reentry) ~= "table"
    or reentry.command ~= "reimplement"
    or reentry.from_state ~= "blocked"
    or state.state ~= "blocked"
    or tostring(state.version or "") ~= tostring(reentry.state_version or "") then
    return false
  end
  if reentry.terminal_reason == "implementing-timeout-without-pr" then
    if m_facts.pr_link_fact(current.comments, ready.proposal_id) ~= nil then return false end
    local fact = conv_reconcile.timeout_reconcile_fact_for_terminal_version_from_states(
      current.comments, ready.proposal_id, state.version, { implementing = true })
    return fact ~= nil
      and fact.from_state == "implementing"
      and fact.reason_class == "state-output-obligation-timeout"
      and tostring(fact.from_version or "") == tostring(reentry.impl_version or "")
      and tonumber(fact.round) == tonumber(reentry.timeout_round)
      and operator_commands.reintake_source_refs_match(
        fact.source_ref, ready.source_ref, devloop_base._max_key_len)
      and tostring(reentry.impl_version or "") == tostring(ready.dedup_key or "")
  end
  local link = m_facts.pr_link_fact(current.comments, ready.proposal_id)
  return link ~= nil
    and tonumber(link.pr_number) == tonumber(reentry.pr_number)
    and tostring(link.impl_version or "") == tostring(reentry.impl_version or "")
end

return M
