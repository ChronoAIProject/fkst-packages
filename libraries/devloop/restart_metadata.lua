local label_defs = require("devloop.state_labels")
local transition_version = require("contract.transition_version")

local R = {}

local label_by_state = label_defs.label_by_state
local state_labels = label_defs.state_labels
local state_graph = label_defs.state_graph
local issue_state_order = label_defs.issue_state_order
local state_order = label_defs.state_order
local state_stage_rank = label_defs.state_stage_rank
local copy_array = label_defs.copy_array

function R.is_nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, nested in pairs(value) do
    copy[key] = copy_value(nested)
  end
  return copy
end

R.copy_value = copy_value
R.copy_array = copy_array

function R.arrays_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then
      return false
    end
  end
  for key in pairs(left) do
    if type(key) ~= "number" or key < 1 or key > #left or key % 1 ~= 0 then
      return false
    end
  end
  for key in pairs(right) do
    if type(key) ~= "number" or key < 1 or key > #right or key % 1 ~= 0 then
      return false
    end
  end
  return true
end

function R.has_label(labels, expected)
  if type(labels) ~= "table" then
    return false
  end
  for _, label in ipairs(labels) do
    if tostring(label) == expected then
      return true
    end
  end
  return false
end

function R.is_state(state) return label_by_state[state] ~= nil end
function R.is_state_label(label) return state_labels[tostring(label)] == true end
function R.state_label(state) return label_by_state[state] end
function R.state_order() return copy_array(state_order) end
function R.issue_state_order() return copy_array(issue_state_order) end
function R.state_successors(state) return copy_array(state_graph[state]) end
function R.lifecycle_state_set()
  local out = {}
  for state, _ in pairs(label_by_state) do out[state] = true end
  for state, next_states in pairs(state_graph) do
    if state ~= "unmanaged" then out[state] = true end
    for _, next_state in ipairs(next_states or {}) do if next_state ~= "unmanaged" then out[next_state] = true end end
  end
  for _, state in ipairs(state_order) do out[state] = true end
  for state, _ in pairs(state_stage_rank) do out[state] = true end
  return out
end

function R.version_order_key(version)
  return transition_version.version_order_key(version)
end

function R.stage_rank(state)
  return state_stage_rank[state] or 0
end

function R.version_updated_at(version)
  return transition_version.updated_at(version)
end

function R.version_loop_round(version)
  return transition_version.loop_round(version)
end

function R.version_fix_round(version)
  return transition_version.fix_round(version)
end

function R.version_review_meta_action_round(version)
  return transition_version.review_meta_action_round(version)
end

function R.version_review_loop_round(version)
  return transition_version.review_loop_round(version)
end

function R.version_timeout_round(version, state_name)
  return transition_version.timeout_round(version, state_name)
end

function R.version_reimplement_round(version)
  return transition_version.reimplement_round(version)
end

function R.version_ready_split_round(version)
  return transition_version.ready_split_round(version)
end

function R.next_fix_version(version)
  return transition_version.next_fix(version)
end

function R.fix_version_from_review_version(version)
  return R.next_fix_version(version)
end

function R.next_review_meta_action_version(version)
  return transition_version.next_review_meta_action(version)
end

function R.next_review_loop_version(version)
  return transition_version.next_review_loop(version)
end

function R.marker_order_key(version, state_or_stage_rank)
  local stage_rank = tonumber(state_or_stage_rank)
  if stage_rank == nil then
    stage_rank = R.stage_rank(state_or_stage_rank)
  end
  return transition_version.marker_order_key(version, stage_rank)
end

local function strip_latest_fix_version_suffix(version)
  return transition_version.strip_trailing_fix(version)
end

local function compare_transition_versions(incoming_version, current_version)
  return transition_version.compare(incoming_version, current_version)
end

local function sign_order(value)
  if value > 0 then
    return 1
  end
  if value < 0 then
    return -1
  end
  return 0
end

