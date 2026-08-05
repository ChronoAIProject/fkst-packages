local M = {}

local function minted(caps, snapshot, decision, effect_id, context)
  if decision.status ~= "apply" and decision.status ~= "idempotent" then
    error(context .. ": decision rejected: " .. tostring(decision.reason_code))
  end
  local grant = caps.restart_effects.mint_grant(snapshot, decision, effect_id)
  if grant == nil then error(context .. ": grant was not minted") end
  return { snapshot = snapshot, decision = decision, grant = grant }
end

function M.consume(caps, authorization, effect_id, context)
  local accepted = type(authorization) == "table" and caps.restart_effects.verify_grant(
    authorization.grant, effect_id, authorization.snapshot
  )
  if not accepted then error(context .. ": exact grant was rejected") end
end

function M.implement_receiver(caps, args)
  local state = args.receiver_state
  local snapshot = caps.restart_effects.seal_snapshot({
    owner = caps.restart_package_name,
    entity = { kind = "issue", repo = args.repo, number = args.issue_number },
    proposal_id = args.ready.proposal_id,
    current = state,
    snapshot_fingerprint = table.concat({ "implement-receiver", args.ready.proposal_id,
      state.state or "missing", state.version or "missing" }, "|"),
    lock_epoch = args.lock_key .. "@" .. tostring(state.version or "missing"),
    generation = args.ready.dedup_key,
  })
  local decision = caps.restart_effects.decide_receiver_dispatch(snapshot,
    { receiver_state = "implementing", accepted_handoff = state.state ~= "implementing" })
  return minted(caps, snapshot, decision, "codex.dispatch:implement",
    "github-devloop: implement receiver dispatch grant")
end

function M.implementation_publish(caps, args)
  local snapshot = caps.restart_effects.seal_snapshot({
    owner = caps.restart_package_name,
    entity = { kind = "issue", repo = args.repo, number = args.issue_number },
    proposal_id = args.ready.proposal_id,
    current = args.publish_state,
    snapshot_fingerprint = table.concat({ "implementation-publish",
      args.ready.proposal_id, args.publish_state.version, args.outcome_kind }, "|"),
    lock_epoch = args.lock_key .. "@" .. tostring(args.publish_state.version),
    generation = args.ready.dedup_key,
  })
  local decision = caps.restart_effects.decide_transition(snapshot,
    { semantic_variant = "revision_published", target = "awaiting-pr",
      incoming_version = args.ready.dedup_key })
  return minted(caps, snapshot, decision, "git.push:implementation-branch",
    "github-devloop: implementation publish grant")
end

return M
