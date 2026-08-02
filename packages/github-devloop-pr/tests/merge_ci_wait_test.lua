local ci_wait = require("core.merge_ci_wait")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")

local t = h.t

return {
  test_hold_emits_one_wait_fact_and_returns_cleanly = function()
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
    local ok, result = pcall(ci_wait.hold, h.core, merge_ready, "owner/repo", {
      head_sha = merge_ready.reviewed_head_sha,
    }, {
      kind = "CI_WAIT",
      reason = "checks-pending",
    })

    devloop_logging.log_raise = original_log_raise
    devloop_logging.log_line = original_log_line
    if not ok then error(result, 0) end

    t.eq(result, nil)
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_pr_comment_request")
    t.is_true(raised[1].payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason="checks-pending"', 1, true) ~= nil)
    t.eq(#logged, 1)
    t.eq(logged[1].level, "info")
    t.eq(logged[1].tag, "GATE")
  end,
}
