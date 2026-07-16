-- dev_select: the label-scoped dev intake seat. On the dev_intake_tick cron tick it
-- discovers OPEN fkst-dev issues and produces the EXISTING candidate seam
-- github-devloop-intake.devloop_intake_candidate that github-devloop-workflow's
-- workflow_select consumes -- reusing the shared claim + candidate builder VERBATIM. The
-- spec lives here; the handlers (and every core read + gh egress) come from bindings.
local saga = require("workflow.saga")
local bindings = require("bindings")

local spec = {
  consumes = { "dev_intake_tick" },
  produces = {
    "github-devloop-intake.devloop_intake_candidate",
  },
  stall_window = "2m",
}

return saga.department(spec, bindings.dev_select_handlers())
