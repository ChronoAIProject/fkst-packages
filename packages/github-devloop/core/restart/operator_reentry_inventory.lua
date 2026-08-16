return {
  {
    semantic_variant = "reimplement_impl_failed",
    owner = "github-devloop",
    row_id = "implementing",
    kind = "operator_reentry",
    source = {
      state = "impl-failed",
      boundary = nil,
    },
    target = "implementing",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/implementing/operator_reentry/reimplement_impl_failed/apply",
        effect_ids = { "github-proxy.github_issue_comment_request", "devloop_ready" },
      },
      idempotent = {
        id = "github-devloop/implementing/operator_reentry/reimplement_impl_failed/idempotent",
        effect_ids = {},
      },
    },
    pending_order = { participates = true, predecessor_state = "impl-failed" },
    cause_evidence = {
      command = "reimplement",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop",
      row = "implementing",
      field = "operator_reentry_inventory.reimplement_impl_failed",
    },
  },
  {
    semantic_variant = "reimplement_blocked_open_pr",
    owner = "github-devloop",
    row_id = "implementing",
    kind = "operator_reentry",
    source = {
      state = "blocked",
      boundary = "open-pr",
    },
    target = "implementing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_implement_activation_handoff_v1",
    cas_variant = "blocked_to_implementing",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_open_pr/apply",
        effect_ids = {
          "github-proxy.github_issue_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_open_pr/idempotent",
        effect_ids = {},
      },
    },
    cause_evidence = {
      command = "reimplement",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop",
      row = "implementing",
      field = "operator_reentry_inventory.reimplement_blocked_open_pr",
    },
  },
  {
    semantic_variant = "reimplement_blocked_implementing_timeout_without_pr",
    owner = "github-devloop",
    row_id = "implementing",
    kind = "operator_reentry",
    source = {
      state = "blocked",
      boundary = "implementing-timeout-without-pr",
    },
    target = "implementing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_implement_activation_handoff_v1",
    cas_variant = "blocked_to_implementing",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_implementing_timeout_without_pr/apply",
        effect_ids = {
          "github-proxy.github_issue_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_implementing_timeout_without_pr/idempotent",
        effect_ids = {},
      },
    },
    cause_evidence = {
      command = "reimplement",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop",
      row = "implementing",
      field = "operator_reentry_inventory.reimplement_blocked_implementing_timeout_without_pr",
    },
  },
  {
    semantic_variant = "reimplement_blocked_implementation_refusal",
    owner = "github-devloop",
    row_id = "implementing",
    kind = "operator_reentry",
    source = {
      state = "blocked",
      boundary = "implementation-refusal",
    },
    target = "implementing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_implement_activation_handoff_v1",
    cas_variant = "blocked_to_implementing",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_implementation_refusal/apply",
        effect_ids = {
          "github-proxy.github_issue_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop/implementing/operator_reentry/reimplement_blocked_implementation_refusal/idempotent",
        effect_ids = {},
      },
    },
    cause_evidence = {
      command = "reimplement",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop",
      row = "implementing",
      field = "operator_reentry_inventory.reimplement_blocked_implementation_refusal",
    },
  },
  {
    semantic_variant = "reready_blocked_dependency_hold",
    owner = "github-devloop",
    row_id = "dependency_wait",
    kind = "operator_reentry",
    source = {
      state = "blocked",
      boundary = "dependency-hold",
    },
    target = "dependency_wait",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop/dependency_wait/operator_reentry/reready_blocked_dependency_hold/apply",
        effect_ids = { "github-proxy.github_issue_comment_request" },
      },
      idempotent = {
        id = "github-devloop/dependency_wait/operator_reentry/reready_blocked_dependency_hold/idempotent",
        effect_ids = {},
      },
    },
    pending_order = { participates = false },
    cause_evidence = {
      command = "reready",
      requires_applied_certificate = true,
      resolver = "operator_commands",
    },
    provenance = {
      owner = "github-devloop",
      row = "dependency_wait",
      field = "operator_reentry_inventory.reready_blocked_dependency_hold",
    },
  },
}
