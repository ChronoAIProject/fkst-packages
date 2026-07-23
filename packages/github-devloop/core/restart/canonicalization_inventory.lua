local function effect_entitlements(row_id, semantic_variant)
  local id = "github-devloop/" .. row_id .. "/canonicalization/" .. semantic_variant
  return {
    apply = { id = id .. "/apply", effect_ids = {
      "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request",
    } },
    idempotent = { id = id .. "/idempotent", effect_ids = {} },
  }
end

return {
  {
    semantic_variant = "legacy_ready_dependency_hold",
    owner = "github-devloop",
    row_id = "dependency_wait",
    kind = "canonicalization",
    source = {
      state = "ready",
      boundary = nil,
    },
    target = "dependency_wait",
    transition_effect_entitlements = effect_entitlements("dependency_wait", "legacy_ready_dependency_hold"),
    pending_order = { participates = true, predecessor_state = "ready" },
    cause_evidence = {
      marker = "ready-split-canonicalized:v1",
      resolver = "ready_split_canonicalized_fact",
    },
    provenance = {
      owner = "github-devloop",
      row = "dependency_wait",
      field = "canonicalization_inventory.legacy_ready_dependency_hold",
    },
  },
  {
    semantic_variant = "legacy_ready_rederive",
    owner = "github-devloop",
    row_id = "ready",
    kind = "canonicalization",
    source = {
      state = "ready",
      boundary = nil,
    },
    target = "ready",
    transition_effect_entitlements = effect_entitlements("ready", "legacy_ready_rederive"),
    pending_order = { participates = false },
    cause_evidence = {
      marker = "ready-split-canonicalized:v1",
      resolver = "ready_split_canonicalized_fact",
    },
    provenance = {
      owner = "github-devloop",
      row = "ready",
      field = "canonicalization_inventory.legacy_ready_rederive",
    },
  },
  {
    semantic_variant = "implementing_merged_delegated_pr",
    owner = "github-devloop",
    row_id = "awaiting-pr",
    kind = "canonicalization",
    source = {
      state = "implementing",
      boundary = nil,
    },
    target = "awaiting-pr",
    pending_order = { participates = true, predecessor_state = "implementing" },
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "implementing_to_awaiting_pr",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/awaiting-pr/canonicalization/implementing_merged_delegated_pr/apply",
        effect_ids = {
          "github-proxy.github_issue_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop/awaiting-pr/canonicalization/implementing_merged_delegated_pr/idempotent",
        effect_ids = {},
      },
    },
    cause_evidence = {
      marker = "pr-delegation:v1",
      resolver = "pr_delegation_fact",
    },
    provenance = {
      owner = "github-devloop",
      row = "awaiting-pr",
      field = "canonicalization_inventory.implementing_merged_delegated_pr",
    },
  },
  {
    semantic_variant = "legacy_pr_open_delegation",
    owner = "github-devloop",
    row_id = "awaiting-pr",
    kind = "canonicalization",
    source = {
      state = "pr-open",
      boundary = nil,
    },
    target = "awaiting-pr",
    transition_effect_entitlements = effect_entitlements("awaiting-pr", "legacy_pr_open_delegation"),
    pending_order = { participates = false },
    cause_evidence = {
      marker = "pr-delegation:v1",
      resolver = "pr_delegation_fact",
    },
    provenance = {
      owner = "github-devloop",
      row = "awaiting-pr",
      field = "canonicalization_inventory.legacy_pr_open_delegation",
    },
  },
}
