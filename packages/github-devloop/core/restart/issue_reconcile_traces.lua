local conv_reconcile = require("devloop.convergence.reconcile")
local restart_trace = require("devloop.restart_trace")
local obligations = require("core.restart.issue_reconcile_obligations")

local OWNER = "github-devloop"
local EDGE_ID = "github-devloop/thinking/entry/issue_reconcile_true_stall"
local CAS_POLICY_ID = "cas.legacy_issue_reconcile_v1"
local QUEUE = "devloop_reconcile"
local NULL = restart_trace.null
local ROUND = 3

local V_EQUAL = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

local function terminal_version(version)
  return conv_reconcile.reconcile_terminal_state_version(version, ROUND)
end

local fixture_details = {
  ["source-equal-apply"] = {
    current_version = V_EQUAL,
    incoming_version = terminal_version(V_EQUAL),
    generation = V_EQUAL,
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
      terminal_cause = "no-semantic-progress",
    },
  },
  ["source-marker-missing-pending"] = {
    current_version = NULL,
    incoming_version = terminal_version(V_NEWER),
    generation = "r9-issue-reconcile:missing",
    effect_entitlement_id = NULL,
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
  ["source-state-advanced-stale"] = {
    current_version = V_EQUAL,
    incoming_version = terminal_version(V_EQUAL),
    generation = V_EQUAL,
    effect_entitlement_id = NULL,
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
  ["target-idempotent"] = {
    current_version = V_EQUAL,
    incoming_version = terminal_version(V_EQUAL),
    generation = V_EQUAL,
    effect_entitlement_id = EDGE_ID .. "/idempotent",
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
}

local traces = restart_trace.array()
for _, obligation in ipairs(obligations) do
  local details = fixture_details[obligation.input_fixture_id]
  if details == nil then
    error("github-devloop: restart-trace-fixture-missing: missing fixture "
      .. obligation.input_fixture_id, 0)
  end
  local grant_fingerprint = NULL
  if #obligation.expected_effect_ids > 0 then
    grant_fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = "r9-issue-reconcile:" .. obligation.input_fixture_id,
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
        kind = "entry",
        source = { state = "thinking", boundary = QUEUE },
        target = "blocked",
        cause_evidence = {
          source_boundary = QUEUE,
        },
        cas_policy_id = CAS_POLICY_ID,
        cas_status = obligation.expected_decision.cas_status,
        reason_code = obligation.expected_decision.reason_code,
        cas_outcome = obligation.expected_decision.cas_outcome,
        pending_status = "excluded",
        generation_epoch = {
          current_version = details.current_version,
          incoming_version = details.incoming_version,
          generation = details.generation,
          lock_epoch = "r9-issue-reconcile:lock",
        },
        grant_fingerprint = grant_fingerprint,
        effect_entitlement_id = details.effect_entitlement_id,
        effect_ids = restart_trace.array(obligation.expected_effect_ids),
        queue = QUEUE,
        payload_obligations = restart_trace.array(
          obligation.expected_payload_obligations
        ),
        observable_writes = details.observable_writes,
        terminal_why = details.terminal_why,
      },
    }),
  }))
end

return traces
