local scan = require("scan_logic")

return {
  type = "cron",
  interval = scan.poll_interval(),
  produces = scan.tick_queue(),
}
