local progress = require("core.codex_progress")
local progress_identity = require("devloop.codex_progress_identity")
local t = fkst.test

local card_refreshed_at = "2026-08-15T09:00:00Z"
local proposal_id = "github-devloop/issue/owner/repo/42"
local pr_proposal_id = "github-devloop/pr/owner/repo/7"
local review_proposal_id = "github-devloop/pr-review/owner/repo/7/review-v1/abcdef1"
local review_cohort_id = string.rep("a", 64)
local retry_cohort_id = string.rep("b", 64)

local function progress_label(cohort_id)
  return progress_identity.label(pr_proposal_id, cohort_id)
end

local function snapshot_id(cohort_id)
  return progress_identity.parse_label(progress_label(cohort_id)).snapshot_id
end

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

local function pr_running_row(extra)
  local row = running_row({
    run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000011",
    role = "consensus",
    dept = "review_result",
    proposal_id = review_proposal_id,
    label = progress_label(review_cohort_id),
    dedup_key = "convergence:consensus:review-v1:teleology",
    output_tail = "Reviewing pull request",
    started_at_ms = 1786622400000,
    timeout_seconds = 3600,
    started_at = "2026-08-15T00:00:00Z",
  })
  for key, value in pairs(extra or {}) do
    row[key] = value
  end
  return row
end

