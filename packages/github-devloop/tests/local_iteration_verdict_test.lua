local h = require("tests.devloop_helpers")
local t = h.t
local verdict = require("departments.implement.local_iteration_verdict")

local base_sha = "1111111111111111111111111111111111111111"

local function result(kind, identities)
  return { kind = kind, failure_identities = identities or {} }
end

local function probe(fields)
  local value = {
    status = "completed",
    exit = 0,
    head_readback = base_sha,
    base_sha = base_sha,
    result = result("PASS"),
  }
  for key, field in pairs(fields or {}) do
    value[key] = field
  end
  return value
end

return {
  test_candidate_green_needs_no_base_probe = function()
    t.eq(verdict.classify(result("PASS"), nil), "GREEN")
  end,

  test_candidate_red_base_green_is_owned_local_red = function()
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), probe()), "OWN_LOCAL_RED")
  end,

  test_one_base_semantic_observation_is_indeterminate = function()
    local identity = { 'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"command":"python3 -B scripts/check_repo.py","kind":"check"}' }
    local first = probe({ exit = 2, result = result("SEMANTIC_FAIL", identity) })
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), first), "INDETERMINATE")
  end,

  test_two_matching_same_sha_base_semantic_observations_are_base_red = function()
    local identity = { 'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"command":"python3 -B scripts/check_repo.py","kind":"check"}' }
    local first = probe({ exit = 2, result = result("SEMANTIC_FAIL", identity) })
    local second = probe({ exit = 2, result = result("SEMANTIC_FAIL", identity) })
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), second, first), "BASE_RED")
  end,

  test_conflicting_same_sha_observations_are_indeterminate = function()
    local identity_a = { 'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"command":"check-a","kind":"check"}' }
    local identity_b = { 'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"command":"check-b","kind":"check"}' }
    local semantic_a = probe({ exit = 2, result = result("SEMANTIC_FAIL", identity_a) })
    local semantic_b = probe({ exit = 2, result = result("SEMANTIC_FAIL", identity_b) })
    local passing = probe()
    local setup_failure = probe({ exit = 1, result = result("CONFIGURATION_FAIL") })

    t.eq(verdict.classify(result("SEMANTIC_FAIL"), semantic_b, semantic_a), "INDETERMINATE")
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), passing, semantic_a), "INDETERMINATE")
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), setup_failure, semantic_a), "INDETERMINATE")
  end,

  test_untrusted_or_incomplete_base_probe_is_indeterminate = function()
    local candidate = result("SEMANTIC_FAIL")
    t.eq(verdict.classify(candidate, nil), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ status = "checkout-failed", exit = nil })), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ status = "command-failed", exit = nil })), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ status = "timeout", exit = 124 })), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ head_readback = "2222222222222222222222222222222222222222" })), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ base_sha = "2222222222222222222222222222222222222222" })), "INDETERMINATE")
    t.eq(verdict.classify(candidate, probe({ result = result("UNKNOWN") })), "INDETERMINATE")
  end,

  test_candidate_unknown_is_indeterminate_without_base_attribution = function()
    t.eq(verdict.classify(result("UNKNOWN"), probe()), "INDETERMINATE")
  end,

  test_typed_base_faults_have_exhaustive_non_attribution_dispositions = function()
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), probe({
      exit = 1,
      result = result("CONFIGURATION_FAIL"),
    })), "BASE_CONFIGURATION_FAIL")
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), probe({
      exit = 1,
      result = result("TOOLCHAIN_FAIL"),
    })), "BASE_TOOLCHAIN_FAIL")
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), probe({
      exit = 1,
      result = result("INFRASTRUCTURE_FAIL"),
    })), "BASE_INFRASTRUCTURE_FAIL")
  end,

  -- KNOWN v1 LIMITATION (open, three-point control deferred): when the raw base_sha
  -- probe is green but the candidate is red, v1 attributes it to the candidate
  -- (OWN_LOCAL_RED) even though the red could have been introduced by the harness
  -- delta substrate_pin.refresh commits into the candidate worktree before Codex
  -- (a "preparation red"). This is a strict improvement over the prior behavior
  -- (every red -> candidate) and never regresses it; splitting out PREPARATION_RED
  -- needs a pre-Codex "prepared" third control point, left to a follow-up. This test
  -- pins the current v1 attribution so the follow-up is a conscious, visible change.
  test_own_local_red_conflates_preparation_red_known_v1_limitation = function()
    t.eq(verdict.classify(result("SEMANTIC_FAIL"), probe()), "OWN_LOCAL_RED")
  end,
}
