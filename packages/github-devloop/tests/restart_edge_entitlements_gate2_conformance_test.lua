local h = require("tests.devloop_core_helpers")
local restart_edges = require("devloop.restart_edges")
local owner_projection = require("devloop.restart_owner_pending_projection")

local t = h.t
local owner = h.core.restart_package_name
local rows = h.core.restart_transition_table()
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}

local expected_new_apply_effects = {
  ["github-devloop/awaiting-pr/canonicalization/legacy_pr_open_delegation"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/dependency_wait/canonicalization/legacy_ready_dependency_hold"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/dependency_wait/guard_boundary/blockers_released"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/dependency_wait/guard_boundary/blockers_still_open"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/dependency_wait/guard_boundary/dependency_resolver_stale"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/implementing/autonomous/revision_failed"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/implementing/autonomous/revision_published"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/implementing/operator_reentry/reimplement_impl_failed"] = {
    "github-proxy.github_issue_comment_request", "devloop_ready",
  },
  ["github-devloop/ready/canonicalization/legacy_ready_rederive"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/ready/guard_boundary/blocker_reappeared"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
  },
  ["github-devloop/thinking/entry/execute_request"] = {
    "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request", "consensus.proposal",
  },
}

local function copy_value(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, nested in pairs(value) do copy[key] = copy_value(nested) end
  return copy
end

local function assert_array(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do t.eq(actual[index], value) end
end

local function assert_closed(edge)
  local entitlements = edge.transition_effect_entitlements
  t.eq(type(entitlements), "table", edge.id .. " missing transition_effect_entitlements")
  for _, status in ipairs({ "apply", "idempotent" }) do
    local entitlement = entitlements[status]
    t.eq(type(entitlement), "table", edge.id .. " missing " .. status .. " entitlement")
    t.eq(entitlement.id, edge.id .. "/" .. status)
    t.eq(type(entitlement.effect_ids), "table")
  end
end

local function assert_missing_rejected(extract)
  local ok = pcall(extract)
  t.eq(ok, false)
end

local function row_by_state(state)
  for _, row in ipairs(rows) do
    if row.from_state == state then return row end
  end
  error("missing test row " .. state)
end

return {
  test_issue_owner_every_canonical_edge_has_closed_effect_entitlements = function()
    local edges = owner_projection.edges(owner, rows, inventories)
    t.eq(#edges, 26)
    for _, edge in ipairs(edges) do
      assert_closed(edge)
      local expected = expected_new_apply_effects[edge.id]
      if expected ~= nil then
        assert_array(edge.transition_effect_entitlements.apply.effect_ids, expected)
        if edge.id == "github-devloop/thinking/entry/execute_request" then
          assert_array(edge.transition_effect_entitlements.idempotent.effect_ids, expected)
        else
          assert_array(edge.transition_effect_entitlements.idempotent.effect_ids, {})
        end
      end
    end
  end,

  test_all_edge_extractors_fail_closed_on_a_genuinely_missing_entitlement = function()
    local autonomous_row = copy_value(row_by_state("implementing"))
    autonomous_row.responsibility_signature.successors[1].transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_autonomous_edges(owner, { autonomous_row }) end)

    local guard_row = copy_value(row_by_state("dependency_wait"))
    guard_row.responsibility_signature.successors[1].transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_guard_boundary_edges(owner, { guard_row }) end)

    local timeout_row = copy_value(row_by_state("ready"))
    timeout_row.responsibility_signature.successors[2].transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_timeout_edges(owner, { timeout_row }) end)

    local entry = copy_value(inventories.entry[1])
    entry.transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_entry_edges(owner, { entry }, rows) end)

    local operator_reentry = copy_value(inventories.operator_reentry[1])
    operator_reentry.transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_operator_reentry_edges(owner, { operator_reentry }) end)

    local canonicalization = copy_value(inventories.canonicalization[1])
    canonicalization.transition_effect_entitlements = nil
    assert_missing_rejected(function() restart_edges.extract_canonicalization_edges(owner, { canonicalization }) end)
  end,
}