local function pr_terminal_row(extra)
  local row = pr_running_row({
    status = "done",
    ended_at_ms = 1786622525750,
    elapsed_ms = 125750,
    exit_code = 0,
    output_tail = "Review seat complete",
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

  test_fix_run_projects_to_the_canonical_pull_request_target = function()
    local cards = progress.project_pr_cards({ pr_running_row({
      role = "fix",
      dept = "fix",
      proposal_id = proposal_id,
      dedup_key = "fix-work-unit-v1",
      output_tail = "Repairing own CI",
    }) }, {}, card_refreshed_at)

    t.eq(#cards, 1)
    local card = cards[1]
    t.eq(card.queue, "github-proxy.github_pr_comment_request")
    t.eq(card.proposal_id, pr_proposal_id)
    t.eq(card.request.repo, "owner/repo")
    t.eq(card.request.pr_number, 7)
    t.is_nil(card.request.issue_number)
    t.eq(card.request.source_ref.kind, "external")
    t.eq(card.request.source_ref.ref, "owner/repo#pr/7")
    t.eq(card.request.replace_marker, progress.replace_marker(pr_proposal_id))
    t.eq(card.request.replace_snapshot.status, "running")
    t.is_true(card.request.body:find("Role: `fix`", 1, true) ~= nil)
    t.is_true(card.request.body:find("Repairing own CI", 1, true) ~= nil)
  end,

  test_concurrent_review_seats_share_one_aggregate_pull_request_card = function()
    local rows = {}
    for index, lane in ipairs({ "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" }) do
      table.insert(rows, pr_running_row({
        run_id = "codex-01ARZ3NDEKTSV4RRFFQ600001" .. tostring(index),
        dedup_key = "convergence:consensus:review-v1:" .. lane,
        output_tail = lane .. " reviewing",
        started_at_ms = 1786622400000 + index,
      }))
    end

    local cards = progress.project_pr_cards(rows, {}, card_refreshed_at)

    t.eq(#cards, 1)
    local card = cards[1]
    t.eq(card.request.replace_snapshot.run_id, snapshot_id(review_cohort_id))
    t.eq(card.request.replace_snapshot.status, "running")
    t.is_true(card.request.body:find("- Runs: `5`", 1, true) ~= nil)
    for _, lane in ipairs({ "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" }) do
      t.is_true(card.request.body:find(lane .. " reviewing", 1, true) ~= nil,
        "missing aggregate review lane: " .. lane)
    end
  end,

  test_partial_review_completion_remains_one_running_aggregate = function()
    local running = {
      pr_running_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000011", output_tail = "teleology running" }),
      pr_running_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000012", output_tail = "parsimony running" }),
    }
    local recent = {
      pr_terminal_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000013", output_tail = "fidelity done" }),
      pr_terminal_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000014", output_tail = "natural ownership done" }),
      pr_terminal_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000015", output_tail = "containment done" }),
    }

    local cards = progress.project_pr_cards(running, recent, card_refreshed_at)

    t.eq(#cards, 1)
    t.eq(cards[1].request.replace_snapshot.run_id, snapshot_id(review_cohort_id))
    t.eq(cards[1].request.replace_snapshot.status, "running")
    t.is_true(cards[1].request.body:find("- Runs: `5`", 1, true) ~= nil)
    t.is_true(cards[1].request.body:find("fidelity done", 1, true) ~= nil)
  end,

  test_terminal_review_cohort_is_stable_and_absorbs_its_running_snapshot = function()
    local recent = {
      pr_terminal_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000011", output_tail = "teleology done" }),
      pr_terminal_row({ run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000012", output_tail = "parsimony done" }),
      pr_terminal_row({
        run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000013",
        status = "failed",
        exit_code = 17,
        output_tail = "fidelity failed",
      }),
    }

    local first = progress.project_pr_cards({}, recent, card_refreshed_at)[1]
    local second = progress.project_pr_cards({}, recent, "2026-08-15T10:00:00Z")[1]

    t.eq(first.request.replace_snapshot.run_id, snapshot_id(review_cohort_id))
    t.eq(first.request.replace_snapshot.status, "failed")
    t.eq(first.request.body, second.request.body)
    t.eq(first.request.dedup_key, second.request.dedup_key)
    t.is_nil(first.request.body:find("Card last updated", 1, true))
    t.is_true(first.request.body:find("Outcome: `failed`", 1, true) ~= nil)
    t.is_true(first.request.body:find(progress.marker(
      pr_proposal_id, first.request.replace_snapshot.run_id, "failed"), 1, true) ~= nil)
  end,

  test_failed_review_attempt_is_replaced_by_running_retry_then_success = function()
    local failed = pr_terminal_row({
      run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000021",
      label = progress_label(review_cohort_id),
      status = "failed",
      exit_code = 17,
      output_tail = "first attempt failed",
      started_at_ms = 1786622400000,
      ended_at_ms = 1786622525750,
    })
    local running_retry = pr_running_row({
      run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000022",
      label = progress_label(retry_cohort_id),
      output_tail = "retry running",
      started_at_ms = 1786622600000,
    })

    local failed_card = progress.project_pr_cards({}, { failed }, card_refreshed_at)[1]
    local running_card = progress.project_pr_cards(
      { running_retry }, { failed }, card_refreshed_at)[1]

    t.eq(failed_card.request.replace_snapshot.status, "failed")
    t.eq(running_card.request.replace_snapshot.status, "running")
    t.eq(running_card.request.replace_snapshot.run_id == failed_card.request.replace_snapshot.run_id, false)
    t.is_true(running_card.request.body:find("retry running", 1, true) ~= nil)
    t.is_nil(running_card.request.body:find("first attempt failed", 1, true))
    t.is_true(running_card.request.body:find("- Runs: `1`", 1, true) ~= nil)

    local successful_retry = pr_terminal_row({
      run_id = running_retry.run_id,
      label = running_retry.label,
      output_tail = "retry succeeded",
      started_at_ms = running_retry.started_at_ms,
      ended_at_ms = 1786622725750,
    })
    local success_card = progress.project_pr_cards(
      {}, { failed, successful_retry }, card_refreshed_at)[1]

    t.eq(success_card.request.replace_snapshot.run_id, running_card.request.replace_snapshot.run_id)
    t.eq(success_card.request.replace_snapshot.status, "done")
    t.is_true(success_card.request.body:find("retry succeeded", 1, true) ~= nil)
    t.is_nil(success_card.request.body:find("first attempt failed", 1, true))
  end,

  test_pull_request_projection_requires_an_explicit_canonical_target_label = function()
    local missing_label = pr_running_row()
    missing_label.label = nil
    local invalid = {
      missing_label,
      pr_running_row({ label = pr_proposal_id .. "/suffix" }),
      pr_running_row({ label = pr_proposal_id }),
      pr_running_row({ label = proposal_id }),
      pr_running_row({ role = "implement" }),
      pr_running_row({ role = "release-notes" }),
    }

    t.eq(#progress.project_pr_cards(invalid, {}, card_refreshed_at), 0)
  end,
}
