local base_ids = require("devloop.base_ids")
local requests_labels = require("devloop.requests.labels")
local parsers_misc = require("devloop.parsers.misc")
local payloads_predicates = require("devloop.payloads.predicates")
local restart_metadata = require("devloop.restart_metadata")
local S = {}
local C = {}
restart_metadata.export_into(C)
local devloop_base = require("devloop.base")
local transition_version = require("contract.transition_version")
local m_builders = require("devloop.markers.builders")
local issue_observation_facts = require("devloop.restart.issue_observation_facts")
local markers_shared = require("devloop.markers.shared")

local function marker_attrs(marker)
  local attrs = {}
  for key, value in tostring(marker or ""):gmatch('([%w._-]+)="([^"]*)"') do
    attrs[key] = value
  end
  return attrs
end

local function render_state_marker(proposal_id, state, version, effects)
  if not C.is_state(state) then
    error("github-devloop: state-invalid: invalid state")
  end
  local effects_field = ""
  if effects ~= nil and tostring(effects) ~= "" then
    effects_field = ' effects="' .. tostring(effects):gsub('"', "'") .. '"'
  end
  return '<!-- fkst:github-devloop:state:v1 proposal="' .. tostring(proposal_id)
    .. '" state="' .. tostring(state)
    .. '" version="' .. tostring(version)
    .. '" stage_rank="' .. tostring(C.stage_rank(state))
    .. '" marker_order_key="' .. C.marker_order_key(version, state)
    .. '"'
    .. effects_field
    .. ' -->'
end

local function marker_stage_rank(marker, state)
  local explicit_rank = tonumber(marker:match('stage_rank="(%d+)"'))
  return explicit_rank or C.stage_rank(state)
end

local function state_marker_fact(marker, comment)
  local attrs = marker_attrs(marker)
  local marker_proposal = attrs.proposal
  local marker_state = attrs.state
  local marker_version = attrs.version
  if marker_proposal == nil or not C.is_state(marker_state) then
    return nil
  end
  return {
    proposal_id = marker_proposal,
    state = marker_state,
    version = marker_version,
    stage_rank = marker_stage_rank(marker, marker_state),
    marker_created_at = parsers_misc._comment_created_at(comment),
  }
end

local function versions_equivalent(left, right)
  if left == nil or right == nil then
    return left == right
  end
  if tostring(left) == tostring(right) then
    return true
  end
  return transition_version.safe_version_segment(left) == transition_version.safe_version_segment(right)
end

local function compare_state_marker(a, b)
  if a == nil then
    return true
  end
  local version_order = C._compare_transition_versions(b.version, a.version)
  if version_order ~= 0 then
    return version_order > 0
  end
  local a_stage_rank = tonumber(a.stage_rank) or C.stage_rank(a.state)
  local b_stage_rank = tonumber(b.stage_rank) or C.stage_rank(b.state)
  if a_stage_rank ~= b_stage_rank then
    return b_stage_rank > a_stage_rank
  end
  local a_key = C.marker_order_key(a.version, a.stage_rank)
  local b_key = C.marker_order_key(b.version, b.stage_rank)
  return b_key > a_key
end

local function lineage_matches(version, opts)
  local options = opts or {}
  if options.lineage_base == nil then
    return true
  end
  local actual = transition_version.strip_suffixes(version)
  local expected = transition_version.strip_suffixes(options.lineage_base)
  return versions_equivalent(actual, expected)
end

function C.comment_bodies(comments)
  local bodies = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(bodies, parsers_misc._comment_body(comment))
  end
  return bodies
end

local function derive_current_marker(comments, proposal_id, trust_set, include_author)
  if type(comments) ~= "table" then
    return nil
  end

  local current = nil
  local marker_pattern = markers_shared.STATE_MARKER_PATTERN
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments, trust_set)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = state_marker_fact(marker, comment)
      if candidate ~= nil and candidate.proposal_id == proposal_id then
        candidate = {
          state = candidate.state,
          version = candidate.version,
          stage_rank = candidate.stage_rank,
          marker_created_at = candidate.marker_created_at,
        }
        if include_author then
          candidate.author_login = parsers_misc.canonical_login(parsers_misc._comment_author_login(comment))
        end
        if compare_state_marker(current, candidate) then
          current = candidate
        end
      end
    end
  end
  return current or {
    state = nil,
    version = nil,
    stage_rank = 0,
  }
