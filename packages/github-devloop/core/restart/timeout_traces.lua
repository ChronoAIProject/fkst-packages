local transition_version = require("contract.transition_version")
local conv_reconcile = require("devloop.convergence.reconcile")
local restart_trace = require("devloop.restart_trace")
local obligations = require("core.restart.timeout_obligations")

local OWNER = "github-devloop"
local EDGE_ID = "github-devloop/ready/timeout/actionable_kickoff_timeout"
local CAS_POLICY_ID = "cas.legacy_timeout_reconcile_v1"
local QUEUE = "devloop_timeout_reconcile"
local NULL = restart_trace.null

local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local READY_ATTEMPT = transition_version.timeout_at(V_EQUAL, "ready", 3)

local function timeout_reconcile_version(version)
  return conv_reconcile.timeout_reconcile_state_version(version, "ready", 3)
end

local fixture_details = {
  ["newer-source-marker-missing-pending"] = {
    current_version = NULL,
    incoming_version = timeout_reconcile_version(
      transition_version.timeout_at(V_NEWER, "ready", 3)
    ),
    effect_entitlement_id = NULL,
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
  ["source-equal-apply"] = {
    current_version = READY_ATTEMPT,
    incoming_version = timeout_reconcile_version(READY_ATTEMPT),
    effect_entitlement_id = EDGE_ID .. "/apply",
    observable_writes = restart_trace.array({
      {
        effect_id = "github-proxy.github_issue_comment_request",
        marker_write = true,
        ordinal = 1,
        write_kind = "comment",
      },
      {
        effect_id = "github-proxy.github_issue_label_request",
        marker_write = false,
        ordinal = 2,
        write_kind = "label",
      },
    }),
    terminal_why = {
      reason_class = "state-output-obligation-timeout",
    },
  },
  ["source-older-stale"] = {
    current_version = READY_ATTEMPT,
    incoming_version = timeout_reconcile_version(
      transition_version.timeout_at(V_OLDER, "ready", 3)
    ),
    effect_entitlement_id = NULL,
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
}

local function copy_array(values)
  local result = restart_trace.array()
  for _, value in ipairs(values) do
    table.insert(result, value)
  end
  return result
end

local function payload_obligations(values)
  local result = restart_trace.array()
  for _, value in ipairs(values) do
    table.insert(result, {
      effect_id = value.effect_id,
      equality = value.equality,
    })
  end
  return result
end

local traces = restart_trace.array()
for _, obligation in ipairs(obligations) do
  local details = fixture_details[obligation.input_fixture_id]
  if details == nil then
    error("github-devloop: restart-trace-fixture-missing: missing fixture "
      .. obligation.input_fixture_id, 0)
  end
  local grant_fingerprint = NULL
  if details.effect_entitlement_id ~= NULL then
    grant_fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = "r9-timeout-reconcile:" .. obligation.input_fixture_id,
      edge_id = EDGE_ID,
      effect_entitlement_id = details.effect_entitlement_id,
    })
  end
  table.insert(traces, restart_trace.define({
    schema = "restart-trace.v1",
    owner = OWNER,
    fixture_id = obligation.input_fixture_id,
    steps = restart_trace.array({
      {
        edge_id = EDGE_ID,
        row_replay_id = NULL,
        kind = "timeout",
        source = { state = "ready", boundary = NULL },
        target = "blocked",
        cause_evidence = {
          timeout_evidence_policy_id = "timeout.state_entry_legacy_v1",
        },
        cas_policy_id = CAS_POLICY_ID,
        cas_status = obligation.expected_decision.cas_status,
        reason_code = obligation.expected_decision.reason_code,
        cas_outcome = obligation.expected_decision.cas_outcome,
        pending_status = "included",
        generation_epoch = {
          current_version = details.current_version,
          incoming_version = details.incoming_version,
          generation = "r9-timeout-reconcile:generation",
          lock_epoch = "r9-timeout-reconcile:lock",
        },
        grant_fingerprint = grant_fingerprint,
        effect_entitlement_id = details.effect_entitlement_id,
        effect_ids = copy_array(obligation.expected_effect_ids),
        queue = QUEUE,
        payload_obligations = payload_obligations(
          obligation.expected_payload_obligations
        ),
        observable_writes = details.observable_writes,
        terminal_why = details.terminal_why,
      },
    }),
  }))
end

return traces
