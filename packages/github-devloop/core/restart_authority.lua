-- This grant-disabled shadow slice proves CAS-admission-composition parity only.
-- The loop department's thinking-to-blocked probe is an admission sentinel; the
-- real blocked transition belongs to reconcile, so this does not prove effect parity.
--
-- cas_outcome parity is COMPLETE for this edge: admission status and reason_code
-- (two independent reachability implementations) plus the full cas_outcome including
-- the loop stale VERSION-BRANCH. Production loop emits "skip-stale(incoming version <
-- current marker version)" when the driving event's dedup_key is ordered-older
-- (devloop_state.cas_outcome passes dedup_key as incoming_version) and
-- "skip-advanced-or-diverged" otherwise; this shadow now threads that dedup_key as
-- intent.incoming_version, the catalog's plain base_result passes it to status_result
-- (cas.legacy_loop_plain_v1 resolves via resolve_profile, so the version-branch fires
-- while the abstract cas.base_plain_legacy_v1 stays versionless via resolve_base), and
-- the parity harness exercises the ordered-older stale case bidirectionally against the
-- real loop department. The earlier version-branch gap is closed.

local core = require("core")
local owner = core.restart_package_name
local rows = core.restart_transition_table()
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local projection = owner_pending_projection.derive(owner, rows, inventories)
local catalog = require("devloop.restart_cas_catalog")
local restart_effect_entitlements = require("devloop.restart_effect_entitlements")
local restart_source_admission = require("devloop.restart_source_admission")

local function timeout_effect_edges()
  local projected = owner_pending_projection.edges(owner, rows, inventories)
  local representative = nil
  for _, edge in ipairs(projected) do
    if edge.kind == "timeout"
      and edge.cas_policy_id == "cas.legacy_timeout_reconcile_v1"
      and edge.target == "blocked"
      and edge.transition_effect_entitlements ~= nil then
      if representative ~= nil then
        error("github-devloop: timeout-effect-edge-ambiguous: multiple timeout effect representatives")
      end
      representative = edge
    end
  end
  if representative == nil then
    error("github-devloop: timeout-effect-edge-missing: missing timeout effect representative")
  end

  local by_source = {}
  for _, edge in ipairs(projected) do
    if edge.kind == "timeout" and edge.semantic_variant == representative.semantic_variant then
      by_source[edge.source.state] = true
    end
  end
  for _, row in ipairs(rows) do
    local escalation = row.on_timeout and row.on_timeout.on_escalate
    local source_state = row.from_state
    if row.terminal == false
      and type(escalation) == "table"
      and source_state ~= escalation.terminal_state
      and escalation.action == "force-terminate"
      and escalation.terminal_state == representative.target
      and by_source[source_state] ~= true then
      local edge_id = table.concat({ owner, source_state, "timeout", representative.semantic_variant }, "/")
      table.insert(projected, {
        id = edge_id,
        owner = owner,
        row_id = source_state,
        kind = representative.kind,
        source = { state = source_state, boundary = representative.source.boundary },
        target = representative.target,
        semantic_variant = representative.semantic_variant,
        cas_policy_id = representative.cas_policy_id,
        cas_variant = source_state:gsub("%-", "_") .. "_to_blocked",
        pending_order = { participates = false },
        transition_effect_entitlements = {
          apply = {
            id = edge_id .. "/apply",
            effect_ids = { "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" },
          },
          idempotent = {
            id = edge_id .. "/idempotent",
            effect_ids = {},
          },
        },
        provenance = {
          owner = owner,
          row = source_state,
          field = "on_timeout.on_escalate",
        },
      })
    end
  end
  return projected
end

local edges = timeout_effect_edges()

local M = {}
local issued = setmetatable({}, { __mode = "k" })
local intent_fields = {
  semantic_variant = true,
  source_boundary = true,
  target = true,
  evidence_refs = true,
  incoming_version = true,
  target_version = true,
  overlay_version = true,
  phase = true,
  retry = true,
  handoff = true,
  accepted_handoff = true,
}

local function illegal(reason_code, outcome_reason)
  return {
    status = "illegal",
    reason_code = reason_code,
    cas_outcome = "illegal(" .. tostring(outcome_reason or reason_code) .. ")",
    grant = nil,
  }
end

