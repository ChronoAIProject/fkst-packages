local S = {}

function S.install(M, resolved)
  local shared = require("workflow.liveness.shared").install(M, resolved)
  require("workflow.liveness.contract").install(M, shared, {
    pr_recovery = {
      allowed = {
        not_mergeable = {
          to_state = "fixing",
          queue = "devloop_fixing",
        },
      },
    },
  })
  require("devloop.liveness.signal").install(M, shared)
  require("devloop.liveness.timeout").install(M, shared)
end

return S
