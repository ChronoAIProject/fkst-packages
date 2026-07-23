local temporal = require("devloop.restart_temporal_obligations")
local owner_index = require("core.restart.temporal_obligations.index")
local h = require("tests.devloop_core_helpers")

local core = h.core
local t = h.t

local expected_keys = {
  ["github-devloop-pr/blocked/response-with-deadline"] = true,
  ["github-devloop-pr/fixing/response-with-deadline"] = true,
  ["github-devloop-pr/merge-ready/response-with-deadline"] = true,
  ["github-devloop-pr/merging/response-with-deadline"] = true,
  ["github-devloop-pr/pr-open/response-with-deadline"] = true,
  ["github-devloop-pr/review-meta/response-with-deadline"] = true,
  ["github-devloop-pr/reviewing/response-with-deadline"] = true,
}

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy_value(item)
  end
  return out
end

local function contains(value, needle)
  return tostring(value or ""):find(needle, 1, true) ~= nil
end

local function assert_fails(fn, needle)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(contains(err, needle), tostring(err))
end

local function assert_error_list_contains(errors, needle)
  for _, err in ipairs(errors or {}) do
    if contains(err, needle) then
      return
    end
  end
  error("missing temporal conformance error containing: " .. needle)
end

local function row_by_state(rows, state)
  for _, row in ipairs(rows) do
    if row.from_state == state then
      return row
    end
  end
  error("missing restart row: " .. state)
end

local function synthetic_row(kind, extra)
  local obligation = {
    obligation_id = "github-devloop-pr/synthetic/" .. kind,
    kind = kind,
    body = {},
  }
  for key, value in pairs(extra or {}) do
    obligation[key] = value
  end
  return {
    from_state = "synthetic",
    terminal = false,
    actionable_epoch = { source = "state_entry:v1" },
    budget = { minutes = 5 },
    liveness_contract = { mode = "row-budget-bounds-receiver" },
    temporal_obligations = { obligation },
  }
end

return {
  test_pr_temporal_index_has_exact_row_authored_key_set = function()
    local rows = core.restart_transition_table()
    local index = owner_index.derive(rows)
    local count = 0
    for key, entry in pairs(index) do
      count = count + 1
      t.eq(expected_keys[key], true)
      t.eq(entry.obligation_id, key)
      t.eq(entry.owner, "github-devloop-pr")
      t.eq(entry.kind, "response-with-deadline")
      t.eq(entry.verification.provider_kind, "r8-liveness-watchdog")
      t.eq(entry.verification.status, "monitored")
    end
    t.eq(count, 7)

    for _, row in ipairs(rows) do
      t.eq(type(row.temporal_obligations), "table")
      if row.terminal then
        t.eq(#row.temporal_obligations, 0)
      end
    end
  end,

  test_duplicate_row_authored_id_fails_closed = function()
    local rows = copy_value(core.restart_transition_table())
    local blocked = row_by_state(rows, "blocked")
    local fixing = row_by_state(rows, "fixing")
    fixing.temporal_obligations[1].obligation_id = blocked.temporal_obligations[1].obligation_id
    assert_fails(function()
      temporal.derive_temporal_index("github-devloop-pr", rows, temporal.provider_capability_matrix())
    end, "duplicate obligation_id")
  end,

  test_orphan_and_drifting_index_entries_fail_conformance = function()
    local rows = core.restart_transition_table()
    local index = owner_index.derive(rows)

    local orphaned = copy_value(index)
    orphaned["github-devloop-pr/orphan/response-with-deadline"] = copy_value(index[next(index)])
    assert_error_list_contains(
      temporal.index_errors("github-devloop-pr", rows, orphaned, temporal.provider_capability_matrix()),
      "orphan index entry"
    )

    local drifted = copy_value(index)
    local key = next(drifted)
    drifted[key].body.budget_minutes = drifted[key].body.budget_minutes + 1
    assert_error_list_contains(
      temporal.index_errors("github-devloop-pr", rows, drifted, temporal.provider_capability_matrix()),
      "drifting index entry"
    )
  end,

  test_separately_authored_provider_binding_is_rejected = function()
    local row = synthetic_row("response-with-deadline", {
      body = {
        actionable_epoch_source = "state_entry:v1",
        resolver = "row-budget-bounds-receiver",
        budget_minutes = 5,
      },
      provider_binding = "r8-liveness-watchdog",
    })
    assert_fails(function()
      temporal.derive_temporal_index("github-devloop-pr", { row }, temporal.provider_capability_matrix())
    end, "separately-authored provider binding")
  end,

  test_provider_capability_matrix_rejects_runtime_extension = function()
    local matrix = temporal.provider_capability_matrix()
    matrix.absence = { status = "monitored", provider_kind = "invented-absence-provider" }
    assert_fails(function()
      temporal.derive_temporal_index("github-devloop-pr", core.restart_transition_table(), matrix)
    end, "not the closed canonical matrix")
  end,

  test_absence_without_capable_provider_fails_closed = function()
    assert_fails(function()
      temporal.derive_temporal_index(
        "github-devloop-pr",
        { synthetic_row("absence") },
        temporal.provider_capability_matrix()
      )
    end, "unmonitored/indeterminate")
  end,
}
