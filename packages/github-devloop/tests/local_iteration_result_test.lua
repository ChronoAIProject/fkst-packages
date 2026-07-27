local h = require("tests.devloop_helpers")
local t = h.t
local result = require("departments.implement.local_iteration_result")

local function classify(command_result)
  return result.from_command(command_result)
end

local function marker(outcome)
  return "FKST_LOCAL_ITERATION_RESULT:v1:" .. outcome .. "\n"
end

return {
  test_zero_exit_is_pass = function()
    local classified = classify({ exit_code = 0, stdout = "tests passed\n", stderr = "" })
    t.eq(classified.kind, "PASS")
    t.eq(classified.reason, "exit-zero")
  end,

  test_nonzero_requires_a_producer_semantic_failure_declaration = function()
    local classified = classify({
      exit_code = 2,
      stdout = "",
      stderr = marker("SEMANTIC_FAIL") .. "tests failed\n",
    })
    t.eq(classified.kind, "SEMANTIC_FAIL")
    t.eq(classified.reason, "producer-declared")
  end,

  test_untyped_nonzero_is_unknown = function()
    local classified = classify({ exit_code = 2, stdout = "", stderr = "report supervisor unavailable\n" })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "untyped-nonzero")
  end,

  test_producer_can_declare_unknown = function()
    local classified = classify({ exit_code = 2, stdout = marker("UNKNOWN"), stderr = "slot timeout\n" })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "producer-declared")
  end,

  test_conflicting_or_exit_inconsistent_declarations_are_unknown = function()
    local conflicting = classify({
      exit_code = 2,
      stdout = marker("SEMANTIC_FAIL"),
      stderr = marker("UNKNOWN"),
    })
    t.eq(conflicting.kind, "UNKNOWN")
    t.eq(conflicting.reason, "conflicting-declarations")

    local inconsistent = classify({ exit_code = 2, stdout = marker("PASS"), stderr = "" })
    t.eq(inconsistent.kind, "UNKNOWN")
    t.eq(inconsistent.reason, "exit-contract-mismatch")
  end,

  test_timeout_is_unknown_even_with_a_semantic_failure_declaration = function()
    local classified = classify({
      exit_code = 124,
      stdout = marker("SEMANTIC_FAIL"),
      stderr = "",
      timed_out = true,
    })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "timed-out")
  end,
}
