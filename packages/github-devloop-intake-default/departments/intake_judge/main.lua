local default_intake = require("devloop.intake.default")
local intake_class = require("core.intake_class")
local intake_service_class = require("core.intake_service_class")
local devloop_logging = require("devloop.logging")
local saga = require("workflow.saga")
local prompts = default_intake.prompt_surface()

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

local function act_intake_judge(event)
  return default_intake.act(intake_class, intake_service_class, event, {
    dept = "intake_judge",
    prompts = prompts,
  })
end

return saga.department(spec, {
  done = intake_judge_done,
  act = act_intake_judge,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "intake_judge",
})
