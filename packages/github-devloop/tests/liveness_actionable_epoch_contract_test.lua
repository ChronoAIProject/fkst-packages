local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for key, nested in pairs(value) do
    copied[key] = copy_value(nested)
  end
  return copied
end

local function copy_rows(rows)
  local copied = {}
  for index, row in ipairs(rows or {}) do
    copied[index] = copy_value(row)
  end
  return copied
end

local function rows_by_state(rows)
  local by_state = {}
  for _, row in ipairs(rows or {}) do
    by_state[row.from_state] = row
  end
  return by_state
end

local function has_error(errors, needle)
  local joined = table.concat(errors or {}, "\n")
  return joined:find(needle, 1, true) ~= nil
end

local function state_errors(records, state)
  local selected = {}
  for _, record in ipairs(records or {}) do
    if type(record) == "table" and record.state == state then
      table.insert(selected, record.message)
    end
  end
  return selected
end

return {
  test_actionable_epoch_source_registry_declares_primitives = function()
    local sources = core.restart_actionable_epoch_sources()
    local expected = {
      ["state_entry:v1"] = {
        excludes_deferred_time = false,
        allowed_when = "no_defer_possible",
      },
      ["liveness_substate_entry:v1"] = {
        excludes_deferred_time = true,
        allowed_when = "hierarchical_liveness_substate",
      },
      ["defer_clear_fact:v1"] = {
        excludes_deferred_time = true,
        allowed_when = "defer_clear_fact",
        requires_clear_fact = true,
      },
      ["live_defer_epoch:v1"] = {
        excludes_deferred_time = true,
        allowed_when = "live_defer_with_clear_fact",
        requires_live_marker = true,
        requires_clear_fact = true,
        requires_observed_fact = true,
      },
    }
    for source, spec in pairs(expected) do
      local contract = sources[source]
      t.is_true(contract ~= nil, source)
      t.eq(contract.durable, true)
      t.eq(contract.opens_generation, true)
      t.eq(contract.excludes_deferred_time, spec.excludes_deferred_time)
      t.eq(contract.allowed_when, spec.allowed_when)
      t.eq(contract.requires_live_marker, spec.requires_live_marker)
      t.eq(contract.requires_clear_fact, spec.requires_clear_fact)
      t.eq(contract.requires_observed_fact, spec.requires_observed_fact)
    end
  end,

  test_default_conformance_passes_only_through_exact_liveness_inventory = function()
    t.eq(#core.liveness_contract_errors(), 0)
    local inventory = core.known_liveness_contract_violations()
    t.eq(table.concat(inventory, ","), "implementing,ready,reviewing,thinking")
    local records = core.strict_liveness_contract_error_records()
    for _, state in ipairs(inventory) do
      local errors = state_errors(records, state)
      t.is_true(#errors >= 1, state)
      t.is_true(has_error(errors, "state_entry:v1 is only allowed when no defer is possible"), state)
    end
  end,

  test_strict_conformance_flags_current_live_defer_rows = function()
    local errors = core.strict_liveness_contract_errors()
    t.is_true(has_error(errors, "ready: state_entry:v1 is only allowed when no defer is possible"))
    t.is_true(has_error(errors, "reviewing: state_entry:v1 is only allowed when no defer is possible"))
    t.is_true(has_error(errors, "implementing: state_entry:v1 is only allowed when no defer is possible"))
    t.is_true(has_error(errors, "thinking: state_entry:v1 is only allowed when no defer is possible"))
  end,

  test_actionable_epoch_contract_rejects_missing_or_unregistered_source = function()
    local rows = copy_rows(core.restart_transition_table())
    local row = rows_by_state(rows)["merge-ready"]
    row.actionable_epoch.source = nil
    local missing = core.liveness_contract_errors(rows)
    t.is_true(has_error(missing, "merge-ready: actionable_epoch.source is missing"))

    rows = copy_rows(core.restart_transition_table())
    row = rows_by_state(rows)["merge-ready"]
    row.actionable_epoch.source = "not-registered:v1"
    local unregistered = core.liveness_contract_errors(rows)
    t.is_true(has_error(unregistered, "merge-ready: actionable_epoch.source is not registered: not-registered:v1"))
  end,

  test_actionable_epoch_contract_rejects_live_defer_without_source = function()
    local rows = copy_rows(core.restart_transition_table())
    local row = rows_by_state(rows).ready
    row.actionable_epoch.source = nil
    local errors = core.liveness_contract_errors(rows)
    t.is_true(has_error(errors, "ready: actionable_epoch.source is missing"))
  end,

  test_actionable_epoch_contract_rejects_live_defer_clearable_marker_without_clear_fact = function()
    local rows = copy_rows(core.restart_transition_table())
    local row = rows_by_state(rows).ready
    row.actionable_epoch.source = "defer_clear_fact:v1"
    row.defer.clear_fact = nil
    local errors = core.liveness_contract_errors(rows)
    t.is_true(has_error(errors, "ready: live-defer row must declare durable defer.clear_fact"))
    t.is_true(has_error(errors, "ready: actionable_epoch.source requires durable defer.clear_fact"))
  end,

  test_watchdog_declaration_must_match_budget_and_liveness_mode = function()
    local rows = copy_rows(core.restart_transition_table())
    local row = rows_by_state(rows)["merge-ready"]
    row.watchdog.mode = "live-defer"
    row.watchdog.budget_ms = 1
    local errors = core.liveness_contract_errors(rows)
    t.is_true(has_error(errors, "merge-ready: watchdog.mode must match liveness_contract.mode"))
    t.is_true(has_error(errors, "merge-ready: watchdog.budget_ms must match budget.minutes"))
  end,

  test_ready_887_model_documents_state_entry_violation = function()
    local row = rows_by_state(core.restart_transition_table()).ready
    local state = {
      state = "ready",
      version = "consensus:github-devloop/issue/owner/repo/887/intake/1",
      proposal_id = "github-devloop/issue/owner/repo/887",
      marker_created_at = "2026-06-17T09:45:00Z",
    }
    local now_seconds = core.iso_timestamp_epoch_seconds("2026-06-17T10:33:02Z")
    local due, age = core.liveness_timeout_due_with_facts(row, state, {
      proposal_id = "github-devloop/issue/owner/repo/887",
      current = {
        comments = {
          {
            body = core.dependency_release_marker("github-devloop/issue/owner/repo/887", state.version),
            author_login = "fkst-test-bot",
            created_at = "2026-06-17T10:33:00Z",
          },
        },
      },
      now_seconds = now_seconds,
    }, now_seconds)
    t.eq(row.actionable_epoch.source, "state_entry:v1")
    t.eq(due, true)
    t.eq(age, 48)

    local strict_errors = state_errors(core.strict_liveness_contract_error_records(), "ready")
    t.is_true(has_error(strict_errors, "state_entry:v1 is only allowed when no defer is possible"))
  end,
}