function R.compare_state_marker_order(current, target_state, target_version)
  if current == nil or current.version == nil then
    return -1
  end
  local version_order = compare_transition_versions(current.version, target_version)
  if version_order ~= 0 then
    return sign_order(version_order)
  end
  return sign_order(R.stage_rank(current.state) - R.stage_rank(target_state))
end

function R.timeout_lineage_matches_current(scheduled, current)
  if type(scheduled) ~= "table" or type(current) ~= "table" then
    return true
  end
  if tostring(current.state or "") ~= tostring(scheduled.state or "") then
    return false, "state-advanced"
  end
  if transition_version.strip_suffixes(current.version) ~= transition_version.strip_suffixes(scheduled.version) then
    return false, "lineage-mismatch"
  end
  return true
end

local milestone_domains = {
  ["github-devloop"] = nil,
  ["github-devloop-issue"] = {
    thinking = true,
    dependency_wait = true,
    ready = true,
    implementing = true,
    ["awaiting-pr"] = true,
    ["impl-failed"] = true,
    declined = true,
    blocked = true,
    merged = true,
  },
  ["github-devloop-pr"] = {
    ["pr-open"] = true,
    reviewing = true,
    ["review-meta"] = true,
    ["merge-ready"] = true,
    merging = true,
    fixing = true,
    blocked = true,
    ["closed-unmerged"] = true,
    merged = true,
  },
}

local function domain_allows_state(domain, state)
  if domain == nil or domain == "" then
    return true
  end
  local allowed = milestone_domains[domain]
  if allowed == nil then
    return domain == "github-devloop" and R.is_state(state)
  end
  return allowed[state] == true
end

local function validate_milestone_domain(domain, milestone)
  if domain == nil or domain == "" then
    return
  end
  if milestone_domains[domain] == nil and domain ~= "github-devloop" then
    error("github-devloop: unknown milestone domain")
  end
  if not domain_allows_state(domain, milestone) then
    error("github-devloop: milestone is outside milestone domain")
  end
end

R._domain_allows_state = domain_allows_state
R._validate_milestone_domain = validate_milestone_domain

function R.compare_phase(left, right, opts)
  local options = opts or {}
  local left_state = type(left) == "table" and left.state or left
  local right_state = type(right) == "table" and right.state or right
  local right_rank = R.stage_rank(right_state)
  if not R.is_state(right_state) then
    error("github-devloop: invalid milestone")
  end
  validate_milestone_domain(options.domain or options.milestone_domain, right_state)
  local left_rank = type(left) == "table" and tonumber(left.stage_rank) or nil
  if left_rank == nil then
    if not R.is_state(left_state) then
      return nil
    end
    left_rank = R.stage_rank(left_state)
  end
  return sign_order(left_rank - right_rank)
end

function R.is_at_or_after(state_or_marker, milestone, opts)
  return (R.compare_phase(state_or_marker, milestone, opts) or -1) >= 0
end

function R.state_label_changes(to_state) return label_defs.state_label_changes(to_state) end
function R.state_label_reconcile_changes(labels, to_state) return label_defs.state_label_reconcile_changes(labels, to_state) end
function R.state_label_hint_matches(labels, state) return label_defs.state_label_hint_matches(labels, state) end

function R.has_terminal_label(labels)
  return R.has_label(labels, label_by_state.ready)
    or R.has_label(labels, label_by_state.implementing)
    or R.has_label(labels, label_by_state["pr-open"])
    or R.has_label(labels, label_by_state.reviewing)
    or R.has_label(labels, label_by_state["review-meta"])
    or R.has_label(labels, label_by_state["merge-ready"])
    or R.has_label(labels, label_by_state.merging)
    or R.has_label(labels, label_by_state.merged)
    or R.has_label(labels, label_by_state.fixing)
    or R.has_label(labels, label_by_state["impl-failed"])
    or R.has_label(labels, label_by_state.declined)
    or R.has_label(labels, label_by_state.blocked)
end

function R.has_thinking_label(labels)
  return R.has_label(labels, label_by_state.thinking)
end

function R.has_blocked_label(labels)
  return R.has_label(labels, label_by_state.blocked)
end

