local devloop_base = require("devloop.base")
local config = require("devloop.config")
local strings = require("contract.strings")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local t = h.t

local BASE_SHA = string.rep("a", 40)
local HEAD_SHA = "def456"
local CANDIDATE_SHA = string.rep("c", 40)
local CANDIDATE_RUN_ID = "101"
local BASE_RUN_ID = "202"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function materialize_manifest(runtime_root, run_id, body)
  local directory = runtime_root
    .. "/ci-failure-manifests/"
    .. strings.runtime_safe_segment("owner/repo")
    .. "/run-"
    .. tostring(run_id)
  local ok = os.execute("mkdir -p " .. shell_quote(directory))
  if ok ~= true and ok ~= 0 then
    error("failure-manifest fixture directory setup failed")
  end
  file.write(directory .. "/failure-manifest.json", body)
end

local function at_cap_event()
  local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
  for n = 1, config.max_fix_rounds() do
    version = version .. "/fix/" .. tostring(n)
  end
  local review_proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, version, HEAD_SHA)
  return h.merge_ready({
    version = version,
    reviewed_head_sha = HEAD_SHA,
    review_proposal_id = review_proposal_id,
    review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
  })
end

local function failure_manifest(event_name, tested_commit, base_commit, head_commit)
  local fields = {
    '{"schema":"fkst.test.failure-manifest.v1"',
    ',"event_name":"' .. event_name .. '"',
    ',"tested_commit":"' .. tested_commit .. '"',
  }
  if base_commit ~= nil then table.insert(fields, ',"base_commit":"' .. base_commit .. '"') end
  if head_commit ~= nil then table.insert(fields, ',"head_commit":"' .. head_commit .. '"') end
  table.insert(fields, ',"complete":true,"report_count":1,"failures":[')
  table.insert(fields, '{"owner_namespace":"github-devloop","file":"tests/regression_test.lua","name":"test_k"}')
  table.insert(fields, "]}")
  return table.concat(fields)
end

local function mock_check_runs(commit, run_id, conclusion)
  t.mock_command("gh api 'repos/owner/repo/commits/" .. commit .. "/check-runs'", {
    stdout = '{"total_count":1,"check_runs":[{"id":' .. run_id
      .. ',"name":"test","status":"completed","conclusion":"' .. conclusion
      .. '","head_sha":"' .. commit
      .. '","details_url":"https://github.com/owner/repo/actions/runs/' .. run_id .. '/job/1"}]}',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_red_ci_with_no_new_failing_identity_neither_merges_nor_enters_fixing = function()
    local event = at_cap_event()
    local origin_marker = m_builders.pr_origin_marker(
      event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"
    )
    local rollup = '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:04:04Z",'
      .. '"conclusion":"FAILURE","detailsUrl":"https://github.com/owner/repo/actions/runs/'
      .. CANDIDATE_RUN_ID .. '/job/1","name":"test","startedAt":"2026-06-03T02:03:04Z",'
      .. '"status":"COMPLETED","workflowName":"ci","headSha":"' .. HEAD_SHA .. '"}]'

    h.mock_bot_env()
    h.mock_write_env("1")
    h.mock_write_env("1")
    h.mock_issue_merge({ "fkst-dev:merge-ready" }, h.merge_comments(event))
    h.mock_pr_merge_rollup({ origin_marker }, rollup, nil, nil, nil, nil, nil, nil, nil, nil, nil, BASE_SHA)
    h.mock_pr_merge_rollup({ origin_marker }, rollup, nil, nil, nil, nil, nil, nil, nil, nil, nil, BASE_SHA)
    mock_check_runs(HEAD_SHA, CANDIDATE_RUN_ID, "failure")
    mock_check_runs(BASE_SHA, BASE_RUN_ID, "failure")
    local candidate_manifest = failure_manifest("pull_request", CANDIDATE_SHA, BASE_SHA, HEAD_SHA)
    local base_manifest = failure_manifest("push", BASE_SHA, nil, nil)
    local run_opts = h.opts("no-new-ci-failure-hold", { FKST_GITHUB_WRITE = "1" })
    local runtime_root = run_opts.env.FKST_RUNTIME_ROOT
    materialize_manifest(runtime_root, CANDIDATE_RUN_ID, candidate_manifest)
    materialize_manifest(runtime_root, BASE_RUN_ID, base_manifest)
    for _ = 1, 2 do
      t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
        stdout = runtime_root,
        stderr = "",
        exit_code = 0,
      })
    end

    local result = h.run_merge(event, run_opts)

    t.eq(result.exit_code, 0, tostring(result.error))
    t.eq(h.count_calls("gh pr merge"), 0)
    t.eq(h.find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(h.find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(h.find_raise(result.raises, "devloop_fix_reconcile"), nil)
    t.eq(h.find_raise(result.raises, "github-devloop-decompose.devloop_decompose"), nil)
  end,
}
