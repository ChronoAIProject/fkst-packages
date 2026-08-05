local core = require("core")
local default_intake = require("devloop.intake.default")
local wiring = require("core.devloop_wiring")
local t = fkst.test

return {
  test_default_intake_owns_policy_prompt = function()
    t.eq(type(default_intake.prompt), "table")
    t.eq(type(default_intake.prompt.template), "string")
    t.eq(wiring.prompts().prompts.intake, default_intake.prompt)
  end,
}
