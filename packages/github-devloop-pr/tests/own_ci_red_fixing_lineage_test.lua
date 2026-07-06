local requests_review = require("devloop.requests.review")
local payloads_builders = require("devloop.payloads.builders")
local m_facts = require("devloop.markers.facts")
local v_fixing = require("devloop.validators.fixing")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local merge_ready = h.merge_ready

local function replay_payload(event, ci_failure_key)
  return payloads_builders.build_replayed_fixing_payload({
    proposal_id = event.proposal_id,
    impl_version = event.version,
  }, event.pr_number, {
    review_proposal_id = event.review_proposal_id,
    review_dedup_key = event.review_dedup_key,
    reviewed_head_sha = event.reviewed_head_sha,
    blocking_gap = "own-ci-red",
    gate_baseline_sha = "ba5e9999",
    ci_failure_key = ci_failure_key,
    review_reason = "own-ci-red",
  }, event.source_ref)
end

return {
  test_own_ci_red_fixing_lineage_is_keyed_by_failing_check_run = function()
    local event = merge_ready()
    local fix_version = core.fix_version_from_review_version(event.version)
    local first_key = "check-run/test/1001/def456/COMPLETED/FAILURE"
    local second_key = "check-run/test/1002/def456/COMPLETED/FAILURE"
    local request = requests_review.build_merge_gate_fix_comment_request(core,
      "owner/repo",
      "42",
      event,
      fix_version,
      "own-ci-red",
      "ba5e9999",
      event.source_ref,
      "none",
      {
        ci_failure_key = first_key,
      }
    )

    t.eq(request.handoff.ci_failure_key, first_key)
    local fact = m_facts.merge_gate_fix_fact({ request.body }, event.proposal_id, request.handoff.version)
    t.eq(fact.ci_failure_key, first_key)

    local first = replay_payload(event, first_key)
    local same = replay_payload(event, first_key)
    local changed = replay_payload(event, second_key)

    t.eq(first.dedup_key, same.dedup_key)
    t.is_true(first.dedup_key ~= changed.dedup_key)
    t.is_true(first.dedup_key:find("/" .. first_key, 1, true) ~= nil)
    t.is_true(changed.dedup_key:find("/" .. second_key, 1, true) ~= nil)
    t.eq(first.ci_failure_key, first_key)
    t.eq(v_fixing.is_supported_fixing(first), true)
    t.eq(v_fixing.is_supported_fixing(changed), true)
  end,
}
