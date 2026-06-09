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

function M.should_observe_entity(labels, comments, proposal_id)
  local current = M.current_state(comments, proposal_id)
  return current ~= nil and current.state ~= nil
end

function M.observe_issue_summary(repo, issue_number, current)
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

function M.observe_pr_summary(repo, pr_number, current)
  local origin = M.pr_origin_fact(current.comments)
  if origin == nil then
    return nil
  end
  local history = M.state_marker_history(current.comments, origin.proposal_id, 2)
  local state = M.current_state(current.comments, origin.proposal_id)
  if state == nil or state.state == nil then
    return nil
  end
  return {
    kind = "pr",
    repo = repo,
    number = tostring(pr_number),
    proposal_id = origin.proposal_id,
    issue_number = tostring(origin.issue_number or ""),
    github_state = tostring(current.state or ""),
    state = state.state,
    version = state.version,
    head_sha = tostring(current.head_sha or ""),
    head_ref_name = tostring(current.head_ref_name or ""),
    base_ref_name = tostring(current.base_ref_name or ""),
    recent_transition = transition_from_history(history),
    source_ref = {
      kind = "external",
      ref = tostring(repo) .. "#pr/" .. tostring(pr_number),
    },
  }
end

M.observe_entity_summary = M.observe_issue_summary

function M.observe_scope(issue_limit, pr_limit)
  return {
    kind = "latest",
    issue_limit = tonumber(issue_limit or 100) or 100,
    pr_limit = tonumber(pr_limit or 100) or 100,
  }
end

function M.build_state_snapshot_payload(repo, snapshot_at, scope)
  local observed_at = tostring(snapshot_at or "")
  if observed_at == "" then
    observed_at = tostring(now())
  end
  local snapshot_scope = scope or M.observe_scope()
  return {
    schema = "github-devloop.state-snapshot-ref.v1",
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
    scope = snapshot_scope,
    artifact = {
      kind = "log",
      queue = "devloop_state_snapshot",
      report_dept = "observe_report",
    },
  }
end

function M.collect_state_snapshot(repo, scope, run_cmd)
  local snapshot_scope = scope or M.observe_scope()
  local issue_limit = snapshot_scope.issue_limit or 100
  local pr_limit = snapshot_scope.pr_limit or 100
  local entities = {}

  local listed = run_cmd(M.gh_issue_list_observe_cmd(repo, issue_limit), "gh observe issue list")
  for _, issue in ipairs(M.parse_issue_list_observe(listed.stdout)) do
    local issue_number = tostring(issue.number or "")
    if M.issue_ref_round_trips(repo, issue_number) then
      local proposal_id = M.proposal_id(repo, issue_number)
      local viewed = run_cmd(M.gh_issue_view_observe_cmd(repo, issue_number), "gh observe issue view")
      local current = M.parse_issue_view_observe(viewed.stdout)
      M.log_forged_markers("observe_report", proposal_id, current.comments)
      if M.should_observe_entity(current.labels, current.comments, proposal_id) then
        table.insert(entities, M.observe_issue_summary(repo, issue_number, current))
      end
    end
  end

  local pr_listed = run_cmd(M.gh_pr_list_observe_cmd(repo, pr_limit), "gh observe PR list")
  for _, pr in ipairs(M.parse_pr_list_observe(pr_listed.stdout)) do
    local pr_number = tostring(pr.number or "")
    if M.is_safe_pr_number(pr_number) then
      local viewed = run_cmd(M.gh_pr_view_observe_cmd(repo, pr_number), "gh observe PR view")
      local current = M.parse_pr_view_observe(viewed.stdout)
      local summary = M.observe_pr_summary(repo, pr_number, current)
      if summary ~= nil then
        M.log_forged_markers("observe_report", summary.proposal_id, current.comments)
        table.insert(entities, summary)
      end
    end
  end

  return entities
end

function M.state_snapshot_report_lines(snapshot)
  local artifact = type(snapshot) == "table" and type(snapshot.artifact) == "table" and snapshot.artifact or {}
  local scope = type(snapshot) == "table" and type(snapshot.scope) == "table" and snapshot.scope or {}
  local lines = {
    "repo=" .. tostring(snapshot and snapshot.repo or ""),
    "observed_at=" .. tostring(snapshot and snapshot.observed_at or ""),
    "artifact=" .. tostring(artifact.kind or "log"),
    "scope=" .. tostring(scope.kind or "latest")
      .. " issues=" .. tostring(scope.issue_limit or "")
      .. " prs=" .. tostring(scope.pr_limit or ""),
    "entities=" .. tostring(type(snapshot) == "table" and type(snapshot.entities) == "table" and #snapshot.entities or 0),
  }
  for _, entity in ipairs(type(snapshot) == "table" and snapshot.entities or {}) do
    local transition = entity.recent_transition or {}
    table.insert(lines, table.concat({
      "entity=" .. tostring(entity.proposal_id or ""),
      "kind=" .. tostring(entity.kind or "issue"),
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
