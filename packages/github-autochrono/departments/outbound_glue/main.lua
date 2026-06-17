local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "autochrono.reply" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "30s",
}

local function act(event)
  raise("github-proxy.github_issue_comment_request", core.reply_to_comment_request(event.payload or {}))
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = function(_event)
    return false
  end,
  act = act,
  name = "outbound_glue",
}
