local ci_wait = require("core.merge_ci_wait")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")

local t = h.t

local function capture_hold(kind, reason, merge_pass)
  local raised = {}
  local logged = {}
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
    table.insert(logged, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end

  local merge_ready = h.merge_ready()
  merge_ready._merge_pass = merge_pass
  local ok, result = pcall(ci_wait.hold, h.core, merge_ready, "owner/repo", {
    head_sha = merge_ready.reviewed_head_sha,
  }, {
    kind = kind,
    reason = reason,
  })

  devloop_logging.log_raise = original_log_raise
  devloop_logging.log_line = original_log_line
  if not ok then error(result, 0) end
  return merge_ready, result, raised, logged
end

return {
  test_mergeability_wait_requires_the_current_pr_to_produce_the_reason = function()
    for _, case in ipairs({
      { pr = nil, reason = "missing-pr" },
      { pr = {}, reason = "missing-mergeability" },
      { pr = { mergeable = "UNKNOWN" }, reason = "mergeable-unknown" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "BEHIND" }, reason = "merge-state-behind" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "BLOCKED" }, reason = "merge-state-blocked" },
      { pr = { mergeable = "MERGEABLE", merge_state_status = "UNSTABLE" }, reason = "merge-state-unstable" },
    }) do
      t.is_true(ci_wait.is_mergeability_wait(case.pr, case.reason), case.reason)
    end

    for _, case in ipairs({
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
    local merge_ready, result, raised, logged = capture_hold("CI_WAIT", "checks-pending")

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
    t.eq(#logged, 1)
    t.eq(logged[1].level, "info")
    t.eq(logged[1].tag, "GATE")
    t.eq(logged[1].fields[3], "outcome=hold")
    t.eq(logged[1].fields[4], "reason=checks-pending")
    t.eq(logged[1].fields[5], "ci_class=CI_WAIT")
    t.eq(logged[1].fields[6], "head_sha=" .. merge_ready.reviewed_head_sha)
  end,

  test_mergeability_hold_uses_the_same_clean_wait_contract = function()
    local _, result, raised, logged = capture_hold("MERGEABILITY_WAIT", "mergeable-unknown")

    t.eq(result.status, "hold")
    t.eq(result.reason, "mergeable-unknown")
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('kind="MERGEABILITY_WAIT"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason="mergeable-unknown"', 1, true) ~= nil)
    t.eq(#logged, 1)
    t.eq(logged[1].level, "info")
    t.eq(logged[1].fields[3], "outcome=hold")
    t.eq(logged[1].fields[5], "ci_class=MERGEABILITY_WAIT")
  end,

  test_repeated_ci_hold_reuses_the_same_outbound_identity = function()
    local _, _, first = capture_hold("CI_WAIT", "checks-pending")
    local _, _, second = capture_hold("CI_WAIT", "checks-pending")

    t.is_true(tostring(first[1].payload.dedup_key or "") ~= "")
    t.eq(first[1].payload.dedup_key, second[1].payload.dedup_key)
    t.eq(first[1].payload.body, second[1].payload.body)
  end,

  test_poll_hold_keeps_queue_pass_context = function()
    local _, result, _, logged = capture_hold("CI_WAIT", "checks-pending", "poll")

    t.eq(result.status, "hold")
    t.eq(#logged, 1)
    t.eq(logged[1].fields[7], "pass=poll")
  end,
}
