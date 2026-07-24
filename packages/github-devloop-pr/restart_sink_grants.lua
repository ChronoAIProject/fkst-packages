local M = {}

local function finish(caps, snapshot, decision, effect_id, context)
  if decision.status ~= "apply" and decision.status ~= "idempotent" then
    error(context .. ": decision rejected: " .. tostring(decision.reason_code))
  end
  local grant = caps.restart_effects.mint_grant(snapshot, decision, effect_id)
  if grant == nil then error(context .. ": grant was not minted") end
  return { snapshot = snapshot, decision = decision, grant = grant }
end

function M.receiver(caps, fields, intent, effect_id, context)
  local snapshot = caps.restart_effects.seal_snapshot(fields)
  local decision = caps.restart_effects.decide_receiver_dispatch(snapshot, intent)
  return finish(caps, snapshot, decision, effect_id, context)
end

function M.transition(caps, fields, intent, effect_id, context)
  local snapshot = caps.restart_effects.seal_snapshot(fields)
  local decision = caps.restart_effects.decide_transition(snapshot, intent)
  return finish(caps, snapshot, decision, effect_id, context)
end

function M.consume(caps, authorization, effect_id, context)
  if type(authorization) ~= "table"
    or not caps.restart_effects.verify_grant(
      authorization.grant, effect_id, authorization.snapshot
    ) then
    error(context .. ": exact grant was rejected")
  end
end

function M.verified_merge(caps, args)
  local state = args.state
  return M.transition(caps, {
    owner = caps.restart_package_name,
    entity = { kind = "pr", repo = args.repo, number = args.merge_ready.pr_number },
    proposal_id = args.merge_ready.proposal_id,
    current = state,
    snapshot_fingerprint = table.concat({ "verified-merge", args.merge_ready.proposal_id,
      state.state or "missing", state.version or "missing",
      args.rechecked_pr.head_sha or "missing" }, "|"),
    lock_epoch = args.lock_key .. "@" .. tostring(state.version or "missing"),
    generation = args.merge_ready.version,
    head = { sha = args.rechecked_pr.head_sha },
  }, { semantic_variant = "eligible_now", target = "merging",
    incoming_version = args.merge_ready.version, overlay_version = args.merge_ready.version },
    "github.merge:verified-pr", "github-devloop: verified merge grant")
end

return M
