local support = require("testkit_internal.old_behavior_observation_support")

local t = fkst.test

local function array(values)
  return support.json_array(values)
end

local function authorization(atom)
  return {
    cause = "R11.queue_dialogue_to_sync_consensus_call",
    changed_row_ids = array(),
    changed_edge_ids = array({ "edge:test/consensus-delivery" }),
    changed_policy_ids = array(),
    authorized_delivery_atoms = array({
      {
        observation_id = "edge:test/consensus-delivery",
        remove = array({ "queue:consensus.proposal" }),
        add = array({ atom or "raise:devloop_consensus_request" }),
      },
    }),
  }
end

local function old_record()
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = "edge:test/consensus-delivery",
    owner = "github-devloop",
    site = {
      path = "packages/github-devloop/departments/example/main.lua",
      symbol = "pipeline",
      ordinal = "consensus.proposal",
    },
    boundary = "writer",
    typed_intent = {
      kind = "published_intent",
      source_state = "thinking",
      source_boundary = "github-proxy.github_entity_changed",
      target = "consensus.proposal",
    },
    old_inputs = {
      current_fact = { state = "thinking", version = "v1" },
      caller_from_states = array({ "thinking" }),
      incoming_version = "v1",
      target_version = "v1",
      handoff_reference = support.JSON_NULL,
    },
    old_outcome = {
      status = "raised",
      reason_code = "proposal-ready",
      cas_outcome = "applied",
      reply = { status = "reached", decision = "approve" },
      saga_transitions = array({
        { from_state = "thinking", to_state = "ready", ordinal = 1 },
      }),
      emitted_effects = array({
        {
          effect_id = "queue:consensus.proposal",
          sink_kind = "queue",
          authority_class = "lifecycle-authoritative",
          ordinal = 1,
        },
        {
          effect_id = "comment:issue:thinking-state",
          sink_kind = "comment",
          authority_class = "lifecycle-authoritative",
          ordinal = 2,
        },
      }),
      observable_writes = array({
        {
          effect_id = "queue:consensus.proposal",
          queue = "consensus.proposal",
          payload = { schema = "consensus.proposal.v1", proposal_id = "p1" },
        },
        {
          effect_id = "comment:issue:thinking-state",
          queue = "github-proxy.github_issue_comment_request",
          payload = {
            body = "<!-- fkst:github-devloop:state:v1 state=\"thinking\" version=\"v1\" -->",
          },
        },
      }),
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = support.JSON_NULL,
    },
    evidence_refs = array({
      { kind = "runtime-raise-capture", ref = "consensus.proposal" },
    }),
  }
end

local function new_record()
  local record = support.copy_value(old_record())
  record.site.ordinal = "devloop_consensus_request"
  record.typed_intent.target = "devloop_consensus_request"
  record.old_outcome.emitted_effects[1].effect_id =
    "queue:github-devloop.devloop_consensus_request"
  record.old_outcome.observable_writes[1].effect_id =
    "queue:github-devloop.devloop_consensus_request"
  record.old_outcome.observable_writes[1].queue = "devloop_consensus_request"
  record.evidence_refs[1].ref = "devloop_consensus_request"
  return record
end

local function assert_rejected(records, auth, label)
  local ok = pcall(
    support.assert_old_behavior_records,
    records,
    array({ old_record() }),
    label,
    auth
  )
  t.is_true(not ok, label .. " must remain outside delivery authorization")
end

return {
  test_r11_delivery_authorization_cannot_hide_product_or_unlisted_delivery_regressions = function()
    local expected = array({ old_record() })
    local actual = array({ new_record() })
    support.assert_old_behavior_records(actual, expected, "authorized delivery control", authorization())

    local reply_drift = support.copy_value(actual)
    reply_drift[1].old_outcome.reply.decision = "reject"
    assert_rejected(reply_drift, authorization(), "reply drift")

    local transition_drift = support.copy_value(actual)
    transition_drift[1].old_outcome.saga_transitions[1].to_state = "blocked"
    assert_rejected(transition_drift, authorization(), "transition drift")

    local marker_drift = support.copy_value(actual)
    marker_drift[1].old_outcome.observable_writes[2].payload.body =
      "<!-- fkst:github-devloop:state:v1 state=\"blocked\" version=\"v1\" -->"
    assert_rejected(marker_drift, authorization(), "marker drift")

    local cas_drift = support.copy_value(actual)
    cas_drift[1].old_outcome.cas_outcome = "skip-stale"
    assert_rejected(cas_drift, authorization(), "CAS drift")

    local delivery_drift = support.copy_value(actual)
    delivery_drift[1].old_outcome.emitted_effects[1].effect_id = "queue:unlisted.delivery"
    assert_rejected(delivery_drift, authorization(), "unlisted delivery drift")

    assert_rejected(actual, authorization("marker:state-payload"), "non-delivery manifest atom")
  end,
}
