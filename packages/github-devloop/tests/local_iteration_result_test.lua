local h = require("tests.devloop_helpers")
local t = h.t
local result = require("departments.implement.local_iteration_result")
local failure_identity = require("devloop.local_iteration_failure_identity")

local function classify(command_result)
  return result.from_command(command_result)
end

local function marker(verdict, fault_class)
  return "FKST_LOCAL_ITERATION_RESULT:v2:" .. verdict .. ":" .. fault_class .. "\n"
end

local function identity(value)
  return "FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:" .. value .. "\n"
end

return {
  test_markerless_zero_is_unknown = function()
    local classified = classify({ exit_code = 0, stdout = "tests passed\n", stderr = "" })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.fault_class, "UNKNOWN")
    t.eq(classified.reason, "missing-declaration")
  end,

  test_zero_exit_requires_a_producer_pass_declaration = function()
    local classified = classify({ exit_code = 0, stdout = marker("PASS", "NONE"), stderr = "" })
    t.eq(classified.kind, "PASS")
    t.eq(classified.fault_class, "NONE")
    t.eq(classified.reason, "producer-declared")
  end,

  test_nonzero_requires_a_producer_semantic_failure_declaration = function()
    local classified = classify({
      exit_code = 2,
      stdout = "",
      stderr = marker("FAIL", "SEMANTIC") .. "tests failed\n",
    })
    t.eq(classified.kind, "SEMANTIC_FAIL")
    t.eq(classified.fault_class, "SEMANTIC")
    t.eq(classified.reason, "producer-declared")
  end,

  test_semantic_failure_identities_are_validated_sorted_and_deduplicated = function()
    local check = '{"kind":"check","command":"python3 -B scripts/check_repo.py"}'
    local test = '{"kind":"test","owner_namespace":"github-devloop","file":"tests/a_test.lua","name":"test_a","failure_kind":"assertion_failure"}'
    local classified = classify({
      exit_code = 1,
      stdout = identity(test) .. identity(check),
      stderr = marker("FAIL", "SEMANTIC") .. identity(test),
    })

    t.eq(classified.kind, "SEMANTIC_FAIL")
    t.eq(#classified.failure_identities, 2)
    t.eq(classified.failure_identities[1],
      'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"command":"python3 -B scripts/check_repo.py","kind":"check"}')
    t.eq(classified.failure_identities[2],
      'FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:{"failure_kind":"assertion_failure","file":"tests/a_test.lua","kind":"test","name":"test_a","owner_namespace":"github-devloop"}')
  end,

  test_invalid_failure_identity_makes_the_observation_unknown = function()
    local classified = classify({
      exit_code = 1,
      stdout = identity('{"kind":"test","owner_namespace":"github-devloop"}'),
      stderr = marker("FAIL", "SEMANTIC"),
    })

    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "invalid-failure-identity")
  end,

  test_complete_control_line_is_the_identity_size_contract = function()
    local long_file = "tests/" .. string.rep("nested/", 30) .. "example_test.lua"
    local classified = classify({
      exit_code = 1,
      stdout = identity('{"kind":"test","owner_namespace":"github-devloop","file":"'
        .. long_file .. '","name":"test_example","failure_kind":"assertion_failure"}'),
      stderr = marker("FAIL", "SEMANTIC"),
    })

    t.eq(classified.kind, "SEMANTIC_FAIL")
    t.eq(#classified.failure_identities, 1)
  end,

  test_oversized_failure_identity_is_preserved = function()
    local long_identity = identity('{"kind":"check","command":"' .. string.rep("x", 2000) .. '"}')
    local canonical_identity = identity('{"command":"' .. string.rep("x", 2000) .. '","kind":"check"}')
    local classified = classify({
      exit_code = 1,
      stdout = long_identity,
      stderr = marker("FAIL", "SEMANTIC"),
    })

    t.eq(classified.kind, "SEMANTIC_FAIL")
    t.eq(#classified.failure_identities, 1)
    t.eq(classified.failure_identities[1], canonical_identity:sub(1, -2))
  end,

  test_failure_identity_set_beyond_the_comment_request_budget_is_unknown = function()
    local lines = {}
    for index = 1, failure_identity.max_set_size + 1 do
      lines[#lines + 1] = identity('{"kind":"test","owner_namespace":"github-devloop","file":"tests/example_test.lua",'
        .. '"name":"test_' .. tostring(index) .. string.rep("x", 150)
        .. '","failure_kind":"assertion_failure"}')
    end
    local classified = classify({
      exit_code = 1,
      stdout = table.concat(lines),
      stderr = marker("FAIL", "SEMANTIC"),
    })

    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "failure-identity-set-too-large")
  end,

  test_typed_nonsemantic_failures_preserve_the_producer_fault_class = function()
    local expected = {
      CONFIGURATION = "CONFIGURATION_FAIL",
      TOOLCHAIN = "TOOLCHAIN_FAIL",
      INFRASTRUCTURE = "INFRASTRUCTURE_FAIL",
    }
    for fault_class, kind in pairs(expected) do
      local classified = classify({
        exit_code = 1,
        stdout = "",
        stderr = marker("FAIL", fault_class),
      })
      t.eq(classified.kind, kind)
      t.eq(classified.fault_class, fault_class)
      t.eq(classified.reason, "producer-declared")
    end
  end,

  test_untyped_nonzero_is_unknown = function()
    local classified = classify({ exit_code = 2, stdout = "", stderr = "report supervisor unavailable\n" })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.fault_class, "UNKNOWN")
    t.eq(classified.reason, "untyped-nonzero")
  end,

  test_producer_can_declare_unknown = function()
    local classified = classify({ exit_code = 2, stdout = marker("UNKNOWN", "UNKNOWN"), stderr = "slot timeout\n" })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.fault_class, "UNKNOWN")
    t.eq(classified.reason, "producer-declared")
  end,

  test_conflicting_or_exit_inconsistent_declarations_are_unknown = function()
    local conflicting = classify({
      exit_code = 2,
      stdout = marker("FAIL", "SEMANTIC"),
      stderr = marker("UNKNOWN", "UNKNOWN"),
    })
    t.eq(conflicting.kind, "UNKNOWN")
    t.eq(conflicting.reason, "conflicting-declarations")

    local inconsistent = classify({ exit_code = 2, stdout = marker("PASS", "NONE"), stderr = "" })
    t.eq(inconsistent.kind, "UNKNOWN")
    t.eq(inconsistent.reason, "exit-contract-mismatch")
  end,

  test_duplicate_or_invalid_declarations_are_unknown = function()
    local duplicate = classify({
      exit_code = 1,
      stdout = marker("FAIL", "SEMANTIC"),
      stderr = marker("FAIL", "SEMANTIC"),
    })
    t.eq(duplicate.kind, "UNKNOWN")
    t.eq(duplicate.reason, "duplicate-declarations")

    local invalid_pair = classify({ exit_code = 1, stdout = marker("PASS", "SEMANTIC"), stderr = "" })
    t.eq(invalid_pair.kind, "UNKNOWN")
    t.eq(invalid_pair.reason, "invalid-declaration")

    local stale_version = classify({
      exit_code = 1,
      stdout = "FKST_LOCAL_ITERATION_RESULT:v1:SEMANTIC_FAIL\n",
      stderr = "",
    })
    t.eq(stale_version.kind, "UNKNOWN")
    t.eq(stale_version.reason, "invalid-declaration")
  end,

  test_timeout_is_unknown_even_with_a_semantic_failure_declaration = function()
    local classified = classify({
      exit_code = 124,
      stdout = marker("FAIL", "SEMANTIC"),
      stderr = "",
      timed_out = true,
    })
    t.eq(classified.kind, "UNKNOWN")
    t.eq(classified.reason, "timed-out")
  end,
}
