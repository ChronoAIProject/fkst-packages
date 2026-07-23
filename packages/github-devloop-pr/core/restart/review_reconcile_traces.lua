local restart_trace = require("devloop.restart_trace")
local obligations = require("core.restart.review_reconcile_obligations")
local transition_version = require("contract.transition_version")

local OWNER = "github-devloop-pr"
local EDGE_ID = OWNER .. "/reviewing/entry/review_reconcile_true_stall"
local CAS_POLICY_ID = "cas.legacy_issue_reconcile_v1"
local QUEUE = "devloop_review_reconcile"
local WITNESS_PREFIX = "migration/restart-lifecycle.inventory.json#"
local NULL = restart_trace.null

local BASE_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local INCOMING_VERSION = transition_version.review_loop_at(BASE_VERSION, 3)
local FIXING_VERSION = transition_version.next_fix(BASE_VERSION)

local fixture_details = {
  apply = {
    current_version = BASE_VERSION,
    effect_entitlement_id = EDGE_ID .. "/apply",
    observable_writes = restart_trace.array({
      {
        effect_id = "github-proxy.github_pr_comment_request",
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
    terminal_why = { terminal_cause = "no-semantic-progress" },
  },
  ["already-terminal"] = {
    current_version = INCOMING_VERSION,
    effect_entitlement_id = EDGE_ID .. "/idempotent",
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
  ["review-reconcile-marker-visible"] = {
    current_version = INCOMING_VERSION,
    effect_entitlement_id = EDGE_ID .. "/idempotent",
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
  ["state-advanced"] = {
    current_version = FIXING_VERSION,
    effect_entitlement_id = NULL,
    observable_writes = restart_trace.array(),
    terminal_why = NULL,
  },
}

local traces = restart_trace.array()
for _, obligation in ipairs(obligations) do
  local fixture_id = obligation.input_fixture_id
  local details = fixture_details[fixture_id]
  if details == nil then
    error("github-devloop-pr: restart-trace-fixture-missing: missing fixture "
      .. fixture_id, 0)
  end
  local grant_fingerprint = NULL
  if #obligation.expected_effect_ids > 0 then
    grant_fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = "r9-pr-review-reconcile|" .. fixture_id,
      edge_id = EDGE_ID,
      effect_entitlement_id = details.effect_entitlement_id,
    })
  end
  table.insert(traces, restart_trace.define({
    schema = "restart-trace.v1",
    owner = OWNER,
    fixture_id = fixture_id,
    steps = restart_trace.array({
      {
        edge_id = EDGE_ID,
        row_replay_id = NULL,
        kind = "entry",
        source = { state = "reviewing", boundary = QUEUE },
        target = "blocked",
        cause_evidence = {
          source_boundary = QUEUE,
          frozen_observation_id = obligation.witness_id:sub(#WITNESS_PREFIX + 1),
          frozen_status = obligation.expected_decision.frozen_status,
          frozen_reason_code = obligation.expected_decision.frozen_reason_code,
          frozen_cas_outcome = obligation.expected_decision.frozen_cas_outcome,
        },
        cas_policy_id = CAS_POLICY_ID,
        cas_status = obligation.expected_decision.cas_status,
        reason_code = obligation.expected_decision.reason_code,
        cas_outcome = obligation.expected_decision.cas_outcome,
        pending_status = "excluded",
        generation_epoch = {
          current_version = details.current_version,
          incoming_version = INCOMING_VERSION,
          generation = details.current_version,
          lock_epoch = "r9-pr-review-reconcile@" .. details.current_version,
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
