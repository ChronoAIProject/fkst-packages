local base_ids = require("devloop.base_ids")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")

local M = {}

function M.publish(core, repo, issue_number, outcome)
  local comment_request = requests_lifecycle.build_implementation_refusal_comment_request(
    core,
    repo,
    issue_number,
    outcome.ready,
    outcome.reason,
    outcome.evidence,
    outcome.attempt,
    outcome.started_at,
    outcome.exec_ref
  )
  local label_request = requests_labels.build_state_label_request(
    repo,
    issue_number,
    "blocked",
    outcome.ready.proposal_id,
    outcome.ready.dedup_key,
    base_ids.dedup_key({
      "implement",
      "label",
      "implementation-refusal",
      tostring(outcome.reason),
      tostring(outcome.attempt),
      tostring(outcome.ready.dedup_key),
    }),
    outcome.ready.source_ref
  )
  local add_labels, remove_labels = devloop_state.state_label_changes("blocked")
  devloop_logging.log_apply("implement", outcome.ready.proposal_id, "blocked", outcome.ready.dedup_key,
    { add = add_labels, remove = remove_labels }, {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    })
  devloop_logging.log_raise(
    "implement", outcome.ready.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise(
    "implement", outcome.ready.proposal_id, "github-proxy.github_issue_label_request", label_request)
end

return M
