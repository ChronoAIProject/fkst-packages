local core = require("core")

return {
  parse_worktrees = core.parse_worktrees,
  parse_proposal_repo_issue = core.parse_proposal_repo_issue,
  live_branches = core.live_branches,
  is_deterministic_devloop_branch = core.is_deterministic_devloop_branch,
  issue_ref_from_branch = core.issue_ref_from_branch,
  fix_owner_branch = core.fix_owner_branch,
  branch_release_fact = core.branch_release_fact,
  classify = core.classify,
}