end

function C.current_state(comments, proposal_id)
  return derive_current_marker(comments, proposal_id)
end

function C.current_state_fact(comments, proposal_id, trust_set)
  return derive_current_marker(comments, proposal_id, trust_set, true)
end

function C.route_current(comments, proposal_id, routes)
  if type(routes) ~= "table" then
    error("github-devloop: current-state-routes-invalid: invalid current state routes")
  end
  local current = derive_current_marker(comments, proposal_id) or {}
  return {
    route = routes[current.state],
    version = current.version,
    marker_created_at = current.marker_created_at,
  }
end

function C.current_issue_observation_is_terminal(comments, proposal_id)
  local current = derive_current_marker(comments, proposal_id)
  local row = current and issue_observation_facts.transition_row(current.state) or nil
  return row ~= nil and row.terminal == true
end

function C.is_current_state(comments, proposal_id, state, version)
  local current = derive_current_marker(comments, proposal_id)
  return current.state == state and current.version == version
end

local function current_marker_state(comments, proposal_id)
  local current = derive_current_marker(comments, proposal_id)
  if current == nil or current.state == nil then
    return nil
  end
  return current
end

local function has_any_state_label(labels)
  for _, label in ipairs(labels or {}) do
    if C.is_state_label(label) then
      return true
    end
  end
  return false
end

function C.has_active_issue_state(labels, comments, proposal_id)
  local current = current_marker_state(comments, proposal_id)
  if current ~= nil then
    return tostring(current.state or "") ~= "blocked"
  end
  return devloop_base.is_opted_in(labels) or has_any_state_label(labels)
end

function C.reached(comments, proposal_id, milestone, opts)
  if type(comments) ~= "table" then
    return false
  end
  local options = opts or {}
  if not C.is_state(milestone) then
    error("github-devloop: milestone-invalid: invalid milestone")
  end
  local domain = options.domain or options.milestone_domain
  restart_metadata._validate_milestone_domain(domain, milestone)

  local marker_pattern = markers_shared.STATE_MARKER_PATTERN
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = state_marker_fact(marker, comment)
      if candidate ~= nil
        and candidate.proposal_id == proposal_id
        and restart_metadata._domain_allows_state(domain, candidate.state)
        and lineage_matches(candidate.version, options)
        and C.is_at_or_after(candidate, milestone, options) then
        return true
      end
    end
  end
  return false
end

function C.has_state_marker(comments, proposal_id, state, version)
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = markers_shared.STATE_MARKER_PATTERN
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = state_marker_fact(marker, comment)
      if candidate ~= nil
        and candidate.proposal_id == proposal_id
        and candidate.state == state
        and candidate.version == version then
        return true
      end
    end
  end
  return false
end

local function state_marker_comment_id(comments, proposal_id, state, version, effects)
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = markers_shared.STATE_MARKER_PATTERN
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = state_marker_fact(marker, comment)
      local attrs = marker_attrs(marker)
      if candidate ~= nil
        and candidate.proposal_id == proposal_id
        and candidate.state == state
        and candidate.version == version
        and tostring(attrs.effects or "") == tostring(effects or "")
        and payloads_predicates.is_safe_comment_id(comment.id) then
        return tostring(comment.id)
      end
    end
  end
  return nil
end

function C.ready_hand_off_comment_id(comments, proposal_id, marker_version)
  return state_marker_comment_id(
    comments,
    proposal_id,
    "ready",
    marker_version,
    "result-marker,ready-label,devloop-ready"
  )
end

function C.cas_outcome(current, transition, incoming_version)
  if transition == "apply" then
    return "applied"
  end
  if transition == "idempotent" then
    return "skip-idempotent(already at to_state)"
  end
  if transition == "pending" then
    return "retry-pending(from-state marker not yet visible)"
  end
  if transition == "stale" then
    if type(current) == "table"
      and current.version ~= nil
      and incoming_version ~= nil
      and C._compare_transition_versions(incoming_version, current.version) < 0 then
      return "skip-stale(incoming version < current marker version)"
    end
    return "skip-advanced-or-diverged"
  end
  return tostring(transition or "unknown")
end

