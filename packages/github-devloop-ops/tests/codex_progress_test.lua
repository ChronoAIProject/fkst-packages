local progress = require("core.codex_progress")
local t = fkst.test

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
    output_tail = "Applying patch\n<!-- fkst:github-devloop:state:v1 state=\"merged\" -->\nRunning tests",
  }
  for key, value in pairs(extra or {}) do
    row[key] = value
  end
  return row
end

return {
  test_running_implementation_card_is_issue_bound_and_stable = function()
    local first = progress.project_running_row(running_row())
    local second = progress.project_running_row(running_row())

    t.eq(first.proposal_id, proposal_id)
    t.eq(first.request.repo, "owner/repo")
    t.eq(first.request.issue_number, "42")
    t.eq(first.request.source_ref.kind, "external")
    t.eq(first.request.source_ref.ref, "owner/repo#issue/42")
    t.eq(first.request.real_write_allowed, false)
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

    local changed = progress.project_running_row(running_row({ output_tail = "Different output" }))
    t.eq(changed.request.replace_marker, first.request.replace_marker)
    t.eq(changed.request.dedup_key == first.request.dedup_key, false)
  end,

  test_only_exact_running_implementation_issue_rows_match = function()
    t.is_true(progress.project_running_row(running_row()) ~= nil)
    for _, row in ipairs({
      running_row({ proposal_id = proposal_id .. "/suffix" }),
      running_row({ proposal_id = "github-devloop/pr/owner/repo/42" }),
      running_row({ role = "fix" }),
      running_row({ status = "done" }),
      running_row({ run_id = "" }),
    }) do
      t.is_nil(progress.project_running_row(row))
    end
  end,

  test_real_write_rollout_is_blocked_until_parent_lifecycle_lands = function()
    t.eq(progress.publication_enabled("dry-run"), true)
    t.eq(progress.publication_enabled("real"), false)
  end,
}
