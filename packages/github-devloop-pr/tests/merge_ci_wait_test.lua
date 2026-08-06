local ci_wait = require("core.merge_ci_wait")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")

local t = fkst.test
local BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local HEAD_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

local function field_value(fields, key)
  local prefix = key .. "="
  for _, field in ipairs(fields or {}) do
    if tostring(field):sub(1, #prefix) == prefix then
      return tostring(field):sub(#prefix + 1)
    end
  end
  return nil
end

local function run_probe(ancestor_exit_code, merge_tree_result)
  local calls = {}
  local logs = {}
  local core = {
    git = {
      fetch_branch = function(remote, branch, timeout)
        table.insert(calls, { op = "fetch_branch", remote = remote, branch = branch, timeout = timeout })
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
      remote_branch_head = function(remote, branch, timeout)
        table.insert(calls, { op = "remote_branch_head", remote = remote, branch = branch, timeout = timeout })
        return { stdout = BASE_SHA .. "\n", stderr = "", exit_code = 0 }
      end,
      is_ancestor = function(base_sha, head_sha, timeout)
        table.insert(calls, { op = "is_ancestor", base_sha = base_sha, head_sha = head_sha, timeout = timeout })
        return { stdout = "", stderr = "", exit_code = ancestor_exit_code }
      end,
      merge_tree = function(base_sha, head_sha, timeout)
        table.insert(calls, { op = "merge_tree", base_sha = base_sha, head_sha = head_sha, timeout = timeout })
        return merge_tree_result
      end,
    },
  }
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
    table.insert(logs, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end
  local result = {
    pcall(ci_wait.should_wait_for_stale_mergeability, core, {
      number = 7,
      head_sha = HEAD_SHA,
    }, {
      integration = "dev",
    }, "mergeable-conflicting", "github-devloop/issue/owner/repo/42"),
  }
  devloop_logging.log_line = original_log_line
  return result, calls, logs
end

local function capture_hold(kind, reason)
  local raised = {}
  local logs = {}
  local original_log_raise = devloop_logging.log_raise
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_raise = function(dept, proposal_id, queue, payload)
    table.insert(raised, {
      dept = dept,
      proposal_id = proposal_id,
      queue = queue,
      payload = payload,
    })
  end
  devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
    table.insert(logs, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end

  local merge_ready = h.merge_ready()
  local ok, result = pcall(ci_wait.hold, h.core, merge_ready, "owner/repo", {
    head_sha = merge_ready.reviewed_head_sha,
  }, {
    kind = kind,
    reason = reason,
  })

  devloop_logging.log_raise = original_log_raise
  devloop_logging.log_line = original_log_line
  if not ok then error(result, 0) end
  return merge_ready, result, raised, logs
end

return {
  test_non_ancestor_clean_merge_rescues_stale_verdict_with_structured_fact = function()
    local result, calls, logs = run_probe(1, {
      stdout = "cccccccccccccccccccccccccccccccccccccccc\n",
      stderr = "",
      exit_code = 0,
    })

    t.eq(result[1], true)
    t.eq(result[2], true)
    t.eq(result[3], "stale-mergeability-local-merge-clean")
    t.eq(calls[#calls].op, "merge_tree")
    t.eq(calls[#calls].base_sha, BASE_SHA)
    t.eq(calls[#calls].head_sha, HEAD_SHA)
    t.eq(calls[#calls].timeout, 30)
    t.eq(logs[#logs].tag, "MERGEABILITY_PROBE")
    t.eq(field_value(logs[#logs].fields, "outcome"), "stale-verdict-rescued")
    t.eq(field_value(logs[#logs].fields, "probe"), "merge-tree-write-tree")
  end,

  test_non_ancestor_merge_conflict_remains_authoritative = function()
    local result, calls, logs = run_probe(1, {
      stdout = "",
      stderr = "CONFLICT (content): merge conflict",
      exit_code = 1,
    })

    t.eq(result[1], true)
    t.eq(result[2], false)
    t.eq(result[3], "genuine-merge-conflict")
    t.eq(calls[#calls].op, "merge_tree")
    t.eq(field_value(logs[#logs].fields, "outcome"), "genuine-conflict-confirmed")
  end,

  test_merge_probe_error_fails_closed_without_conflict_classification = function()
    local result, _, logs = run_probe(1, {
      stdout = "",
      stderr = "fatal: bad object",
      exit_code = 128,
    })

    t.eq(result[1], false)
    t.is_true(tostring(result[2]):find("mergeability-probe-failed", 1, true) ~= nil)
    t.eq(field_value(logs[#logs].fields, "outcome"), "probe-failed")
    t.eq(field_value(logs[#logs].fields, "exit_code"), "128")
  end,

  test_mergeability_wait_requires_the_current_pr_to_produce_the_reason = function()
    for _, case in ipairs({
      { pr = { mergeable = "UNKNOWN" }, reason = "mergeable-unknown" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "BEHIND" }, reason = "merge-state-behind" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "BLOCKED" }, reason = "merge-state-blocked" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "UNSTABLE" }, reason = "merge-state-unstable" },
    }) do
      t.is_true(ci_wait.is_mergeability_wait(case.pr, case.reason), case.reason)
    end

    for _, case in ipairs({
      { pr = nil, reason = "missing-pr" },
      { pr = {}, reason = "missing-mergeability" },
      { pr = { mergeable = "CONFLICTING" }, reason = "mergeable-conflicting" },
      { pr = { mergeable = "FALSE" }, reason = "mergeable-false" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "CONFLICTING" }, reason = "merge-state-conflicting" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "DIRTY" }, reason = "merge-state-dirty" },
      { pr = { mergeable = "UNKNOWN" }, reason = "merge-state-blocked" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "BLOCKED" }, reason = "write-time-pr-fact-changed" },
    }) do
      t.eq(ci_wait.is_mergeability_wait(case.pr, case.reason), false, case.reason)
    end
  end,

  test_ci_hold_emits_one_wait_fact_and_returns_cleanly = function()
    local merge_ready, result, raised, logs = capture_hold("CI_WAIT", "checks-pending")

    t.eq(result.status, "hold")
    t.eq(result.reason, "checks-pending")
    t.eq(#raised, 1)
    t.eq(raised[1].proposal_id, merge_ready.proposal_id)
    t.eq(raised[1].queue, "github-proxy.github_pr_comment_request")
    t.eq(raised[1].payload.pr_number, merge_ready.pr_number)
    t.eq(raised[1].payload.source_ref.kind, "external")
    t.eq(raised[1].payload.source_ref.ref, "owner/repo#pr/" .. tostring(merge_ready.pr_number))
    t.is_true(raised[1].payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('kind="CI_WAIT"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason="checks-pending"', 1, true) ~= nil)
    t.eq(#logs, 1)
    t.eq(logs[1].level, "info")
    t.eq(logs[1].tag, "GATE")
    t.eq(field_value(logs[1].fields, "outcome"), "hold")
    t.eq(field_value(logs[1].fields, "reason"), "checks-pending")
    t.eq(field_value(logs[1].fields, "ci_class"), "CI_WAIT")
    t.eq(field_value(logs[1].fields, "head_sha"), merge_ready.reviewed_head_sha)
  end,

  test_mergeability_hold_uses_the_same_clean_wait_contract = function()
    local _, result, raised, logs = capture_hold("MERGEABILITY_WAIT", "mergeable-unknown")

    t.eq(result.status, "hold")
    t.eq(result.reason, "mergeable-unknown")
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('kind="MERGEABILITY_WAIT"', 1, true) ~= nil)
    t.eq(field_value(logs[1].fields, "outcome"), "hold")
    t.eq(field_value(logs[1].fields, "ci_class"), "MERGEABILITY_WAIT")
  end,
}
