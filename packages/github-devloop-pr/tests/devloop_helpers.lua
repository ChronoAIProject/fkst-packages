local helpers = require("testkit_internal.devloop_helpers_fixtures").new({
  entity_lib = require("devloop.entity"),
  base = require("tests.devloop_base_helpers"),
  pr = require("tests.devloop_pr_helpers"),
  worktree = require("tests.devloop_worktree_helpers"),
  entity_read_mocks = require("tests.entity_read_mock_helpers"),
  payloads_predicates = require("devloop.payloads.predicates"),
  mock_review_result_pr_name_only = true,
  hydrate_handoff_state_comment = true,
  include_ready_causal_raise = false,
})

function helpers.mock_required_check_runs_for(head_sha, conclusion, repo, run_id)
  local sha = tostring(head_sha or "def456")
  local selected_repo = tostring(repo or "owner/repo")
  local selected_run_id = tostring(run_id or "9002")
  helpers.t.mock_command("gh api 'repos/" .. selected_repo .. "/commits/" .. sha .. "/check-runs'", {
    stdout = '{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"'
      .. tostring(conclusion or "failure")
      .. '","head_sha":"' .. sha
      .. '","details_url":"https://github.com/' .. selected_repo .. "/actions/runs/" .. selected_run_id
      .. '"}]}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function failure_manifest(fields)
  local association = ""
  if fields.base_commit ~= nil then
    association = ',"base_commit":"' .. fields.base_commit
      .. '","head_commit":"' .. fields.head_commit .. '"'
  end
  local failures = fields.new_failure
    and '[{"owner_namespace":"github-devloop-pr","file":"tests/example_test.lua","name":"test_new"}]'
    or "[]"
  return '{"schema":"fkst.test.failure-set.v1","repository":"' .. fields.repo
    .. '","workflow_run_id":"' .. fields.run_id .. '","workflow_run_attempt":1'
    .. ',"event_name":"' .. fields.event_name .. '","tested_commit":"' .. fields.tested_commit
    .. '","complete":true,"report_count":1,"failures":' .. failures .. association .. "}"
end

function helpers.with_new_failure_set_evidence(fields, fn)
  local repo = tostring(fields.repo or "owner/repo")
  local pr_number = tostring(fields.pr_number or "7")
  local base_commit = tostring(fields.base_commit or "")
  local head_commit = tostring(fields.head_commit or "")
  local base_run_id = tostring(fields.base_run_id or "9001")
  local head_run_id = tostring(fields.head_run_id or "9002")
  helpers.t.mock_command("gh api 'repos/" .. repo .. "/commits/" .. base_commit .. "/check-runs'", {
    stdout = '{"total_count":1,"check_runs":[{"name":"test","status":"completed"'
      .. ',"conclusion":"failure","head_sha":"' .. base_commit
      .. '","details_url":"https://github.com/' .. repo .. "/actions/runs/" .. base_run_id
      .. '"}]}\n',
    stderr = "",
    exit_code = 0,
  })
  local download_ok = { stdout = "", stderr = "", exit_code = 0 }
  helpers.t.mock_command("gh run download '" .. base_run_id .. "'", download_ok)
  helpers.t.mock_command("gh run download '" .. head_run_id .. "'", download_ok)

  local base_manifest = failure_manifest({
    repo = repo,
    run_id = base_run_id,
    event_name = "push",
    tested_commit = base_commit,
  })
  local head_manifest = failure_manifest({
    repo = repo,
    run_id = head_run_id,
    event_name = "pull_request",
    tested_commit = string.rep("c", 40),
    base_commit = base_commit,
    head_commit = head_commit,
    new_failure = true,
  })
  local clock = now()
  for offset = -2, 2 do
    local root = "/tmp/fkst-ci-failure-set-" .. pr_number .. "-" .. base_run_id .. "-"
      .. head_run_id .. "-" .. tostring(clock + offset)
    local command = "mkdir -p " .. require("devloop.base")._shell_single_quote(root .. "/base")
      .. " " .. require("devloop.base")._shell_single_quote(root .. "/head")
    local made = os.execute(command)
    if made ~= true and made ~= 0 then
      error("github-devloop-pr test fixture could not create failure-set artifact directories")
    end
    file.write(root .. "/base/failure-set.json", base_manifest)
    file.write(root .. "/head/failure-set.json", head_manifest)
  end
  local results = table.pack(pcall(fn))
  if not results[1] then
    error(results[2])
  end
  return table.unpack(results, 2, results.n)
end

return helpers
