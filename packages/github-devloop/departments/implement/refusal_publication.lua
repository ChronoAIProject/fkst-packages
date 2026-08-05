local base_ids = require("devloop.base_ids")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")

local M = {}

function M.publish(core, repo, issue_number, outcome)
  local precursor_missing = outcome.reason == "precursor-missing"
  local target_state = precursor_missing and "dependency_wait" or "blocked"
  local target_version = precursor_missing
      and core.ready_split_version(outcome.ready.dedup_key)
    or outcome.ready.dedup_key
  local comment_request = requests_lifecycle.build_implementation_refusal_comment_request(
    core,
    repo,
    issue_number,
    outcome.ready,
    outcome.reason,
    outcome.evidence,
    outcome.attempt,
    outcome.started_at,
    outcome.exec_ref,
    outcome.blocker
  )
  local label_request = requests_labels.build_state_label_request(
    repo,
    issue_number,
    target_state,
    outcome.ready.proposal_id,
    target_version,
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
  if precursor_missing then
    table.insert(label_request.add_labels, core._blocked_on_dependency_label)
    label_request.label_colors = label_request.label_colors or {}
    label_request.label_colors[core._blocked_on_dependency_label] =
      core._label_colors[core._blocked_on_dependency_label]
  end
  local add_labels, remove_labels = devloop_state.state_label_changes(target_state)
  if precursor_missing then
    table.insert(add_labels, core._blocked_on_dependency_label)
  end
  local raised = {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
  }
  local blocked_by_request = nil
  if precursor_missing then
    blocked_by_request = {
      schema = "github-proxy.issue-blocked-by.v1",
      repo = repo,
      blocked_issue_number = tonumber(issue_number),
      blocking_issue_number = outcome.blocker.issue_number,
      dedup_key = base_ids.dedup_key({
        "implement",
        "precursor",
        "blocked-by",
        tostring(outcome.ready.proposal_id),
        tostring(outcome.ready.dedup_key),
        tostring(outcome.blocker.issue_number),
      }),
      source_ref = base_ids.normalize_source_ref(outcome.ready.source_ref),
    }
    table.insert(raised, "github-proxy.github_issue_blocked_by_request")
  end
  devloop_logging.log_apply("implement", outcome.ready.proposal_id, target_state, target_version,
    { add = add_labels, remove = remove_labels }, raised)
  devloop_logging.log_raise(
    "implement", outcome.ready.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise(
    "implement", outcome.ready.proposal_id, "github-proxy.github_issue_label_request", label_request)
  if blocked_by_request ~= nil then
    devloop_logging.log_raise(
      "implement", outcome.ready.proposal_id,
      "github-proxy.github_issue_blocked_by_request", blocked_by_request)
  end
end

return M