function R.has_ready_label(labels)
  return R.has_label(labels, label_by_state.ready)
end

function R.has_implementing_label(labels)
  return R.has_label(labels, label_by_state.implementing)
end

function R.has_pr_open_label(labels)
  return R.has_label(labels, label_by_state["pr-open"])
end

function R.has_reviewing_label(labels)
  return R.has_label(labels, label_by_state.reviewing)
end

function R.has_merge_ready_label(labels)
  return R.has_label(labels, label_by_state["merge-ready"])
end

function R.has_merging_label(labels)
  return R.has_label(labels, label_by_state.merging)
end

function R.has_merged_label(labels)
  return R.has_label(labels, label_by_state.merged)
end

function R.has_fixing_label(labels)
  return R.has_label(labels, label_by_state.fixing)
end

function R.has_review_meta_label(labels)
  return R.has_label(labels, label_by_state["review-meta"])
end

function R.has_impl_failed_label(labels)
  return R.has_label(labels, label_by_state["impl-failed"])
end

function R.has_decision_terminal_label(labels)
  return R.has_label(labels, label_by_state.ready)
    or R.has_label(labels, label_by_state.implementing)
    or R.has_label(labels, label_by_state["pr-open"])
    or R.has_label(labels, label_by_state.reviewing)
    or R.has_label(labels, label_by_state["review-meta"])
    or R.has_label(labels, label_by_state["merge-ready"])
    or R.has_label(labels, label_by_state.merging)
    or R.has_label(labels, label_by_state.merged)
    or R.has_label(labels, label_by_state.fixing)
    or R.has_label(labels, label_by_state["impl-failed"])
    or R.has_label(labels, label_by_state.declined)
    or R.has_label(labels, label_by_state.blocked)
end

function R.is_loop_terminal(labels)
  return R.has_label(labels, label_by_state.ready)
    or R.has_label(labels, label_by_state.implementing)
    or R.has_label(labels, label_by_state["pr-open"])
    or R.has_label(labels, label_by_state.reviewing)
    or R.has_label(labels, label_by_state["review-meta"])
    or R.has_label(labels, label_by_state["merge-ready"])
    or R.has_label(labels, label_by_state.merging)
    or R.has_label(labels, label_by_state.merged)
    or R.has_label(labels, label_by_state.fixing)
    or R.has_label(labels, label_by_state["impl-failed"])
    or R.has_label(labels, label_by_state.declined)
    or R.has_label(labels, label_by_state.blocked)
end

R._strip_latest_fix_version_suffix = strip_latest_fix_version_suffix
R._compare_transition_versions = compare_transition_versions

local exported_names = {
  "_compare_transition_versions",
  "_strip_latest_fix_version_suffix",
  "compare_phase",
  "compare_state_marker_order",
  "fix_version_from_review_version",
  "has_blocked_label",
  "has_decision_terminal_label",
  "has_fixing_label",
  "has_impl_failed_label",
  "has_implementing_label",
  "has_label",
  "has_merge_ready_label",
  "has_merged_label",
  "has_merging_label",
  "has_pr_open_label",
  "has_ready_label",
  "has_review_meta_label",
  "has_reviewing_label",
  "has_terminal_label",
  "has_thinking_label",
  "is_at_or_after",
  "is_loop_terminal",
  "is_state",
  "is_state_label",
  "issue_state_order",
  "lifecycle_state_set",
  "marker_order_key",
  "next_fix_version",
  "next_review_loop_version",
  "next_review_meta_action_version",
  "stage_rank",
  "state_label",
  "state_label_changes",
  "state_label_hint_matches",
  "state_label_reconcile_changes",
  "state_order",
  "state_successors",
  "timeout_lineage_matches_current",
  "version_fix_round",
  "version_loop_round",
  "version_order_key",
  "version_ready_split_round",
  "version_reimplement_round",
  "version_review_loop_round",
  "version_review_meta_action_round",
  "version_timeout_round",
  "version_updated_at",
}

function R.export_into(target)
  for _, name in ipairs(exported_names) do
    target[name] = R[name]
  end
end

return R
