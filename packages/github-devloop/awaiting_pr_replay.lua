local core = require("core")
local replayer = assert(rawget(core, "replayer"))

return require("core.awaiting_pr_replayer").install(core, replayer.replay_log_decline)
