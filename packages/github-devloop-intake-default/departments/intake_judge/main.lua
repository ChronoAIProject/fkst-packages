local core = require("core")
local saga = require("workflow.saga")
local default_intake = require("devloop.intake.default_intake")

local spec = {
  consumes = { "github-devloop-intake.devloop_intake_candidate" },
  produces = {
    "github-devloop.devloop_execute_request",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_create_request",
    "github-proxy.github_issue_label_request",
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "2m",
}

local function intake_judge_done(_event)
  return false
end

return saga.department(spec, {
  done = intake_judge_done,
  act = function(event)
    return default_intake.act(core, event, { dept = "intake_judge" })
  end,
  wrap = core.wrap_pipeline_failure,
  name = "intake_judge",
})
