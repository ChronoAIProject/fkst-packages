local entity_lib = require("devloop.entity")
local M = {}
local check_runs = require("forge.github.check_runs")
local git_mechanics = require("devloop.git_mechanics")
local m_mgw = require("devloop.merge_gate_wait")
local devloop_logging = require("devloop.logging")
local pr_safety = require("devloop.pr_safety")

local function log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha, probe, outcome, exit_code)
  devloop_logging.log_line("info", "merge", tostring(proposal_id or "merge-gate"), "MERGEABILITY_PROBE", {
    "pr=" .. tostring(pr and pr.number or ""),
    "base_sha=" .. tostring(base_head or ""),
    "head_sha=" .. tostring(head_sha or ""),
    "github_reason=" .. tostring(mergeable_reason or ""),
    "probe=" .. tostring(probe or ""),
    "outcome=" .. tostring(outcome or ""),
    "exit_code=" .. tostring(exit_code or ""),
  })
end

function M.should_wait_for_stale_mergeability(core, pr, branches, mergeable_reason, proposal_id)
  if not check_runs.is_not_mergeable_reason(mergeable_reason) then
    return false, "not-stale-mergeability"
  end
  local base_head, base_reason = git_mechanics.current_base_head(core.git, branches.integration)
  if base_head == nil then
    error("github-devloop: mergeability-probe-failed: " .. tostring(base_reason))
  end
  local head_sha = tostring(pr and pr.head_sha or "")
  if not pr_safety.is_safe_head_sha(head_sha) then
    error("github-devloop: mergeability-probe-failed: unsafe PR head")
  end
  local ancestry = git_mechanics.git_is_ancestor(core.git, base_head, head_sha, 30)
  if ancestry.exit_code == 0 then
    log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha,
      "merge-base-is-ancestor", "stale-verdict-rescued", ancestry.exit_code)
    return true, "stale-mergeability-current-base-contained"
  end
  local ok, result = pcall(core.git.merge_tree, base_head, head_sha, 30)
  if not ok then
    log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha,
      "merge-tree-write-tree", "probe-failed", "exception")
    error("github-devloop: mergeability-probe-failed: git merge-tree failed: " .. tostring(result))
  end
  if result.exit_code == 0 then
    log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha,
      "merge-tree-write-tree", "stale-verdict-rescued", result.exit_code)
    return true, "stale-mergeability-local-merge-clean"
  end
  if result.exit_code == 1 then
    log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha,
      "merge-tree-write-tree", "genuine-conflict-confirmed", result.exit_code)
    return false, "genuine-merge-conflict"
  end
  log_mergeability_probe(pr, proposal_id, mergeable_reason, base_head, head_sha,
    "merge-tree-write-tree", "probe-failed", result.exit_code)
  error("github-devloop: mergeability-probe-failed: git merge-tree exited "
    .. tostring(result.exit_code) .. ": " .. tostring(result.stderr or ""))
end

function M.is_mergeability_wait(pr, reason)
  local mergeable, derived_reason = check_runs.pr_mergeable(pr)
  return not mergeable
    and derived_reason == tostring(reason or "")
    and derived_reason ~= "missing-pr"
    and derived_reason ~= "missing-mergeability"
    and not check_runs.is_not_mergeable_reason(derived_reason)
end

function M.hold(core, merge_ready, repo, current_pr, classification)
  local reason = tostring(classification and classification.reason or "ci-wait")
  local source_ref = entity_lib.pr_source_ref(repo, merge_ready.pr_number)
  local comment_request = m_mgw.build_merge_gate_wait_comment_request(repo,
    merge_ready,
    reason,
    classification and classification.kind or "CI_WAIT",
    source_ref
  )
  devloop_logging.log_raise("merge", merge_ready.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
  devloop_logging.log_line("info", "merge", merge_ready.proposal_id, "GATE", {
    "pr=" .. tostring(merge_ready.pr_number),
    "version=" .. tostring(merge_ready.version),
    "outcome=hold",
    "reason=" .. reason,
    "ci_class=" .. tostring(classification and classification.kind or ""),
    "head_sha=" .. tostring(current_pr and current_pr.head_sha or ""),
  })
  return { status = "hold", reason = reason }
end

return M
