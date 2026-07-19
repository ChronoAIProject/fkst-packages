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

local function marker_attrs(marker)
  local attrs = {}
  for key, value in tostring(marker or ""):gmatch('([%w._-]+)="([^"]*)"') do
    attrs[key] = value
  end
  return attrs
end

function C.state_marker(proposal_id, state, version, effects)
  if not C.is_state(state) then
    error("github-devloop: invalid state")
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

local function derive_current_marker(comments, proposal_id)
  if type(comments) ~= "table" then
    return nil
  end

  local current = nil
  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = state_marker_fact(marker, comment)
      if candidate ~= nil and candidate.proposal_id == proposal_id then
        candidate = {
          state = candidate.state,
          version = candidate.version,
          stage_rank = candidate.stage_rank,
          marker_created_at = candidate.marker_created_at,
        }
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

function C.reintake_has_active_devloop_state(labels, comments, proposal_id)
  local current = current_marker_state(comments, proposal_id)
  if current ~= nil then
    return tostring(current.state or "") ~= "blocked"
  end
  return devloop_base.is_opted_in(labels) or has_any_state_label(labels)
end

local function later_timestamp(left, right)
  local l = tostring(left or "")
  local r = tostring(right or "")
  if r ~= "" and (l == "" or r > l) then
    return r
  end
  return l ~= "" and l or nil
end

function C.reintake_effect_updated_at(issue, command, comments, proposal_id)
  local updated_at = (command and command.created_at) or (issue and issue.updated_at)
  local current = current_marker_state(comments, proposal_id)
  if command ~= nil and current ~= nil and tostring(current.state or "") == "blocked" then
    updated_at = later_timestamp(updated_at, current.marker_created_at)
  end
  return updated_at or (issue and issue.updated_at)
end

function C.reached(comments, proposal_id, milestone, opts)
  if type(comments) ~= "table" then
    return false
  end
  local options = opts or {}
  if not C.is_state(milestone) then
    error("github-devloop: invalid milestone")
  end
  local domain = options.domain or options.milestone_domain
  restart_metadata._validate_milestone_domain(domain, milestone)

  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
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
  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
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

function C.state_marker_comment_id(comments, proposal_id, state, version, effects)
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
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
  return C.state_marker_comment_id(
    comments,
    proposal_id,
    "ready",
    marker_version,
    "result-marker,ready-label,devloop-ready"
  )
end

local function normalize_state(state)
  if state == nil then
    return "unmanaged"
  end
  return state
end

local function can_reach(from_state, to_state, seen)
  local from = normalize_state(from_state)
  if from == to_state then
    return true
  end
  local next_states = restart_metadata.state_successors(from)
  if next_states == nil then
    return false
  end
  local visited = seen or {}
  if visited[from] then
    return false
  end
  visited[from] = true
  for _, next_state in ipairs(next_states) do
    if can_reach(next_state, to_state, visited) then
      return true
    end
  end
  return false
end

function C.transition_status(current, from_states, to_state)
  local current_state = current
  if type(current) == "table" then
    current_state = current.state
  end
  if current_state == to_state then
    return "idempotent"
  end
  local normalized_current = normalize_state(current_state)
  for _, from_state in ipairs(from_states or {}) do
    if normalized_current == normalize_state(from_state) then
      return "apply"
    end
  end
  for _, from_state in ipairs(from_states or {}) do
    if can_reach(normalized_current, normalize_state(from_state)) then
      return "pending"
    end
  end
  return "stale"
end

function C.versioned_transition_status(current, from_states, to_state, incoming_version)
  if type(current) == "table"
    and current.version ~= nil
    and incoming_version ~= nil
    and C._compare_transition_versions(incoming_version, current.version) < 0 then
    return "stale"
  end
  local status = C.transition_status(current, from_states, to_state)
  return status
end

function C.cyclic_transition_status(current, from_states, to_state, incoming_version, target_version)
  local current_state = current
  local current_version = nil
  if type(current) == "table" then
    current_state = current.state
    current_version = current.version
  end
  if incoming_version == nil then
    return C.transition_status(current, from_states, to_state)
  end
  if target_version ~= nil and current_state == to_state and versions_equivalent(current_version, target_version) then
    return "idempotent"
  end

  local version_order = C._compare_transition_versions(incoming_version, current_version)
  if version_order > 0 then
    return "pending"
  end
  if version_order < 0 then
    return "stale"
  end

  if current_state == to_state then
    return "idempotent"
  end
  local normalized_current = normalize_state(current_state)
  for _, from_state in ipairs(from_states or {}) do
    if normalized_current == normalize_state(from_state) then
      return "apply"
    end
  end
  if C.stage_rank(to_state) > C.stage_rank(current_state) then
    return "apply"
  end
  return "stale"
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



function S.install(M)
  for _, n in ipairs({"_compare_transition_versions", "_strip_latest_fix_version_suffix", "build_reconcile_state_label_request", "cas_outcome", "comment_bodies", "compare_phase", "compare_state_marker_order", "current_state", "cyclic_transition_status", "fix_version_from_review_version", "has_blocked_label", "has_decision_terminal_label", "has_fixing_label", "has_impl_failed_label", "has_implementing_label", "has_label", "has_merge_ready_label", "has_merged_label", "has_merging_label", "has_pr_open_label", "has_ready_label", "has_result_marker", "has_review_meta_label", "has_reviewing_label", "has_state_marker", "has_terminal_label", "has_thinking_label", "is_at_or_after", "is_loop_terminal", "is_state", "is_state_label", "issue_state_order", "lifecycle_state_set", "marker_order_key", "next_fix_version", "next_review_loop_version", "next_review_meta_action_version", "reached", "ready_hand_off_comment_id", "stage_rank", "state_label", "state_label_changes", "state_label_hint_matches", "state_label_reconcile_changes", "state_marker", "state_marker_comment_id", "state_order", "state_successors", "timeout_lineage_matches_current", "transition_status", "version_fix_round", "version_loop_round", "version_order_key", "version_ready_split_round", "version_reimplement_round", "version_review_loop_round", "version_review_meta_action_round", "version_timeout_round", "version_updated_at", "versioned_transition_status"}) do M[n] = C[n] end
end
C.install = S.install

return C
