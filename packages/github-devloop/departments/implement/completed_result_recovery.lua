local base_ids = require("devloop.base_ids")

local M = {}

function M.lock_key(proposal_id, implementation_version)
  if tostring(proposal_id or "") == "" or tostring(implementation_version or "") == "" then
    error("github-devloop: completed-result-recovery-identity-missing: proposal and version are required")
  end
  return base_ids.dedup_key({
    "github-devloop", "implement-recovery", proposal_id, implementation_version,
  })
end

function M.run(args)
  local recovery_lock_key = M.lock_key(args.proposal_id, args.implementation_version)
  args.with_lock(recovery_lock_key, function()
    local admission = nil
    args.with_lock(args.transition_lock_key, function()
      admission = args.admit()
    end)
    if admission == nil then return end

    local prepared = args.prepare(admission)
    if prepared == nil then return end
    local outcome = args.verify(prepared)
    if outcome == nil then return end

    args.with_lock(args.transition_lock_key, function()
      args.publish(outcome)
    end)
  end)
end

return M
