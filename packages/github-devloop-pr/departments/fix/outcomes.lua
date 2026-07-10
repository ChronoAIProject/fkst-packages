local devloop_state = require("devloop.state")
local devloop_logging = require("devloop.logging")

local C = {}

local function bounded_fix_summary(value)
  local text = tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 600 then
    text = text:sub(1, 600)
  end
  return text
end

function C.make(caps)
local M = {}

function M.raise_review_meta(repo, issue_number, fix, reason, detail)
  local comment_request = caps.build_fix_review_meta_comment_request(repo, issue_number, fix, reason, detail)
  local label_request = caps.build_fix_review_meta_label_request(repo, issue_number, fix, reason)
  local add_labels, remove_labels = devloop_state.state_label_changes("review-meta")
  devloop_logging.log_apply("fix", fix.proposal_id, "review-meta", fix.version, { add = add_labels, remove = remove_labels }, {
    "github-proxy.github_pr_comment_request",
    "github-proxy.github_issue_label_request",
    "devloop_review_meta",
  })
  devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
  if issue_number ~= nil then
    devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_issue_label_request", label_request)
  end
  devloop_logging.log_raise("fix", fix.proposal_id, "devloop_review_meta", {
    schema = "github-devloop.review-meta.v1",
    proposal_id = fix.proposal_id,
    review_proposal_id = fix.review_proposal_id,
    review_dedup_key = fix.review_dedup_key,
    version = fix.version,
    pr_number = fix.pr_number,
    n = 0,
    dedup_key = fix.dedup_key,
    source_ref = fix.source_ref,
  })
end

function M.raise_reviewing(repo, issue_number, fix, old_head_sha, new_head_sha, reason, summary)
  caps.raise_fix_reviewing({
    dept = "fix",
    repo = repo,
    issue_number = issue_number,
    fix = fix,
    old_head_sha = old_head_sha,
    new_head_sha = new_head_sha,
    reason = reason,
    fix_summary = bounded_fix_summary(summary),
    clear_fix_summary = true,
  })
end

return M
end

return C