local function normalize_intent(intent)
  if type(intent) ~= "table" then
    return nil
  end
  for field in pairs(intent) do
    if intent_fields[field] ~= true then
      return nil
    end
  end
  if type(intent.semantic_variant) ~= "string" or intent.semantic_variant == "" then
    return nil
  end
  if intent.incoming_version ~= nil
    and (type(intent.incoming_version) ~= "string" or intent.incoming_version == "") then
    return nil
  end
  if intent.target_version ~= nil
    and (type(intent.target_version) ~= "string" or intent.target_version == "") then
    return nil
  end
  if intent.overlay_version ~= nil
    and (type(intent.overlay_version) ~= "string" or intent.overlay_version == "") then
    return nil
  end
  if intent.phase ~= nil and intent.phase ~= "initial" and intent.phase ~= "recheck" then
    return nil
  end
  if intent.retry ~= nil and type(intent.retry) ~= "boolean" then
    return nil
  end
  if intent.accepted_handoff ~= nil and type(intent.accepted_handoff) ~= "boolean" then
    return nil
  end
  if intent.handoff ~= nil
    and (type(intent.handoff) ~= "table"
      or (intent.handoff.status ~= "valid" and intent.handoff.status ~= "invalid")) then
    return nil
  end
  return {
    semantic_variant = intent.semantic_variant,
    source_boundary = intent.source_boundary,
    target = intent.target,
    evidence_refs = intent.evidence_refs,
    incoming_version = intent.incoming_version,
    target_version = intent.target_version,
    overlay_version = intent.overlay_version,
    phase = intent.phase,
    retry = intent.retry,
    handoff = intent.handoff and { status = intent.handoff.status } or nil,
    accepted_handoff = intent.accepted_handoff,
  }
end

local function same_transition_shape(left, right)
  return left.kind == right.kind
    and left.source.boundary == right.source.boundary
    and left.target == right.target
    and left.cas_policy_id == right.cas_policy_id
    and left.cas_variant == right.cas_variant
end

local function select_edge(semantic_variant, current_state)
  local candidates = {}
  for _, candidate in ipairs(edges) do
    if candidate.semantic_variant == semantic_variant then
      table.insert(candidates, candidate)
    end
  end
  if #candidates <= 1 then
    return candidates[1], #candidates
  end
  local exact = nil
  local exact_matches = 0
  for _, candidate in ipairs(candidates) do
    if candidate.source.state == current_state then
      exact = candidate
      exact_matches = exact_matches + 1
    end
  end
  if exact_matches == 1 then
    return exact, 1
  end
  if exact_matches > 1 then
    return nil, #candidates
  end
  local representative = candidates[1]
  for index = 2, #candidates do
    local candidate = candidates[index]
    if not same_transition_shape(candidate, representative) then
      return representative, #candidates
    end
  end
  return representative, 1
end

function M.edges()
  return edges
end

function M.seal_snapshot(fields)
  if type(fields) ~= "table" or fields.owner ~= owner then
    error("restart-authority: snapshot-owner-mismatch: owner must be " .. tostring(owner))
  end
  local current = type(fields.current) == "table" and fields.current or {}
  local sealed = {
    owner = fields.owner,
    proposal_id = fields.proposal_id,
    current = {
      state = current.state,
      version = current.version,
    },
  }
  issued[sealed] = true
  return sealed
end

