local function effect_entitlements(semantic_variant)
  local id = "github-devloop-pr/reviewing/operator_reentry/" .. semantic_variant
  return {
    apply = { id = id .. "/apply", effect_ids = { "github-proxy.github_pr_comment_request" } },
    idempotent = { id = id .. "/idempotent", effect_ids = {} },
  }
end

return {
  {
    semantic_variant = "rereview_blocked",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "operator_reentry",
    source = {
      state = "blocked",
      boundary = nil,
    },
    target = "reviewing",
    transition_effect_entitlements = effect_entitlements("rereview_blocked"),
    pending_order = { participates = false },
    cause_evidence = {
      command = "rereview",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "operator_reentry_inventory.rereview_blocked",
    },
  },
  {
    semantic_variant = "rereview_review_meta",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "operator_reentry",
    source = {
      state = "review-meta",
      boundary = nil,
    },
    target = "reviewing",
    transition_effect_entitlements = effect_entitlements("rereview_review_meta"),
    pending_order = { participates = false },
    cause_evidence = {
      command = "rereview",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "operator_reentry_inventory.rereview_review_meta",
    },
  },
  {
    semantic_variant = "rereview_reviewing",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "operator_reentry",
    source = {
      state = "reviewing",
      boundary = nil,
    },
    target = "reviewing",
    transition_effect_entitlements = effect_entitlements("rereview_reviewing"),
    pending_order = { participates = false },
    cause_evidence = {
      command = "rereview",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "operator_reentry_inventory.rereview_reviewing",
    },
  },
}
