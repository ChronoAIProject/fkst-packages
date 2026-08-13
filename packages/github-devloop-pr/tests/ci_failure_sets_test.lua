local h = require("tests.devloop_helpers")
local t = h.t

local BASE_SHA = string.rep("a", 40)
local HEAD_SHA = string.rep("b", 40)
local CANDIDATE_SHA = HEAD_SHA

local function failure(name)
  return {
    owner_namespace = "github-devloop-pr",
    file = "tests/example_test.lua",
    name = name,
  }
end

local function manifest(fields)
  return {
    schema = "fkst.test.failure-set.v1",
    event_name = fields.event_name or "push",
    tested_commit = fields.tested_commit,
    complete = fields.complete ~= false,
    report_count = fields.report_count or 1,
    failures = fields.failures or {},
    base_commit = fields.base_commit,
    head_commit = fields.head_commit,
  }
end

local function compare(base_failures, candidate_failures)
  local ci_failure_sets = require("core.ci_failure_sets")
  return ci_failure_sets.compare_manifests(
    manifest({ tested_commit = BASE_SHA, failures = base_failures }),
    manifest({
      event_name = "pull_request",
      tested_commit = CANDIDATE_SHA,
      base_commit = BASE_SHA,
      head_commit = HEAD_SHA,
      failures = candidate_failures,
    }),
    { base_commit = BASE_SHA, head_commit = HEAD_SHA }
  )
end

return {
  test_failure_identity_is_commit_independent = function()
    local ci_failure_sets = require("core.ci_failure_sets")
    local first = failure("test_same_assertion")
    local second = failure("test_same_assertion")
    first.tested_commit = BASE_SHA
    second.tested_commit = CANDIDATE_SHA
    t.eq(ci_failure_sets.failure_identity(first), ci_failure_sets.failure_identity(second))
  end,

  test_equal_failure_sets_are_base_inherited = function()
    local result = compare({ failure("test_k") }, { failure("test_k") })
    t.eq(result.kind, "no-new-failing-identity")
    t.eq(result.base_commit, BASE_SHA)
    t.eq(result.tested_candidate_commit, CANDIDATE_SHA)
  end,

  test_candidate_only_failure_is_diff_caused = function()
    local result = compare({ failure("test_k") }, { failure("test_k_prime") })
    t.eq(result.kind, "new-failing-identity")
    t.eq(#result.new_failures, 1)
  end,

  test_mixed_inherited_and_new_failures_is_diff_caused = function()
    local result = compare({ failure("test_k") }, { failure("test_k"), failure("test_k_prime") })
    t.eq(result.kind, "new-failing-identity")
    t.eq(#result.new_failures, 1)
    t.eq(result.new_failures[1].name, "test_k_prime")
  end,

  test_failure_identity_rejects_non_string_fields = function()
    local malformed = failure("test_k")
    malformed.name = 42
    t.eq(require("core.ci_failure_sets").failure_identity(malformed), nil)
  end,

  test_missing_identity_evidence_is_unknown = function()
    local ci_failure_sets = require("core.ci_failure_sets")
    local result = ci_failure_sets.compare_manifests(nil, nil, {})
    t.eq(result.kind, "UNKNOWN")
  end,

  test_mismatched_candidate_association_is_unknown = function()
    local result = compare({ failure("test_k") }, { failure("test_k") })
    result = require("core.ci_failure_sets").compare_manifests(
      manifest({ tested_commit = BASE_SHA, failures = { failure("test_k") } }),
      manifest({
        event_name = "pull_request",
        tested_commit = CANDIDATE_SHA,
        base_commit = string.rep("d", 40),
        head_commit = HEAD_SHA,
        failures = { failure("test_k") },
      }),
      { base_commit = BASE_SHA, head_commit = HEAD_SHA }
    )
    t.eq(result.kind, "UNKNOWN")
  end,

  test_missing_report_count_is_unknown = function()
    local base = manifest({ tested_commit = BASE_SHA, failures = { failure("test_k") } })
    base.report_count = nil
    local result = require("core.ci_failure_sets").compare_manifests(
      base,
      manifest({
        event_name = "pull_request",
        tested_commit = CANDIDATE_SHA,
        base_commit = BASE_SHA,
        head_commit = HEAD_SHA,
        failures = { failure("test_k") },
      }),
      { base_commit = BASE_SHA, head_commit = HEAD_SHA }
    )
    t.eq(result.kind, "UNKNOWN")
  end,

}
