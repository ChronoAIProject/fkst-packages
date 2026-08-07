local t = fkst.test

local function install_model(with_is_state)
  local rows = {
    {
      from_state = "broad-only",
      terminal = true,
      to_states = { "scoped-only" },
    },
    {
      from_state = "scoped-only",
      terminal = true,
      to_states = { "broad-only" },
    },
  }
  local model = {
    restart_lifecycle_states = { "scoped-only" },
    restart_transition_table = function()
      return rows
    end,
    restart_responsibility_inventory_errors = function()
      return {}
    end,
  }
  if with_is_state then
    model.is_state = function(state)
      return state == "broad-only"
    end
  end
  local workflow_ports = {
    dependency_release_marker = function() end,
    is_state = model.is_state,
    restart_lifecycle_states = model.restart_lifecycle_states,
    restart_responsibility_inventory_errors = model.restart_responsibility_inventory_errors,
    restart_transition_table = model.restart_transition_table,
    trusted_bot_login = function()
      return "test"
    end,
  }
  require("workflow_internal.restart_liveness_contract").install(model, {
    workflow_ports = workflow_ports,
  })
  local shared = require("workflow_internal.liveness.shared").install(model, {
    restart_package_name = "parity",
    liveness_signal_producers = {},
    workflow_ports = workflow_ports,
  })
  require("workflow_internal.liveness.contract").install(model, shared, {
    workflow_ports = workflow_ports,
  })
  return model, rows
end

local function assert_errors(actual, expected)
  t.eq(#actual, #expected)
  for index, item in ipairs(expected) do
    t.eq(actual[index], item.text, "error order/text at index " .. tostring(index))
    t.eq(#actual[index], item.bytes, "error byte length at index " .. tostring(index))
  end
end

return {
  test_scoped_totality_precedes_broader_successor_validity_byte_exact = function()
    local model, rows = install_model(true)
    assert_errors(model.liveness_contract_errors(rows), {
      {
        text = "broad-only: restart row is not a reachable lifecycle state",
        bytes = 58,
      },
      {
        text = "broad-only: unknown next state scoped-only",
        bytes = 42,
      },
    })
  end,

  test_absent_broader_state_predicate_skips_successor_validation_byte_exact = function()
    local model, rows = install_model(false)
    assert_errors(model.liveness_contract_errors(rows), {
      {
        text = "broad-only: restart row is not a reachable lifecycle state",
        bytes = 58,
      },
    })
  end,
}
