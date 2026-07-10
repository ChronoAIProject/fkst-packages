local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")

local C = {}

function C.raise_reviewing(M, dept, issue, state, proposal_id, link, current_pr, feedback, tools, reason)
  local new_version = devloop_state.next_fix_version(state.version)
  local source_ref = entity_lib.pr_source_ref(issue.repo, link.pr_number)
  local fix = {
    proposal_id = proposal_id,
    pr_number = link.pr_number,
    version = state.version,
    review_proposal_id = feedback.review_proposal_id,
    review_dedup_key = feedback.review_dedup_key,
    reviewed_head_sha = feedback.reviewed_head_sha,
    source_ref = source_ref,
  }
  local effects = {
    {
      queue = "github-proxy.github_pr_comment_request",
      payload = requests_review.build_fix_reviewing_comment_request(M, issue.repo, issue.number, fix, feedback.reviewed_head_sha, current_pr.head_sha, new_version),
    },
  }
  if issue.number ~= nil then
    table.insert(effects, {
      queue = "github-proxy.github_issue_label_request",
      payload = requests_labels.build_state_label_request(issue.repo, issue.number, "reviewing", base_ids.dedup_key({
        "fixing",
        "label",
        "reviewing",
        tostring(proposal_id),
        tostring(new_version),
        tostring(link.pr_number),
        tostring(current_pr.head_sha),
      }), entity_lib.issue_source_ref(issue.repo, issue.number)),
    })
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "fixing", "reviewing", "applied(replay)", reason)
  return tools.raise_effects(dept, proposal_id, "reviewing", new_version, { add = { "fkst-dev:reviewing" }, remove = { "fkst-dev:fixing" } }, effects)
end

return C
