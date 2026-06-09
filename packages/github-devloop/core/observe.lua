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

local function copy_array(value)
  local copied = {}
  if type(value) == "string" then
    table.insert(copied, value)
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      table.insert(copied, tostring(item))
    end
  end
  table.sort(copied)
  return copied
end

local function read_department_spec(path)
  local previous_pipeline = _G.pipeline
  local ok, dept = pcall(dofile, path)
  _G.pipeline = previous_pipeline
  if not ok or type(dept) ~= "table" or type(dept.spec) ~= "table" then
    return nil
  end
  return dept.spec
end

function M.devloop_pipeline_graph(department_paths)
  local paths = department_paths or {}
  local graph = {}
  for _, path in ipairs(paths) do
    local dept = tostring(path):match("departments/([^/]+)/main%.lua$")
    local spec = dept and read_department_spec(path) or nil
    if spec ~= nil then
      table.insert(graph, {
        dept = dept,
        consumes = copy_array(spec.consumes),
        produces = copy_array(spec.produces),
        fanout = copy_array(spec.fanout),
      })
    end
  end
  table.sort(graph, function(a, b)
    return tostring(a.dept) < tostring(b.dept)
  end)
  return graph
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

function M.build_state_snapshot_payload(repo, entities, graph, snapshot_at)
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
    graph = graph or {},
    artifact = {
      kind = "log",
      queue = "devloop_state_snapshot",
      report_dept = "observe_report",
    },
  }
end

function M.state_snapshot_report_lines(snapshot)
  local artifact = type(snapshot) == "table" and type(snapshot.artifact) == "table" and snapshot.artifact or {}
  local lines = {
    "repo=" .. tostring(snapshot and snapshot.repo or ""),
    "observed_at=" .. tostring(snapshot and snapshot.observed_at or ""),
    "artifact=" .. tostring(artifact.kind or "log"),
    "entities=" .. tostring(type(snapshot) == "table" and type(snapshot.entities) == "table" and #snapshot.entities or 0),
    "graph_edges=" .. tostring(type(snapshot) == "table" and type(snapshot.graph) == "table" and #snapshot.graph or 0),
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
