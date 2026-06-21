local S = {}

function S.install(M, caller_require)
  local shared = require("std.devloop_liveness.shared").install(M, caller_require)
  require("std.devloop_liveness.contract").install(M, shared)
  require("std.devloop_liveness.signal").install(M, shared)
  require("std.devloop_liveness.timeout").install(M, shared)
end

return S
