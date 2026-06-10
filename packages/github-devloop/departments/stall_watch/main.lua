local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_observe_tick" },
  produces = {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  },
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

local function issue_numbers_from_label(repo, label)
  local result, err = run_gh(core.gh_issue_list_observe_cmd(repo, label), 60)
  if result == nil then
    log_skip("github-devloop/stall-watch", "issue-list-failed", err and err.stderr)
    return {}
  end
  local numbers = {}
  for _, issue in ipairs(core.parse_issue_list_observe(result.stdout)) do
    local number = tonumber(issue.number)
    local state = tostring(issue.state or ""):lower()
    if number ~= nil and number >= 1 and number % 1 == 0 and state == "open" then
      numbers[number] = true
    end
  end
  return numbers
end

local function sorted_issue_numbers(repo)
  local seen = {}
  seen = issue_numbers_from_label(repo, core._stalled_label)
  for state, _ in pairs({
    thinking = true,
    ready = true,
    implementing = true,
    ["pr-open"] = true,
    reviewing = true,
    fixing = true,
    merging = true,
  }) do
    for number, _ in pairs(issue_numbers_from_label(repo, core.state_label(state))) do
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
    local label = core.build_stalled_label_request(repo, issue_number, proposal_id, current.version, ref)
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
  local assessment = core.stall_watch_assessment(issue)
  if assessment.action == "clear" then
    if core.has_label(issue.labels, core._stalled_label) then
      local version = assessment.current and assessment.current.version or "unmanaged"
      clear_stalled_label(repo, issue_number, proposal_id, version, ref)
    end
    return
  end
  if core.has_label(issue.labels, core._stalled_label)
    and assessment.current ~= nil
    and not core.has_stall_detected_marker(
      issue.comments,
      proposal_id,
      assessment.current.state,
      assessment.current.version
    ) then
    clear_stalled_label(repo, issue_number, proposal_id, assessment.current.version, ref)
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
  for _, issue_number in ipairs(sorted_issue_numbers(repo)) do
    with_lock(core.observe_lock_key(repo, issue_number), function()
      inspect_issue(repo, issue_number)
    end)
  end
end

return M
