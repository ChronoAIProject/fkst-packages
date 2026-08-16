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

local function execute(args, prepare_during_admission)
  local admission = nil
  local prepared = nil
  args.with_lock(args.transition_lock_key, function()
    admission = args.admit()
    if admission ~= nil and prepare_during_admission then
      prepared = args.prepare(admission)
    end
  end)
  if admission == nil then return end
  if not prepare_during_admission then
    prepared = args.prepare(admission)
  end
  if prepared == nil then return end

  local outcome = args.verify(prepared)
  if outcome == nil then return end

  args.with_lock(args.transition_lock_key, function()
    args.publish(outcome)
  end)
end

function M.run(args)
  args.with_lock(M.lock_key(args.proposal_id, args.implementation_version), function()
    execute(args, args.completed_result == nil)
  end)
end

return M