function M.decide_transition(sealed_snapshot, intent)
  if issued[sealed_snapshot] ~= true or sealed_snapshot.owner ~= owner then
    return illegal("unsealed-or-foreign-snapshot", "unsealed")
  end

  local normalized = normalize_intent(intent)
  if normalized == nil then
    return illegal("malformed-intent")
  end

  local current = type(sealed_snapshot.current) == "table" and sealed_snapshot.current or {}
  local edge, matches = select_edge(normalized.semantic_variant, current.state)
  if matches == 0 then
    return illegal("unknown-variant")
  end
  if edge.cas_policy_id ~= "cas.legacy_loop_plain_v1"
    and not (edge.cas_policy_id == "cas.legacy_consensus_result_v1"
      and (edge.cas_variant == "thinking_to_ready"
        or edge.cas_variant == "thinking_to_dependency_wait"))
    and not (edge.cas_policy_id == "cas.legacy_awaiting_pr_v1"
      and (edge.cas_variant == "implementing_to_awaiting_pr"
        or edge.cas_variant == "awaiting_pr_to_ready"
        or edge.cas_variant == "awaiting_pr_to_merged"
        or edge.cas_variant == "awaiting_pr_to_blocked"))
    and not (edge.cas_policy_id == "cas.legacy_issue_reconcile_v1"
      and edge.cas_variant == "thinking_to_blocked")
    and not (edge.cas_policy_id == "cas.legacy_observe_issue_entry_v1"
      and edge.cas_variant == "unmanaged_to_thinking")
    and not (edge.cas_policy_id == "cas.legacy_timeout_reconcile_v1"
      and edge.kind == "timeout"
      and edge.target == "blocked")
    and not (edge.cas_policy_id == "cas.legacy_implement_activation_handoff_v1"
      and (edge.cas_variant == "ready_to_implementing"
        or edge.cas_variant == "impl_failed_to_implementing"
        or edge.cas_variant == "blocked_to_implementing")) then
    return illegal("unsupported-shadow-edge")
  end
  local concrete_source_mode = edge.source.state ~= nil
  local ingress_mode = edge.kind == "entry" and edge.source.state == nil
  if not concrete_source_mode and not ingress_mode then
    return illegal("policy-variant-shape-mismatch")
  end
  if ingress_mode then
    if type(edge.source.boundary) ~= "string" or edge.source.boundary == ""
      or normalized.source_boundary ~= edge.source.boundary then
      return illegal("source-boundary-mismatch")
    end
    if normalized.target ~= edge.target then
      return illegal("target-mismatch")
    end
  else
    if normalized.source_boundary ~= nil and normalized.source_boundary ~= edge.source.boundary then
      return illegal("source-boundary-mismatch")
    end
    if normalized.target ~= nil and normalized.target ~= edge.target then
      return illegal("target-mismatch")
    end
  end

  local definition = catalog.definition(edge.cas_policy_id)
  local variant = definition
    and type(definition.variants) == "table"
    and definition.variants[edge.cas_variant]
    or nil
  if variant == nil or variant.target_state ~= edge.target then
    return illegal("policy-variant-shape-mismatch")
  end
  if concrete_source_mode
    and not restart_source_admission.exact_source_state(variant.source_states, edge.source.state) then
    return illegal("policy-variant-shape-mismatch")
  end
  local admitted_sources = nil
  local current_state = nil
  if ingress_mode then
    admitted_sources = restart_source_admission.dense_unique_state_set(variant.source_states)
    if admitted_sources == nil then
      return illegal("policy-variant-shape-mismatch")
    end
    current_state = current.state == nil and "unmanaged" or current.state
  end
  local cas_base = variant.base or definition.base
  if edge.cas_policy_id == "cas.legacy_implement_activation_handoff_v1" and cas_base == nil then
    cas_base = "versioned"
  end
  if (cas_base == "versioned" or cas_base == "cyclic")
    and normalized.incoming_version == nil then
    return illegal("incoming-version-required")
  end

  local evidence = {
    current = {
      state = current.state,
      version = current.version,
    },
    variant = edge.cas_variant,
    incoming_version = normalized.incoming_version,
    target_version = normalized.target_version,
    overlay_version = normalized.overlay_version,
  }
  if edge.cas_policy_id == "cas.legacy_implement_activation_handoff_v1" then
    evidence.phase = normalized.phase
    evidence.retry = normalized.retry
    evidence.handoff = normalized.handoff
    evidence.accepted_handoff = normalized.accepted_handoff
  end
  local resolved = catalog.resolve(edge.cas_policy_id, evidence, projection)
  if ingress_mode and resolved.status == "apply" and admitted_sources[current_state] ~= true then
    return illegal("source-state-not-admitted")
  end
  if matches > 1 and resolved.status ~= "pending" then
    return illegal("ambiguous-variant")
  end
  local disposition = ({
    apply = "apply",
    idempotent = "idempotent",
  })[resolved.status]
  local effect_entitlement_id = nil
  local granted_effect_ids = nil
  if disposition ~= nil and edge.transition_effect_entitlements ~= nil then
    local entitlement = restart_effect_entitlements.resolve(edge, disposition)
    effect_entitlement_id = entitlement.id
    granted_effect_ids = entitlement.effect_ids
  end
  return {
    status = resolved.status,
    reason_code = resolved.reason_code,
    cas_outcome = resolved.cas_outcome,
    edge_id = edge.id,
    cas_policy_id = edge.cas_policy_id,
    effect_entitlement_id = effect_entitlement_id,
    granted_effect_ids = granted_effect_ids,
    evidence = {
      status = "complete",
      refs = normalized.evidence_refs or {},
      facts = {
        source = ingress_mode and current.state or edge.source.state,
        target = edge.target,
      },
    },
    grant = nil,
  }
end

return M
