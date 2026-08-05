local core = require("core")
local default_intake = require("devloop.intake.default")
local t = fkst.test

return {
  test_workflow_uses_default_intake_policy_prompt = function()
    t.eq(core.default_intake, default_intake)
    t.eq(type(default_intake.prompt), "table")
    t.eq(type(default_intake.prompt.template), "string")
  end,
}
