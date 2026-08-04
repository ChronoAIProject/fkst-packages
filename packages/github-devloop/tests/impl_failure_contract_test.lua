local h = require("tests.devloop_core_helpers")
local payloads_builders = require("devloop.payloads.builders")

local core = h.core
local t = h.t

local function ready()
  return payloads_builders.build_devloop_ready_payload(core, h.reached())
end

local function legacy_failure(value, reason)
  return '<!-- fkst:github-devloop:impl-failure:v1 proposal="' .. value.proposal_id
    .. '" reason="' .. reason .. '" dedup="' .. value.dedup_key .. '" -->'
end

return {
  test_typed_failure_fact_round_trips_producer_retry_disposition = function()
    local value = ready()
    local failed = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "codex-failed", nil, "UNKNOWN", true)
    t.eq(core.has_impl_failure_marker({ failed }, value.proposal_id, value.dedup_key), true)
    t.eq(core.has_implementation_fact_marker({ failed }, value.proposal_id, value.dedup_key), true)

    local failed_fact = core.impl_failure_fact({ failed }, value.proposal_id, value.dedup_key)
    t.eq(failed_fact.attempt, 1)
    t.eq(failed_fact.fault_class, "UNKNOWN")
    t.eq(failed_fact.retryable, true)
    t.eq(core.impl_failure_retry_allowed(failed_fact), true)

    local retry_failed = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "codex-failed", 2, "UNKNOWN", true)
    local retry_fact = core.impl_failure_fact(
      { failed, retry_failed }, value.proposal_id, value.dedup_key)
    t.eq(retry_fact.reason, "codex-failed")
    t.eq(retry_fact.attempt, 2)
    t.eq(core.impl_failure_retry_allowed(retry_fact), false)

    local non_descendant = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "non-descendant-head", nil, "UNKNOWN", true)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ non_descendant }, value.proposal_id, value.dedup_key)), true)

    local local_iteration = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "local-iteration-failed", nil, "SEMANTIC", false)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ local_iteration }, value.proposal_id, value.dedup_key)), false)

    local base_local_iteration = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "base-local-iteration-failed", nil, "SEMANTIC", false)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ base_local_iteration }, value.proposal_id, value.dedup_key)), false)

    local unretryable = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "no-changes", nil, "UNKNOWN", false)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ unretryable }, value.proposal_id, value.dedup_key)), false)

    local explicit_override = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "codex-failed", nil, "INFRASTRUCTURE", false)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ explicit_override }, value.proposal_id, value.dedup_key)), false)

    local reason_independent = core.impl_failure_marker(
      value.proposal_id, value.dedup_key, "new-producer-reason", nil, "UNKNOWN", true)
    t.eq(core.impl_failure_retry_allowed(
      core.impl_failure_fact({ reason_independent }, value.proposal_id, value.dedup_key)), true)
  end,

  test_legacy_failure_facts_keep_the_bounded_v1_reason_policy = function()
    local value = ready()
    for _, reason in ipairs({ "codex-failed", "lean-proof-repair-needed", "non-descendant-head" }) do
      local legacy_fact = core.impl_failure_fact(
        { legacy_failure(value, reason) }, value.proposal_id, value.dedup_key)
      t.is_true(legacy_fact ~= nil)
      t.eq(legacy_fact.fault_class, nil)
      t.eq(legacy_fact.retryable, true)
      t.eq(core.impl_failure_retry_allowed(legacy_fact), true)
    end

    local legacy_nonretryable = core.impl_failure_fact(
      { legacy_failure(value, "local-iteration-failed") }, value.proposal_id, value.dedup_key)
    t.eq(legacy_nonretryable.retryable, false)
    t.eq(core.impl_failure_retry_allowed(legacy_nonretryable), false)
  end,
}
