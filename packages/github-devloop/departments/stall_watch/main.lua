local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_observe_tick", "github-proxy.github_entity_changed" },
  produces = {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  },
  fanout = { "devloop_observe_tick", "github-proxy.github_entity_changed" },
  ephemeral = { "devloop_observe_tick" },
  retry = false,
  stall_window = "2m",
}

local dept = "stall_watch"

local function require_repo()
  local repo = core.read_env("FKST_GITHUB_REPO")
  if repo == nil or core.safe_repo(repo) ~= tostring(repo) then
    error("github-devloop: FKST_GITHUB_REPO is required for stall_watch")
  end
  return repo
end

local function log_skip(proposal_id, reason, detail)
  core.log_line("warn", dept, proposal_id or "unknown", "STALL_WATCH_SKIP", {
    "reason=" .. tostring(reason or "unknown"),
    "detail=" .. core._one_line(detail or ""),
  })
end

local function run_gh(cmd, timeout)
  local result = exec_sync({ cmd = cmd, timeout = timeout or 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    return nil, result
  end
  return result, nil
end

local function sorted_issue_numbers(repo)
  local ok, entities = pcall(core.scan_observe_devloop_entities, {
    all_open_issues = true,
    repo = repo,
    trusted_bot_configured = true,
  })
  if not ok or type(entities) ~= "table" then
    log_skip("github-devloop/stall-watch", "entity-scan-failed", entities)
    return {}
  end
  local seen = {}
  for _, entity in ipairs(entities) do
    local number = tonumber(entity and entity.issue_number)
    if number ~= nil and number >= 1 and number % 1 == 0 and entity and entity.state ~= nil then
      seen[number] = true
    end
  end
  local numbers = {}
  for number, _ in pairs(seen) do
    table.insert(numbers, number)
  end
  table.sort(numbers)
  return numbers
end

local function fetch_issue(repo, issue_number)
  local result, err = run_gh(core.gh_issue_view_state_cmd(repo, issue_number), 30)
  if result == nil then
    log_skip(core.proposal_id(repo, issue_number), "issue-view-failed", err and err.stderr)
    return nil
  end
  local ok, issue = pcall(core.parse_issue_view_state, result.stdout)
  if not ok or type(issue) ~= "table" then
    log_skip(core.proposal_id(repo, issue_number), "issue-view-malformed", issue)
    return nil
  end
  return issue
end

local function fetch_pr(repo, pr_number, proposal_id)
  local result, err = run_gh(core.gh_pr_view_origin_cmd(repo, pr_number), 30)
  if result == nil then
    log_skip(proposal_id, "pr-view-failed", err and err.stderr)
    return nil
  end
  local ok, pr = pcall(core.parse_pr_view_origin, result.stdout)
  if not ok or type(pr) ~= "table" then
    log_skip(proposal_id, "pr-view-malformed", pr)
    return nil
  end
  return pr
end

local function entity_comments(repo, issue, proposal_id)
  local comments = {}
  for _, comment in ipairs(issue.comments or {}) do
    table.insert(comments, comment)
  end
  local link = core.pr_link_fact(issue.comments, proposal_id)
  if link == nil then
    return comments, true
  end
  local pr = fetch_pr(repo, link.pr_number, proposal_id)
  if pr == nil then
    return comments, false
  end
  for _, comment in ipairs(pr.comments or {}) do
    table.insert(comments, comment)
  end
  return comments, true
end

local function source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

local function clear_stalled_label(repo, issue_number, proposal_id, version, ref)
  local request = core.build_stalled_label_clear_request(repo, issue_number, proposal_id, version, ref)
  core.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = { core._stalled_label } }, {
    "github-proxy.github_issue_label_request",
  })
  core.log_raise(dept, proposal_id, "github-proxy.github_issue_label_request", request)
end

local function raise_alert(repo, issue_number, proposal_id, assessment, ref, current_labels)
  local current = assessment.current
  if assessment.action == "alert" then
    local comment = core.build_stall_detected_comment_request(
      repo,
      issue_number,
      proposal_id,
      current.state,
      current.version,
      assessment.threshold_seconds,
      ref
    )
    core.log_line("warn", dept, proposal_id, "STALL_DETECTED", {
      "state=" .. tostring(current.state),
      "version=" .. tostring(current.version),
      "age_seconds=" .. tostring(math.floor(assessment.age_seconds or 0)),
      "threshold_seconds=" .. tostring(assessment.threshold_seconds or ""),
    })
    core.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", comment)
  end
  if not core.has_label(current_labels, core._stalled_label) then
    local label = core.build_stalled_label_request(repo, issue_number, proposal_id, current.state, current.version, ref)
    core.log_apply(dept, proposal_id, nil, nil, { add = { core._stalled_label }, remove = {} }, {
      "github-proxy.github_issue_label_request",
    })
    core.log_raise(dept, proposal_id, "github-proxy.github_issue_label_request", label)
  end
end

local function inspect_issue(repo, issue_number)
  local proposal_id = core.proposal_id(repo, issue_number)
  local issue = fetch_issue(repo, issue_number)
  if issue == nil or issue.state ~= "OPEN" then
    return
  end
  local ref = source_ref(repo, issue_number)
  issue.proposal_id = proposal_id
  local comments, ok = entity_comments(repo, issue, proposal_id)
  if not ok then
    return
  end
  issue.comments = comments
  local assessment = core.stall_watch_assessment(issue)
  if assessment.action == "clear" then
    if core.has_label(issue.labels, core._stalled_label) then
      local version = assessment.current and assessment.current.version or "unmanaged"
      if assessment.reason == "advanced-past-stall" then
        clear_stalled_label(repo, issue_number, proposal_id, version, ref)
      end
    end
    return
  end
  if assessment.action == "alert" or assessment.action == "label-only" then
    raise_alert(repo, issue_number, proposal_id, assessment, ref, issue.labels)
  end
end

function pipeline(event)
  core.log_entry(dept, event, "github-devloop/stall-watch", "tick")
  core.assert_trusted_bot_configured()
  local repo = require_repo()
  local payload = event.payload or {}
  if event.queue == "github-proxy.github_entity_changed" then
    if not core.is_supported_issue(payload) then
      log_skip("github-devloop/stall-watch", "unsupported-entity", "expected issue entity")
      return
    end
    with_lock(core.observe_lock_key(payload.repo, payload.number), function()
      inspect_issue(payload.repo, payload.number)
    end)
    return
  end
  for _, issue_number in ipairs(sorted_issue_numbers(repo)) do
    with_lock(core.observe_lock_key(repo, issue_number), function()
      inspect_issue(repo, issue_number)
    end)
  end
end

return M
