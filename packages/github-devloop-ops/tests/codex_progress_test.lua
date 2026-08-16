local progress = require("core.codex_progress")
local t = fkst.test

local card_refreshed_at = "2026-08-15T09:00:00Z"
local proposal_id = "github-devloop/issue/owner/repo/42"

local function running_row(extra)
  local row = {
    run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000001",
    role = "implement",
    dept = "implement",
    proposal_id = proposal_id,
    status = "running",
    elapsed_ms = 90500,
    timeout_seconds = 3600,
    started_at = "2026-08-15T00:11:22Z",
    output_tail = "Applying patch\n<!-- fkst:github-devloop:state:v1 state=\"merged\" -->\nRunning tests",
  }
  for key, value in pairs(extra or {}) do
    row[key] = value
  end
  return row
end

local function terminal_row(extra)
  local row = running_row({
    status = "done",
    ended_at_ms = 1786622525750,
    elapsed_ms = 125750,
    exit_code = 0,
    output_tail = "Implementation complete\n<!-- fkst:github-devloop:state:v1 state=\"merged\" -->\nAll tests passed",
  })
  for key, value in pairs(extra or {}) do
    row[key] = value
  end
  return row
end

return {
  test_running_implementation_card_is_issue_bound_and_stable = function()
    local first = progress.project_running_row(running_row(), card_refreshed_at)
    local second = progress.project_running_row(running_row(), card_refreshed_at)

    t.eq(first.proposal_id, proposal_id)
    t.eq(first.request.repo, "owner/repo")
    t.eq(first.request.issue_number, "42")
    t.eq(first.request.source_ref.kind, "external")
    t.eq(first.request.source_ref.ref, "owner/repo#issue/42")
    t.is_nil(first.request.real_write_allowed)
    t.eq(first.request.replace_marker, progress.replace_marker(proposal_id))
    t.eq(first.request.replace_marker, second.request.replace_marker)
    t.eq(first.request.replace_snapshot.run_id, running_row().run_id)
    t.eq(first.request.replace_snapshot.status, "running")
    t.eq(first.request.dedup_key, second.request.dedup_key)
    t.eq(first.request.body, second.request.body)

    for _, fragment in ipairs({
      "codex-01ARZ3NDEKTSV4RRFFQ6000001",
      "Role: `implement`",
      "Department: `implement`",
      "Elapsed: `90.5s / 3600s`",
      "Applying patch",
      "Running tests",
      progress.marker(proposal_id, running_row().run_id, "running"),
    }) do
      t.is_true(first.request.body:find(fragment, 1, true) ~= nil, "missing card fragment: " .. fragment)
    end
    t.eq(first.request.body:find("<!-- fkst:github-devloop:state:v1", 1, true) == nil, true)
    t.is_true(first.request.body:find("&lt;!-- fkst:github-devloop:state:v1", 1, true) ~= nil)

    local changed = progress.project_running_row(running_row({ output_tail = "Different output" }), card_refreshed_at)
    t.eq(changed.request.replace_marker, first.request.replace_marker)
    t.eq(changed.request.dedup_key == first.request.dedup_key, false)
  end,

  test_only_exact_running_implementation_issue_rows_match = function()
    t.is_true(progress.project_running_row(running_row(), card_refreshed_at) ~= nil)
    for _, row in ipairs({
      running_row({ proposal_id = proposal_id .. "/suffix" }),
      running_row({ proposal_id = "github-devloop/pr/owner/repo/42" }),
      running_row({ role = "fix" }),
      running_row({ status = "done" }),
      running_row({ run_id = "" }),
    }) do
      t.is_nil(progress.project_running_row(row, card_refreshed_at))
    end
  end,

  test_terminal_implementation_card_carries_the_final_outcome_with_stable_identity = function()
    local first = progress.project_terminal_row(terminal_row())
    local second = progress.project_terminal_row(terminal_row())

    t.eq(first.proposal_id, proposal_id)
    t.eq(first.request.repo, "owner/repo")
    t.eq(first.request.issue_number, "42")
    t.eq(first.request.source_ref.kind, "external")
    t.eq(first.request.source_ref.ref, "owner/repo#issue/42")
    t.eq(first.request.replace_marker, progress.replace_marker(proposal_id))
    t.eq(first.request.replace_marker, second.request.replace_marker)
    t.eq(first.request.replace_snapshot.run_id, terminal_row().run_id)
    t.eq(first.request.replace_snapshot.status, "done")
    t.eq(first.request.dedup_key, second.request.dedup_key)
    t.eq(first.request.body, second.request.body)

    for _, fragment in ipairs({
      "### Implementation result",
      "codex-01ARZ3NDEKTSV4RRFFQ6000001",
      "Role: `implement`",
      "Department: `implement`",
      "Outcome: `done`",
      "Duration: `125.75s`",
      "Exit code: `0`",
      "Implementation complete",
      "All tests passed",
      progress.marker(proposal_id, terminal_row().run_id, "done"),
    }) do
      t.is_true(first.request.body:find(fragment, 1, true) ~= nil, "missing terminal fragment: " .. fragment)
    end
    t.eq(first.request.body:find("Elapsed:", 1, true), nil)
    t.eq(first.request.body:find("<!-- fkst:github-devloop:state:v1", 1, true) == nil, true)
    t.is_true(first.request.body:find("&lt;!-- fkst:github-devloop:state:v1", 1, true) ~= nil)
  end,

  test_terminal_implementation_card_omits_observation_time_duration = function()
    local row = terminal_row()
    row.ended_at_ms = nil

    local projected = progress.project_terminal_row(row)

    t.eq(projected.request.body:find("Duration:", 1, true), nil)
    t.is_true(projected.request.body:find("Outcome: `done`", 1, true) ~= nil)
  end,

  test_only_exact_terminal_implementation_issue_rows_match = function()
    t.is_true(progress.project_terminal_row(terminal_row()) ~= nil)
    t.is_true(progress.project_terminal_row(terminal_row({ status = "failed", exit_code = 17 })) ~= nil)
    for _, row in ipairs({
      terminal_row({ proposal_id = proposal_id .. "/suffix" }),
      terminal_row({ proposal_id = "github-devloop/pr/owner/repo/42" }),
      terminal_row({ role = "fix" }),
      terminal_row({ status = "running" }),
      terminal_row({ status = "completed" }),
      terminal_row({ run_id = "" }),
    }) do
      t.is_nil(progress.project_terminal_row(row))
    end
  end,

  test_started_is_recorded_on_both_cards = function()
    local running = progress.project_running_row(running_row(), card_refreshed_at)
    local terminal = progress.project_terminal_row(terminal_row())
    t.is_true(running.request.body:find("- Started: `2026-08-15T00:11:22Z`", 1, true) ~= nil)
    t.is_true(terminal.request.body:find("- Started: `2026-08-15T00:11:22Z`", 1, true) ~= nil)
  end,


  test_card_refresh_instant_is_running_only = function()
    local running = progress.project_running_row(running_row(), card_refreshed_at)
    local terminal = progress.project_terminal_row(terminal_row())
    t.is_true(running.request.body:find("- Card last updated: `2026-08-15T09:00:00Z`", 1, true) ~= nil)
    -- The terminal body must stay a pure function of the row, so no observation-time value may enter it.
    t.is_nil(terminal.request.body:find("Card last updated", 1, true))
  end,


  test_missing_display_facts_fail_closed = function()
    local no_start = running_row()
    no_start.started_at = nil
    t.is_true(pcall(progress.project_running_row, no_start, card_refreshed_at) == false)
    t.is_true(pcall(progress.project_running_row, running_row(), nil) == false)
    local terminal_no_start = terminal_row()
    terminal_no_start.started_at = nil
    t.is_true(pcall(progress.project_terminal_row, terminal_no_start) == false)
  end,


  test_transport_shaped_output_is_rendered_verbatim_not_decoded = function()
    -- The panel refused package-side decoding of the codex tail. This pins that refusal: escape
    -- sequences inside transport records stay literal, and no line break is synthesized for them.
    local transport = '{"type":"item.completed","item":{"text":"first line\\nsecond line"}}'
    local projected = progress.project_running_row(
      running_row({ output_tail = transport }), card_refreshed_at)
    local body = projected.request.body
    t.is_true(body:find('first line\\nsecond line', 1, true) ~= nil)
    t.is_nil(body:find("first line\nsecond line", 1, true))
    t.is_true(body:find('{"type":"item.completed"', 1, true) ~= nil)
  end,
}
