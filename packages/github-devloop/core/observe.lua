local S = {}

function S.install(M)
local function has_devloop_state_label(labels)
  for _, label in ipairs(labels or {}) do
    if M._state_labels[tostring(label)] then
      return true
    end
  end
  return false
end

local function transition_from_history(history)
  if #history == 0 then
    return nil
  end
  local current = history[1]
  local previous = history[2]
  if previous == nil then
    return {
      from = nil,
      to = current.state,
      version = current.version,
      at = current.comment_created_at,
    }
  end
  return {
    from = previous.state,
    to = current.state,
    version = current.version,
    at = current.comment_created_at,
  }
end

function M.devloop_pipeline_graph()
  return {
    { dept = "intake_scan", consumes = { "devloop_intake_tick" }, produces = { "devloop_intake_candidate" } },
    { dept = "intake_judge", consumes = { "devloop_intake_candidate" }, produces = { "consensus.proposal", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "observe_issue", consumes = { "github-proxy.github_entity_changed" }, produces = { "consensus.proposal", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "consensus_result", consumes = { "consensus.consensus_reached" }, produces = { "devloop_ready", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "loop", consumes = { "consensus.consensus_converge" }, produces = { "consensus.proposal", "devloop_reconcile", "github-proxy.github_issue_comment_request" } },
    { dept = "reconcile", consumes = { "devloop_reconcile", "devloop_review_reconcile", "devloop_fix_reconcile" }, produces = { "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "implement", consumes = { "devloop_ready" }, produces = { "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "open_pr", consumes = { "github-proxy.github_entity_changed" }, produces = { "github-proxy.github_pr_open_request", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "observe_pr", consumes = { "github-proxy.github_entity_changed" }, produces = { "devloop_reviewing", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "review_pr", consumes = { "devloop_reviewing" }, produces = { "consensus.proposal" } },
    { dept = "review_result", consumes = { "consensus.consensus_reached" }, produces = { "devloop_merge_ready", "devloop_fixing", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "review_loop", consumes = { "consensus.consensus_converge" }, produces = { "consensus.proposal", "devloop_review_reconcile", "github-proxy.github_issue_comment_request" } },
    { dept = "fix", consumes = { "devloop_fixing" }, produces = { "devloop_reviewing", "devloop_review_meta", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "review_meta", consumes = { "devloop_review_meta" }, produces = { "devloop_fixing", "devloop_merge_ready", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "merge", consumes = { "devloop_merge_ready" }, produces = { "devloop_fixing", "github-proxy.github_issue_comment_request", "github-proxy.github_issue_label_request" } },
    { dept = "sync_scan", consumes = { "devloop_branch_tick" }, produces = { "devloop_sync_conflict" } },
    { dept = "sync_conflict", consumes = { "devloop_sync_conflict" }, produces = {} },
    { dept = "rollup_scan", consumes = { "devloop_branch_tick" }, produces = { "devloop_rollup_ready" } },
    { dept = "rollup_merge", consumes = { "devloop_rollup_ready" }, produces = {} },
    { dept = "observe_scan", consumes = { "devloop_observe_tick" }, produces = { "devloop_state_snapshot" } },
    { dept = "observe_report", consumes = { "devloop_state_snapshot" }, produces = {} },
  }
end

function M.should_observe_entity(labels, comments, proposal_id)
  local current = M.current_state(comments, proposal_id)
  return current ~= nil and current.state ~= nil
end

function M.observe_entity_summary(repo, issue_number, current)
  local proposal_id = M.proposal_id(repo, issue_number)
  local history = M.state_marker_history(current.comments, proposal_id, 2)
  local state = M.current_state(current.comments, proposal_id)
  return {
    kind = "issue",
    repo = repo,
    number = tostring(issue_number),
    proposal_id = proposal_id,
    github_state = tostring(current.state or ""),
    state = state and state.state or nil,
    version = state and state.version or nil,
    label_hint = has_devloop_state_label(current.labels),
    recent_transition = transition_from_history(history),
    source_ref = {
      kind = "external",
      ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
    },
  }
end

function M.build_state_snapshot_payload(repo, entities, snapshot_at)
  local observed_at = tostring(snapshot_at or "")
  if observed_at == "" then
    observed_at = tostring(now())
  end
  return {
    schema = "github-devloop.state-snapshot.v1",
    repo = repo,
    observed_at = observed_at,
    dedup_key = M._dedup_key({
      "state-snapshot",
      M.safe_repo(repo),
      M.safe_updated_at(observed_at),
    }),
    source_ref = {
      kind = "external",
      ref = tostring(repo) .. "#state-snapshot",
    },
    entities = entities or {},
    graph = M.devloop_pipeline_graph(),
  }
end

function M.state_snapshot_report_lines(snapshot)
  local lines = {
    "repo=" .. tostring(snapshot and snapshot.repo or ""),
    "observed_at=" .. tostring(snapshot and snapshot.observed_at or ""),
    "entities=" .. tostring(type(snapshot) == "table" and type(snapshot.entities) == "table" and #snapshot.entities or 0),
    "graph_edges=" .. tostring(type(snapshot) == "table" and type(snapshot.graph) == "table" and #snapshot.graph or 0),
  }
  for _, entity in ipairs(type(snapshot) == "table" and snapshot.entities or {}) do
    local transition = entity.recent_transition or {}
    table.insert(lines, table.concat({
      "entity=" .. tostring(entity.proposal_id or ""),
      "github_state=" .. tostring(entity.github_state or ""),
      "state=" .. tostring(entity.state or "unmanaged"),
      "version=" .. tostring(entity.version or ""),
      "recent_transition=" .. tostring(transition.from or "unmanaged") .. "->" .. tostring(transition.to or entity.state or "unmanaged"),
    }, " "))
  end
  return lines
end
end

return S
