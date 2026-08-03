local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core

local proposal_id = "github-devloop/issue/owner/repo/42"
local base_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local refusal_reasons = {
  "precursor-missing",
  "wrong-layer",
  "already-satisfied",
}

local function trusted_comment(body)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = "2026-06-03T01:02:03Z",
  }
end

local function refusal_comments(version, reason, refusal_attempt, author_login, implement_attempt)
  return {
    trusted_comment(h.state_marker(proposal_id, "blocked", version)),
    trusted_comment(core.implement_attempt_marker(
      proposal_id, version, implement_attempt or refusal_attempt, "100")),
    {
      body = core.implementation_refusal_marker(
        proposal_id, version, reason, "Worker-reported evidence.", refusal_attempt),
      author_login = author_login or core._test_bot_login,
      created_at = "2026-06-03T01:02:04Z",
    },
  }
end

return {
  test_supported_reason_contract_is_exact_ordered_and_copy_safe = function()
    local reasons = core.implementation_refusal_reasons()
    t.eq(#reasons, #refusal_reasons)
    for index, reason in ipairs(refusal_reasons) do
      t.eq(reasons[index], reason)
      t.eq(core.is_supported_implementation_refusal_reason(reason), true)
    end
    reasons[1] = "mutated"
    t.eq(core.implementation_refusal_reasons()[1], "precursor-missing")
    t.eq(core.is_supported_implementation_refusal_reason("Wrong-Layer"), false)
    t.eq(core.is_supported_implementation_refusal_reason("scope-mismatch"), false)
  end,

  test_supported_refusal_markers_round_trip_only_for_current_exact_lineage = function()
    for _, reason in ipairs(refusal_reasons) do
      local fact = core.implementation_refusal_fact(
        refusal_comments(base_version, reason, 1), proposal_id, base_version)
      t.is_true(fact ~= nil, reason)
      t.eq(fact.reason, reason, reason)
      t.eq(fact.attempt, 1, reason)
      t.eq(fact.evidence, "Worker-reported evidence.", reason)
    end
  end,

  test_same_version_second_attempt_refusal_uses_trusted_attempt_fact = function()
    local fact = core.implementation_refusal_fact(
      refusal_comments(base_version, "precursor-missing", 2), proposal_id, base_version)
    t.is_true(fact ~= nil)
    t.eq(fact.attempt, 2)
  end,

  test_refusal_fact_rejects_untrusted_malformed_stale_and_wrong_identity_markers = function()
    local valid = refusal_comments(base_version, "wrong-layer", 2)
    t.eq(core.implementation_refusal_fact(valid, proposal_id .. "/other", base_version), nil)
    t.eq(core.implementation_refusal_fact(valid, proposal_id, base_version .. "/other"), nil)

    local untrusted = refusal_comments(base_version, "wrong-layer", 2, "mallory")
    t.eq(core.implementation_refusal_fact(untrusted, proposal_id, base_version), nil)

    local stale = refusal_comments(base_version, "wrong-layer", 2)
    stale[1] = trusted_comment(h.state_marker(proposal_id, "blocked", base_version))
    t.eq(core.implementation_refusal_fact(stale, proposal_id, base_version .. "/other"), nil)

    local wrong_attempt = refusal_comments(base_version, "wrong-layer", 1, nil, 2)
    t.eq(core.implementation_refusal_fact(wrong_attempt, proposal_id, base_version), nil)

    local malformed = refusal_comments(base_version, "wrong-layer", 2)
    malformed[3].body = malformed[3].body:gsub('reason="wrong%-layer"', 'reason="Wrong-Layer"')
    t.eq(core.implementation_refusal_fact(malformed, proposal_id, base_version), nil)
  end,
}
