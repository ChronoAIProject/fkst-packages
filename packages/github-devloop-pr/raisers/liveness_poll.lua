local timing_policy = require("core.timing_policy")

return {
  type = "cron",
  interval = timing_policy.liveness_poll_interval(),
  produces = "devloop_liveness_tick",
}
