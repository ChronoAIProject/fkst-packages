local core = require("core")
local observation = require("testkit_internal.old_behavior_observation_support")
local sha256 = require("contract.sha256")
local t = fkst.test
local EXPECTED_DIGEST = "cc59dcf98928c5ed1ec6090e619fd0a595568ecf863b6f16d3bdd953168c4fc9"

local copy_value = require("testkit_internal.values").copy_value

local function rows_by_state(rows)
  local indexed = {}
  for _, row in ipairs(rows) do
    indexed[row.from_state] = row
  end
  return indexed
end

local function restart_digest(rows)
  return sha256.hex(observation.canonical_json(rows))
end

local function assert_mutation_changes_digest(mutate)
  local rows = copy_value(core.restart_transition_table())
  mutate(rows, rows_by_state(rows))
  t.is_true(restart_digest(rows) ~= EXPECTED_DIGEST)
end

return {
  test_restart_policy_is_a_typed_private_kernel = function()
    local policy = assert(rawget(core, "restart_policy"), "missing typed restart policy")
    t.eq(core.restart_transition_table, policy.restart_transition_table)
    t.eq(core.maybe_timeout_redrive_from_table, policy.maybe_timeout_redrive_from_table)
    t.eq(require("devloop.restart").install, nil)
    t.eq(require("devloop.liveness").install, nil)
    t.eq(require("devloop.restart.pr_review_replay_facts").install, nil)
  end,

  test_restart_transition_table_bytes_are_frozen = function()
    t.eq(restart_digest(core.restart_transition_table()), EXPECTED_DIGEST)
  end,

  test_restart_transition_table_digest_rejects_successor_change = function()
    assert_mutation_changes_digest(function(_, by_state)
      by_state.ready.to_states[2] = "declined"
    end)
  end,

  test_restart_transition_table_digest_rejects_budget_change = function()
    assert_mutation_changes_digest(function(_, by_state)
      by_state.ready.budget.minutes = by_state.ready.budget.minutes + 1
    end)
  end,

  test_restart_transition_table_digest_rejects_function_replacement = function()
    assert_mutation_changes_digest(function(_, by_state)
      by_state.ready.payload_builder_symbol = "devloop.payloads.builders.build_proposal"
    end)
  end,

  test_restart_transition_table_digest_rejects_function_swap = function()
    assert_mutation_changes_digest(function(_, by_state)
      by_state.ready.payload_builder_symbol, by_state.thinking.payload_builder_symbol =
        by_state.thinking.payload_builder_symbol, by_state.ready.payload_builder_symbol
    end)
  end,

  test_restart_transition_table_digest_rejects_row_removal = function()
    assert_mutation_changes_digest(function(rows)
      table.remove(rows, #rows)
    end)
  end,
}
