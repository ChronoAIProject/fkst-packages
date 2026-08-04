local branch_tick = require("branch_tick")

return {
  type = "cron",
  interval = branch_tick.poll_interval,
  produces = branch_tick.source_queue,
}
