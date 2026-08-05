local observation = require("testkit_internal.old_behavior_observation_support")
local obligations = require("core.restart.issue_reconcile_obligations")
local h = require("tests.devloop_core_helpers")

local t = h.t
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/issue-reconcile.json"

local function fixture_index(fixtures)
  local result = {}
  for _, fixture in ipairs(fixtures) do
    result[fixture.fixture_id] = fixture
  end
  return result
end

return {
  test_issue_reconcile_obligations_link_cas_matrix_to_frozen_parity = function()
    local corpus = json.decode(file.read(CORPUS_PATH))
    local fixtures = fixture_index(corpus.fixtures)
    t.eq(#obligations, #corpus.fixtures)

    for _, obligation in ipairs(obligations) do
      local fixture = fixtures[obligation.input_fixture_id]
      t.is_true(fixture ~= nil, obligation.obligation_id .. ": frozen witness fixture")
      t.eq(obligation.owner, corpus.owner, obligation.obligation_id .. ": owner")
      t.eq(obligation.edge_id, fixture.edge_id, obligation.obligation_id .. ": edge")
      t.eq(obligation.case_kind, "cas-matrix", obligation.obligation_id .. ": case kind")
      t.eq(
        observation.canonical_json(obligation.expected_decision),
        observation.canonical_json({
          cas_status = fixture.cas_status,
          reason_code = fixture.reason_code,
          cas_outcome = fixture.cas_outcome,
        }),
        obligation.obligation_id .. ": expected decision"
      )
      t.eq(#obligation.expected_effect_ids, #fixture.granted_effect_ids)
      for ordinal, effect_id in ipairs(obligation.expected_effect_ids) do
        t.eq(effect_id, fixture.granted_effect_ids[ordinal])
      end
      t.eq(#obligation.expected_payload_obligations, #fixture.observable_writes)
      for ordinal, payload_obligation in ipairs(obligation.expected_payload_obligations) do
        t.eq(payload_obligation.effect_id, fixture.observable_writes[ordinal].effect_id)
        t.eq(payload_obligation.equality, "byte-exact-frozen-old")
      end
      t.eq(
        obligation.witness_id,
        CORPUS_PATH .. "#" .. obligation.input_fixture_id,
        obligation.obligation_id .. ": witness"
      )
    end
  end,
}
