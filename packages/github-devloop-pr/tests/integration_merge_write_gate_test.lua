local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local opts = h.opts

local function origin_marker(event, branch)
  return m_builders.pr_origin_marker(
    event.proposal_id,
    "42",
    branch or "devloop-owner-repo-42-01HY",
    event.version,
    "dev"
  )
end

local function prepare_write_time_recheck(event, write_time_comments, mergeable, merge_state)
  h.mock_bot_env()
  h.mock_write_env("1")
  h.mock_write_env("1")
  h.mock_issue_merge({ "fkst-dev:merge-ready" }, h.merge_comments(event))
  h.mock_pr_merge({ origin_marker(event) })
  h.mock_issue_merge({ "fkst-dev:merge-ready" }, h.merge_comments(event))
  h.mock_pr_merge({ origin_marker(event) })
  h.mock_pr_merge(
    write_time_comments or { origin_marker(event) },
    "devloop-owner-repo-42-01HY",
    event.reviewed_head_sha,
    "OPEN",
    "owner/repo",
    false,
    mergeable or "MERGEABLE",
    merge_state or "CLEAN"
  )
end

local function run_write_time_recheck(event, name, extra_env)
  local env = {
    FKST_GITHUB_WRITE = "1",
  }
  for key, value in pairs(extra_env or {}) do
    env[key] = value
  end
  return h.run_merge(event, opts(name, env))
end

local function failure_text(result)
  return tostring(result and (result.error or result.stderr) or "")
end

local function mock_current_base_not_contained()
  t.mock_command("git fetch origin dev", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/dev^{commit}'", {
    stdout = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git merge-base --is-ancestor aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa def456", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
end

return {
  test_write_time_conflicting_mergeability_moves_back_to_fixing = function()
    local event = h.merge_ready()
    mock_current_base_not_contained()
    prepare_write_time_recheck(event, nil, "CONFLICTING", "CLEAN")

    local result = run_write_time_recheck(event, "merge-write-time-conflicting")

    t.eq(result.exit_code, 0, failure_text(result))
    t.eq(#result.raises, 2)
    t.eq(h.count_calls("gh pr merge"), 0)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:fixing")
    t.eq(h.find_causal_raise(result, "devloop_fixing").payload.gate_failure_excerpt, "mergeable-conflicting")
  end,

  test_write_time_unknown_mergeability_retries_without_fixing = function()
    local event = h.merge_ready()
    prepare_write_time_recheck(event, nil, "UNKNOWN", "CLEAN")

    local result = run_write_time_recheck(event, "merge-write-time-unknown")

    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr merge"), 0)
    t.is_true(
      failure_text(result):find("write-time-merge-wait", 1, true) ~= nil,
      failure_text(result)
    )
  end,

  test_write_time_missing_high_risk_evidence_retries = function()
    local event = h.merge_ready()
    h.mock_pr_normal_risk_diff_name_only()
    h.mock_pr_high_risk_diff_name_only()
    prepare_write_time_recheck(event)

    local result = run_write_time_recheck(event, "merge-write-time-high-risk", {
      FKST_TEST_SKIP_DEFAULT_RISK_MOCK = "1",
    })

    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr merge"), 0)
    t.is_true(
      failure_text(result):find("high-risk-review-evidence-missing", 1, true) ~= nil,
      failure_text(result)
    )
  end,

  test_write_time_changed_origin_fails_closed = function()
    local event = h.merge_ready()
    prepare_write_time_recheck(event, { origin_marker(event, "changed-branch") })

    local result = run_write_time_recheck(event, "merge-write-time-origin-changed")

    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr merge"), 0)
    t.is_true(
      failure_text(result):find("write-time-pr-fact-changed", 1, true) ~= nil,
      failure_text(result)
    )
  end,
}
