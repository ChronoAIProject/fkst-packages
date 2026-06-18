local S = {}
local registry = require("std.registry")
local strings = require("std.strings")

function S.install(M)
local function is_open_pr(pr)
  return tostring(pr.state or ""):upper() == "OPEN"
end

local function log_check_runs_fallback(M, opts, repo, head_sha, runs, reason)
  if type(M.log_line) ~= "function" then
    return
  end
  M.log_line("info", tostring(opts and opts.dept or "merge"), tostring(opts and opts.proposal_id or "merge-gate"), "CI_FALLBACK", {
    "repo=" .. tostring(repo),
    "head_sha=" .. tostring(head_sha),
    "source=commit-check-runs",
    "required_checks=" .. table.concat(M._required_check_run_names or {}, ","),
    "check_runs=" .. tostring(type(runs) == "table" and #runs or 0),
    "reason=" .. tostring(reason or ""),
  })
end

local function fetch_commit_check_runs(repo, head_sha)
  if tostring(repo or "") == "" or not M.is_safe_head_sha(head_sha) then
    return nil, "ci-unknown"
  end
  local result = M.gh_commit_check_runs(repo, head_sha, 30)
  if result.exit_code ~= 0 then
    return nil, "ci-unknown"
  end
  return M.parse_commit_check_runs(result.stdout), nil
end

local function check_run_id(run)
  local id = type(run) == "table" and (run.id or run.databaseId or run.database_id) or nil
  local text = tostring(id or "")
  if text ~= "" and text:find("[^0-9]") == nil then
    return text
  end
  return nil
end

local function check_run_head_sha(run)
  if type(run) ~= "table" then
    return nil
  end
  for _, value in ipairs({
    run.head_sha,
    run.headSha,
    run.headSHA,
  }) do
    if M.is_safe_head_sha(value) then
      return tostring(value):lower()
    end
  end
  if type(run.check_suite) == "table" then
    for _, value in ipairs({
      run.check_suite.head_sha,
      run.check_suite.headSha,
    }) do
      if M.is_safe_head_sha(value) then
        return tostring(value):lower()
      end
    end
  end
  if type(run.checkSuite) == "table" then
    for _, value in ipairs({
      run.checkSuite.head_sha,
      run.checkSuite.headSha,
    }) do
      if M.is_safe_head_sha(value) then
        return tostring(value):lower()
      end
    end
  end
  return nil
end

local function check_run_name(run)
  if type(run) ~= "table" then
    return ""
  end
  return tostring(run.name or run.context or run.workflowName or run.workflow_name or "")
end

local function check_run_state(run)
  if type(run) ~= "table" then
    return "", ""
  end
  return tostring(run.state or run.status or ""):upper(), tostring(run.conclusion or ""):upper()
end

local green_required_check_conclusions = {
  SUCCESS = true,
  NEUTRAL = true,
  SKIPPED = true,
}

local function required_head_check_run_status(runs, head_sha)
  if type(runs) ~= "table" or not M.is_safe_head_sha(head_sha) then
    return "unknown"
  end
  local required_names = M._required_check_run_names or {}
  local required = {}
  for _, name in ipairs(required_names) do
    required[tostring(name)] = false
  end
  local expected = tostring(head_sha):lower()
  for _, run in ipairs(runs) do
    local name = check_run_name(run)
    if required[name] ~= nil then
      local run_head = check_run_head_sha(run)
      if run_head == nil or run_head == expected then
        required[name] = true
        local state, conclusion = check_run_state(run)
        if state == "COMPLETED" then
          if not green_required_check_conclusions[conclusion] then
            return "red"
          end
        else
          return "pending"
        end
      end
    end
  end
  for _, name in ipairs(required_names) do
    if required[tostring(name)] ~= true then
      return "unknown"
    end
  end
  return "green"
end

local function ci_classification(kind, reason, extra)
  local result = extra or {}
  result.kind = kind
  result.reason = reason
  result.merge_blocking = kind ~= "OK"
  result.actionable = kind == "OWN_CI_RED"
  return result
end

local function integration_or_external_red(pr, head_sha, runs)
  local gate_sha = M.rollup_failure_gate_sha(pr)
  if gate_sha ~= nil and tostring(gate_sha):lower() ~= tostring(head_sha):lower() then
    return ci_classification("INTEGRATION_RED", "integration-ci-red", { check_runs = runs })
  end
  return ci_classification("EXTERNAL_CI_RED", "external-ci-red", { check_runs = runs })
end

local merge_gate_reason_classes = registry.load_indexed_map("core.merge_gate.reason_classes.index", "reason", nil, nil, "github-devloop")

local function merge_gate_reason_row(reason)
  local text = tostring(reason or "")
  if text:find("^rollup%-red:", 1) ~= nil then
    return merge_gate_reason_classes["rollup-red"]
  end
  return merge_gate_reason_classes[text]
end

local function merge_attempt_limit(request)
  local attempts = tonumber(request and request.match_head_retry_attempts or 1) or 1
  attempts = math.floor(attempts)
  if attempts < 1 then
    return 1
  end
  return attempts
end

local function expected_pr_identity(request, repo, head_sha)
  return {
    repo = repo,
    head_sha = head_sha,
    head_branch = request and request.head_branch,
    base_branch = request and request.base_branch,
  }
end

return {
  strings = strings,
  is_open_pr = is_open_pr,
  log_check_runs_fallback = log_check_runs_fallback,
  fetch_commit_check_runs = fetch_commit_check_runs,
  check_run_id = check_run_id,
  check_run_head_sha = check_run_head_sha,
  check_run_name = check_run_name,
  check_run_state = check_run_state,
  green_required_check_conclusions = green_required_check_conclusions,
  required_head_check_run_status = required_head_check_run_status,
  ci_classification = ci_classification,
  integration_or_external_red = integration_or_external_red,
  merge_gate_reason_classes = merge_gate_reason_classes,
  merge_gate_reason_row = merge_gate_reason_row,
  merge_attempt_limit = merge_attempt_limit,
  expected_pr_identity = expected_pr_identity,
}
end

return S
