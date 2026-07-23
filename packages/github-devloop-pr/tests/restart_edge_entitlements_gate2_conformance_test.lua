local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")

local t = h.t
local owner = h.core.restart_package_name
local rows = h.core.restart_transition_table()
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}

local PR_COMMENT = "github-proxy.github_pr_comment_request"
local ISSUE_LABEL = "github-proxy.github_issue_label_request"
local expected_new_apply_effects = {
  ["github-devloop-pr/fixing/autonomous/fix_budget_exhausted"] = { "devloop_fix_reconcile" },
  ["github-devloop-pr/fixing/autonomous/revision_failed"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/merge-ready/autonomous/fix_budget_exhausted"] = { "devloop_fix_reconcile" },
  ["github-devloop-pr/merge-ready/guard_boundary/merge_gate/approval_stale"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/merge-ready/guard_boundary/merge_gate/code_repair_needed"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/merge-ready/guard_boundary/merge_gate/eligible_now"] = {},
  ["github-devloop-pr/merging/autonomous/fix_budget_exhausted"] = { "devloop_fix_reconcile" },
  ["github-devloop-pr/merging/autonomous/head-advanced"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/merging/autonomous/merge-completed"] = { PR_COMMENT },
  ["github-devloop-pr/merging/autonomous/merge-needs-fix"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/pr-open/autonomous/review_requested"] = { PR_COMMENT },
  ["github-devloop-pr/pr-open/entry/pr_open_handoff"] = { "devloop_observe_pr" },
  ["github-devloop-pr/pr-open/guard_boundary/pr_base_unmanaged"] = { PR_COMMENT },
  ["github-devloop-pr/reviewing/canonicalization/fixing_head_renormalization"] = { PR_COMMENT, ISSUE_LABEL },
  ["github-devloop-pr/reviewing/canonicalization/pr_base_unmanaged_self_heal"] = { PR_COMMENT },
  ["github-devloop-pr/reviewing/operator_reentry/rereview_blocked"] = { PR_COMMENT },
  ["github-devloop-pr/reviewing/operator_reentry/rereview_review_meta"] = { PR_COMMENT },
  ["github-devloop-pr/reviewing/operator_reentry/rereview_reviewing"] = { PR_COMMENT },
}

local function assert_array(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do t.eq(actual[index], value) end
end

return {
  test_pr_owner_every_canonical_edge_has_closed_effect_entitlements = function()
    local edges = owner_projection.edges(owner, rows, inventories)
    t.eq(#edges, 43)
    for _, edge in ipairs(edges) do
      local entitlements = edge.transition_effect_entitlements
      t.eq(type(entitlements), "table", edge.id .. " missing transition_effect_entitlements")
      for _, status in ipairs({ "apply", "idempotent" }) do
        local entitlement = entitlements[status]
        t.eq(type(entitlement), "table", edge.id .. " missing " .. status .. " entitlement")
        t.eq(entitlement.id, edge.id .. "/" .. status)
        t.eq(type(entitlement.effect_ids), "table")
      end
      local expected = expected_new_apply_effects[edge.id]
      if expected ~= nil then
        assert_array(entitlements.apply.effect_ids, expected)
        if edge.id == "github-devloop-pr/pr-open/entry/pr_open_handoff" then
          assert_array(entitlements.idempotent.effect_ids, expected)
        else
          assert_array(entitlements.idempotent.effect_ids, {})
        end
      end
    end
  end,
}
