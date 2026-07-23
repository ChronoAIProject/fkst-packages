local function effect_entitlements(semantic_variant, effect_ids)
  local id = "github-devloop-pr/reviewing/canonicalization/" .. semantic_variant
  return {
    apply = { id = id .. "/apply", effect_ids = effect_ids },
    idempotent = { id = id .. "/idempotent", effect_ids = {} },
  }
end

return {
  {
    semantic_variant = "fixing_head_renormalization",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "canonicalization",
    source = {
      state = "fixing",
      boundary = nil,
    },
    target = "reviewing",
    transition_effect_entitlements = effect_entitlements("fixing_head_renormalization", {
      "github-proxy.github_pr_comment_request", "github-proxy.github_issue_label_request",
    }),
    pending_order = { participates = true, predecessor_state = "fixing" },
    cause_evidence = {
      marker = "fix:v1",
      resolver = "has_fix_marker",
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "canonicalization_inventory.fixing_head_renormalization",
    },
  },
  {
    semantic_variant = "pr_base_unmanaged_self_heal",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "canonicalization",
    source = {
      state = "blocked",
      boundary = nil,
    },
    target = "reviewing",
    transition_effect_entitlements = effect_entitlements("pr_base_unmanaged_self_heal", {
      "github-proxy.github_pr_comment_request",
    }),
    pending_order = { participates = false },
    cause_evidence = {
      marker = "state:v1",
      resolver = "current_entity_state",
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "canonicalization_inventory.pr_base_unmanaged_self_heal",
    },
  },
}
