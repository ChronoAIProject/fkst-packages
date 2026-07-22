local context_bundle = require("devloop.context_bundle")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local m_claims = require("devloop.claims")
local observe_issue_caps = require("observe_issue_department_caps")
local payloads_builders = require("devloop.payloads.builders")
local v_validate_proposal = require("devloop.validators.validate_proposal")

local M = {}

function M.process(args)
  local owner_core = args.core
  local current = args.current
  local event = args.event
  local issue = args.issue
  local lock_key = args.lock_key
  local proposal_id = args.proposal_id
  local state = args.state
  local grant_version = state.version or issue.dedup_key
  local snapshot = observe_issue_caps.restart_effects.seal_snapshot({
    owner = observe_issue_caps.restart_package_name,
    entity = { kind = "issue", repo = issue.repo, number = issue.number },
    proposal_id = proposal_id,
    current = { state = state.state, version = grant_version },
    snapshot_fingerprint = table.concat({
      "observe-issue-entry", proposal_id, state.state or "unmanaged", grant_version,
    }, "|"),
    lock_epoch = lock_key .. "@" .. grant_version,
    generation = grant_version,
  })
  local decision = observe_issue_caps.restart_effects.decide_transition(snapshot, {
    semantic_variant = "unmanaged_issue",
    source_boundary = "github-proxy.github_entity_changed",
    target = "thinking",
    incoming_version = issue.dedup_key,
  })
  if decision.status == "stale" then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state,
      "unmanaged", "thinking", decision.cas_outcome,
      "current marker is not an unmanaged start")
    return
  end
  if decision.status == "pending" then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state,
      "unmanaged", "thinking", decision.cas_outcome,
      "unmanaged state marker pending for observe")
    error("github-devloop: state-marker-pending: unmanaged state marker pending for observe; retrying")
  end
  if decision.status ~= "apply" and decision.status ~= "idempotent" then
    error("github-devloop: restart-effect-decision-illegal: observe issue entry decision rejected: "
      .. tostring(decision.reason_code))
  end
  if not m_claims.claim_issue_for_management(owner_core, "observe_issue", issue.repo,
    issue.number, current, proposal_id) then
    return
  end
  devloop_logging.log_cas_decision("observe_issue", proposal_id, state,
    "unmanaged", "thinking", decision.cas_outcome,
    "starting consensus for opted-in issue")

  issue.content_fetch = context_bundle.context_fetch_ref_from_bundle(owner_core, {
    dept = "observe_issue",
    repo = issue.repo,
    issue_number = issue.number,
    proposal_id = proposal_id,
    version = issue.dedup_key,
    tick = event.ts,
  })
  local proposal = payloads_builders.build_board_proposal(owner_core, issue, event.ts)
  if not v_validate_proposal.validate_proposal(proposal) then
    log.warn("github-devloop dept=observe_issue proposal_id=" .. tostring(proposal_id)
      .. " tag=SKIP reason=cannot-build-valid-proposal")
    return
  end
  local grant = observe_issue_caps.restart_effects.mint_grant(
    snapshot, decision, "comment:issue:thinking-state")
  if grant == nil then
    error("github-devloop: restart-effect-grant-mint-failed: observe issue entry grant was not minted")
  end
  local facade = observe_issue_caps.restart_effect_facade.make({
    family = "observe-issue-entry",
    verify_grant = observe_issue_caps.restart_effects.verify_grant,
    sink_inventory = observe_issue_caps.sink_inventory,
  })
  if type(facade.emit) ~= "function" then
    error("github-devloop: restart-effect-facade-invalid: observe issue entry facade emit is unavailable")
  end

  local effects = {}
  local serializer_args = { core = owner_core, issue = issue, proposal = proposal }
  for _, effect_id in ipairs(decision.granted_effect_ids) do
    local payload, rejection = facade.emit(grant, effect_id, snapshot, serializer_args)
    if payload == nil then
      error("github-devloop: restart-effect-facade-rejected: observe issue entry effect "
        .. tostring(effect_id) .. " rejected: " .. tostring(rejection))
    end
    table.insert(effects, { queue = effect_id, payload = payload })
  end
  local add_labels, remove_labels = devloop_state.state_label_changes("thinking")
  devloop_logging.log_apply("observe_issue", proposal_id, "thinking", proposal.dedup_key, {
    add = add_labels,
    remove = remove_labels,
  }, decision.granted_effect_ids)
  for _, effect in ipairs(effects) do
    devloop_logging.log_raise("observe_issue", proposal_id, effect.queue, effect.payload)
  end
end

return M
