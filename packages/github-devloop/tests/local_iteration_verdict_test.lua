local h = require("tests.devloop_helpers")
local t = h.t
local verdict = require("departments.implement.local_iteration_verdict")

local base_sha = "1111111111111111111111111111111111111111"

local function probe(fields)
  local value = {
    status = "completed",
    exit = 0,
    head_readback = base_sha,
    base_sha = base_sha,
  }
  for key, field in pairs(fields or {}) do
    value[key] = field
  end
  return value
end

return {
  test_candidate_green_needs_no_base_probe = function()
    t.eq(verdict.classify(0, nil), "GREEN")
  end,

  test_candidate_red_base_green_is_owned_local_red = function()
    t.eq(verdict.classify(1, probe()), "OWN_LOCAL_RED")
  end,

  test_candidate_red_base_red_is_base_red = function()
    t.eq(verdict.classify(1, probe({ exit = 2 })), "BASE_RED")
  end,

  test_untrusted_or_incomplete_base_probe_is_indeterminate = function()
    t.eq(verdict.classify(1, nil), "INDETERMINATE")
    t.eq(verdict.classify(1, probe({ status = "checkout-failed", exit = nil })), "INDETERMINATE")
    t.eq(verdict.classify(1, probe({ status = "command-failed", exit = nil })), "INDETERMINATE")
    t.eq(verdict.classify(1, probe({ status = "timeout", exit = 124 })), "INDETERMINATE")
    t.eq(verdict.classify(1, probe({ head_readback = "2222222222222222222222222222222222222222" })), "INDETERMINATE")
    t.eq(verdict.classify(1, probe({ base_sha = "2222222222222222222222222222222222222222" })), "INDETERMINATE")
  end,

  test_explicit_non_timeout_exit_124_is_base_red = function()
    t.eq(verdict.classify(1, probe({ exit = 124, timed_out = false })), "BASE_RED")
  end,
}
