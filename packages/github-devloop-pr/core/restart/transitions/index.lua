local M = {
  { module = "blocked", key = "blocked" },
  { module = "closed_unmerged", key = "closed-unmerged" },
  { module = "fixing", key = "fixing" },
  { module = "merge_ready", key = "merge-ready" },
  { module = "merged", key = "merged" },
  { module = "merging", key = "merging" },
  { module = "pr_open", key = "pr-open" },
  { module = "review_meta", key = "review-meta" },
  { module = "reviewing", key = "reviewing" },
}

function M.pr_comment_and_issue_label(edge_id)
  return {
    apply = {
      id = edge_id .. "/apply",
      effect_ids = {
        "github-proxy.github_pr_comment_request",
        "github-proxy.github_issue_label_request",
      },
    },
    idempotent = {
      id = edge_id .. "/idempotent",
      effect_ids = {},
    },
  }
end

return M