function C.build_reconcile_state_label_request(repo, issue_number, proposal_id, state, version, source_ref, current_labels)
  return requests_labels.build_state_label_request(repo,
    issue_number,
    state,
    proposal_id,
    version,
    base_ids.dedup_key({
      "reconcile",
      "label",
      tostring(proposal_id),
      tostring(state),
      tostring(version or "unversioned"),
    }),
    source_ref,
    current_labels
  )
end

function C.has_result_marker(comments, proposal_id, decision, dedup_key, decision_reason)
  if type(comments) ~= "table" then
    return false
  end
  -- Match the FULL marker (proposal + decision + dedup) so a stale opposite/older-version marker
  -- does not suppress writing the current decision's result marker.
  local needle = m_builders.result_marker(proposal_id, decision, dedup_key, decision_reason)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    if parsers_misc._comment_body(comment):find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local projected_handoff_kinds = {
  ready = "github-devloop.ready",
  dependency_wait = "github-devloop.ready-split-label",
}

function C.state_marker(proposal_id, state, version, effects)
  if projected_handoff_kinds[state] ~= nil then
    error("github-devloop: projected-state-marker-raw-forbidden: use the canonical comment request")
  end
  return render_state_marker(proposal_id, state, version, effects)
end

local function append_labels(target, additions)
  for _, label in ipairs(additions or {}) do table.insert(target, label) end
end

function C.build_projected_state_comment_request(args)
  local handoff_kind = type(args) == "table" and projected_handoff_kinds[args.state] or nil
  if handoff_kind == nil then
    error("github-devloop: projected-state-comment-target-invalid: target must be ready or dependency_wait")
  end
  local marker_version = tostring(args.marker_version or "")
  local label_policy = args.label_policy
  if marker_version == "" or type(args.body_before_marker) ~= "string"
    or type(args.body_after_marker) ~= "string" or type(label_policy) ~= "table"
    or label_policy.dedup_key == nil or args.comment_dedup_key == nil then
    error("github-devloop: projected-state-comment-incomplete: required request data is missing")
  end
  local label_request = requests_labels.build_state_label_request(args.repo, args.issue_number,
    args.state, args.proposal_id, marker_version, label_policy.dedup_key, args.source_ref,
    label_policy.current_labels)
  append_labels(label_request.add_labels, label_policy.add_labels)
  append_labels(label_request.remove_labels, label_policy.remove_labels)
  for _, label in ipairs(label_policy.add_labels or {}) do
    local color = devloop_base._label_colors and devloop_base._label_colors[tostring(label)]
    if color ~= nil then
      label_request.label_colors = label_request.label_colors or {}
      label_request.label_colors[tostring(label)] = color
    end
  end
  local normalized_source_ref = base_ids.normalize_source_ref(args.source_ref)
  local request = require("devloop.claims").attach_issue_claim({
    schema = "github-proxy.v1", repo = args.repo, issue_number = args.issue_number,
    body = args.body_before_marker
      .. render_state_marker(args.proposal_id, args.state, marker_version, args.effects)
      .. args.body_after_marker,
    dedup_key = args.comment_dedup_key, source_ref = normalized_source_ref,
  }, args.source_ref)
  request.handoff = {
    kind = handoff_kind, proposal_id = args.proposal_id,
    version = tostring(args.handoff_version or marker_version), marker_version = marker_version,
    label_request = label_request, source_ref = normalized_source_ref,
  }
  if args.framing ~= nil then request.handoff.framing = args.framing end
  return request
end

function S.install(M)
  for _, n in ipairs({"_compare_transition_versions", "_strip_latest_fix_version_suffix", "build_reconcile_state_label_request", "cas_outcome", "compare_state_marker_order", "current_state", "fix_version_from_review_version", "has_label", "has_result_marker", "has_terminal_label", "is_state", "is_state_label", "lifecycle_state_order", "lifecycle_state_set", "marker_order_key", "next_fix_version", "next_review_loop_version", "next_review_meta_action_version", "reached", "ready_hand_off_comment_id", "route_current", "stage_rank", "state_label", "state_label_hint_matches", "state_marker", "state_order", "state_successors", "version_fix_round", "version_loop_round", "version_order_key", "version_ready_split_round", "version_reimplement_round", "version_review_loop_round", "version_review_meta_action_round", "version_timeout_round"}) do M[n] = C[n] end
end
C.install = S.install

return C
