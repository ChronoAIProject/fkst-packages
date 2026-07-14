local report = require("report_logic")

return {
  type = "cron",
  interval = report.poll_interval(),
  produces = report.tick_queue(),
}
