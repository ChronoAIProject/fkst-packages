local devloop_base = require("devloop.base")
local intake_capacity = require("core.intake_capacity")
local marker_builders = require("devloop.markers.builders")
local marker_facts = require("devloop.markers.facts")
local premise_correction = require("devloop.premise_correction")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local decline_dedup = "github-devloop/issue/owner/repo/42/intake/decline-1"
local decline_reason = "Production credentials are required.\nA human must authorize access."

local function trusted_comment(body, created_at)
  return {
    id = "IC_trusted_decline",
    body = body,
    author_login = devloop_base._test_bot_login,
    created_at = created_at or "2026-07-27T10:00:00Z",
  }
end

local function decline_comment(dedup_key, reason, created_at)
  local premise = premise_correction.premise_fingerprint(proposal_id, dedup_key, reason)
  return trusted_comment(
    marker_builders.intake_decision_marker(proposal_id, "decline", dedup_key, "standard", premise),
    created_at
  ), premise
end

local function correction_comment(premise, id, evidence, created_at, override)
  local correction = override or premise_correction.correction_fingerprint(id, evidence)
  return {
    id = id,
    body = tostring(evidence) .. '\n\n<!-- fkst:premise-correction:v1 premise="'
      .. tostring(premise) .. '" correction="' .. tostring(correction) .. '" -->',
    author_login = "ordinary-user",
    created_at = created_at or "2026-07-27T10:01:00Z",
  }, correction
end

return {
  test_premise_fingerprint_uses_proposal_decision_identity_and_full_normalized_reason = function()
    local fingerprint = premise_correction.premise_fingerprint(proposal_id, decline_dedup, decline_reason)
    t.is_true(premise_correction.is_premise_fingerprint(fingerprint))
    t.eq(
      fingerprint,
      premise_correction.premise_fingerprint(
        proposal_id,
        decline_dedup,
        "\r\nProduction credentials are required.  \r\nA human must authorize access.\r\n"
      )
    )
    t.is_true(fingerprint ~= premise_correction.premise_fingerprint(proposal_id, decline_dedup .. "-other", decline_reason))
    t.is_true(fingerprint ~= premise_correction.premise_fingerprint(proposal_id, decline_dedup, decline_reason .. "\nAnother fact."))
  end,

  test_decline_marker_fact_carries_premise_and_latest_decision_wins = function()
    local first, first_premise = decline_comment(decline_dedup, decline_reason, "2026-07-27T10:00:00Z")
    local second_dedup = decline_dedup .. "-second"
    local second, second_premise = decline_comment(second_dedup, "The corrected evidence is still insufficient.", "2026-07-27T10:02:00Z")
    local fact = marker_facts.intake_decision_fact({ first, second }, proposal_id)

    t.eq(fact.decision, "decline")
    t.eq(fact.dedup_key, second_dedup)
    t.eq(fact.premise_fingerprint, second_premise)
    t.is_true(first_premise ~= second_premise)
  end,

  test_correction_fact_is_bound_to_comment_id_and_surrounding_evidence = function()
    local _, premise = decline_comment(decline_dedup, decline_reason)
    local comment, correction = correction_comment(
      premise,
      "IC_correction_1",
      "The credential premise changed because the test now uses a fake adapter."
    )
    local fact = premise_correction.correction_comment_fact(comment)

    t.eq(fact.premise_fingerprint, premise)
    t.eq(fact.correction_fingerprint, correction)
    t.eq(fact.comment_id, "IC_correction_1")
    t.eq(fact.evidence, "The credential premise changed because the test now uses a fake adapter.")
    t.is_true(correction ~= premise_correction.correction_fingerprint("IC_correction_2", fact.evidence))
    t.is_true(correction ~= premise_correction.correction_fingerprint("IC_correction_1", fact.evidence .. " Updated."))
  end,

  test_correction_fingerprint_uses_sha256_for_collision_resistance = function()
    local first = premise_correction.correction_fingerprint(
      "IC_correction_collision",
      "Premise corrected: Aa"
    )
    local second = premise_correction.correction_fingerprint(
      "IC_correction_collision",
      "Premise corrected: B@"
    )

    t.eq(first, "correction-sha256-9204fac964c90fad886beacfea8a26788a43a6147cf76afaf11147e49d2ef5d1")
    t.eq(second, "correction-sha256-942abec6e24671ad31076cbd94f6e287459297b914ba99e702152d1f32defddf")
    t.is_true(first ~= second)
  end,

  test_correction_parser_rejects_malformed_mismatched_and_trusted_comments = function()
    local _, premise = decline_comment(decline_dedup, decline_reason)
    local mismatched = correction_comment(premise, "IC_bad", "Evidence.", nil, "correction-fp-1")
    t.is_nil(premise_correction.correction_comment_fact(mismatched))
    t.is_nil(premise_correction.correction_comment_fact({
      id = "IC_malformed",
      body = '<!-- fkst:premise-correction:v1 premise="' .. premise .. '" -->',
      author_login = "ordinary-user",
      created_at = "2026-07-27T10:01:00Z",
    }))
    local trusted = correction_comment(premise, "IC_trusted", "Evidence.")
    trusted.author_login = devloop_base._test_bot_login
    t.is_nil(premise_correction.correction_comment_fact(trusted))
  end,

  test_pending_correction_requires_latest_decline_exact_premise_and_later_time = function()
    local decline, premise = decline_comment(decline_dedup, decline_reason, "2026-07-27T10:00:00Z")
    local older = correction_comment(premise, "IC_older", "Older evidence.", "2026-07-27T09:59:59Z")
    local wrong = correction_comment("premise-fp-123", "IC_wrong", "Wrong premise.", "2026-07-27T10:01:00Z")
    local matching, correction = correction_comment(premise, "IC_match", "Corrected evidence.", "2026-07-27T10:02:00Z")
    local decline_fact = marker_facts.intake_decision_fact({ decline, older, wrong, matching }, proposal_id)
    local fact = premise_correction.matching_correction_fact({ decline, older, wrong, matching }, decline_fact)

    t.eq(fact.correction_fingerprint, correction)

    local current = {
      number = 42,
      state = "OPEN",
      labels = {},
      comments = { decline, matching },
    }
    t.is_true(intake_capacity.issue_occupies_capacity("owner/repo", current))

    local redecline = decline_comment(
      premise_correction.decision_dedup_key(devloop_base.intake_decision_dedup_key(proposal_id, current), {
        premise_fingerprint = premise,
        correction_fingerprint = correction,
      }),
      "The corrected evidence still does not establish safe automation.",
      "2026-07-27T10:03:00Z"
    )
    local latest = marker_facts.intake_decision_fact({ decline, matching, redecline }, proposal_id)
    t.is_nil(premise_correction.matching_correction_fact({ decline, matching, redecline }, latest))
  end,
}
