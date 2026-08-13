local check_runs = require("forge.github.check_runs")
local forge_validators = require("devloop.forge_validators")
local strings = require("contract.strings")

local M = {}

local ARTIFACT_NAME = "test-reports"
local REPORT_SCHEMA = "fkst.test.report.v1"
local FAILURE_SET_SCHEMA = "fkst.test.failure-set.v1"

local function unknown(reason)
  return { kind = "UNKNOWN", reason = tostring(reason or "failure-report-unavailable") }
end

local function is_exact_commit_oid(value)
  return type(value) == "string" and #value == 40 and value:match("^%x+$") ~= nil
end

function M.failure_identity(failure)
  if type(failure) ~= "table" then
    return nil
  end
  local fields = { failure.owner_namespace, failure.file, failure.name }
  for _, value in ipairs(fields) do
    if type(value) ~= "string" or value == "" then
      return nil
    end
  end
  return table.concat({
    tostring(#fields[1]), ":", fields[1],
    tostring(#fields[2]), ":", fields[2],
    tostring(#fields[3]), ":", fields[3],
  })
end

local function validated_failures(manifest)
  local report_count = type(manifest) == "table" and manifest.report_count or nil
  if type(manifest) ~= "table"
    or manifest.schema ~= FAILURE_SET_SCHEMA
    or manifest.complete ~= true
    or type(report_count) ~= "number"
    or report_count < 0
    or report_count % 1 ~= 0
    or manifest.incomplete_reasons ~= nil
    or not is_exact_commit_oid(manifest.tested_commit)
    or type(manifest.failures) ~= "table" then
    return nil
  end

  local failure_count = 0
  for key in pairs(manifest.failures) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil
    end
    failure_count = failure_count + 1
  end

  local failures = {}
  local seen = {}
  for index = 1, failure_count do
    local failure = manifest.failures[index]
    local identity = M.failure_identity(failure)
    if identity == nil then
      return nil
    end
    if not seen[identity] then
      table.insert(failures, {
        identity = identity,
        owner_namespace = failure.owner_namespace,
        file = failure.file,
        name = failure.name,
      })
      seen[identity] = true
    end
  end
  table.sort(failures, function(left, right) return left.identity < right.identity end)
  return failures
end

function M.compare_manifests(base_manifest, candidate_manifest, expected)
  expected = type(expected) == "table" and expected or {}
  local expected_base = type(expected.base_commit) == "string" and expected.base_commit:lower() or ""
  local expected_head = type(expected.head_commit) == "string" and expected.head_commit:lower() or ""
  if not is_exact_commit_oid(expected_base) or not is_exact_commit_oid(expected_head) then
    return unknown("comparison-commit-binding-missing")
  end

  local base_failures = validated_failures(base_manifest)
  local candidate_failures = validated_failures(candidate_manifest)
  if base_failures == nil or candidate_failures == nil then
    return unknown("failure-manifest-invalid-or-incomplete")
  end
  if not is_exact_commit_oid(candidate_manifest.base_commit)
    or not is_exact_commit_oid(candidate_manifest.head_commit)
    or base_manifest.tested_commit:lower() ~= expected_base
    or tostring(candidate_manifest.event_name or "") ~= "pull_request"
    or candidate_manifest.tested_commit:lower() ~= expected_head
    or candidate_manifest.base_commit:lower() ~= expected_base
    or candidate_manifest.head_commit:lower() ~= expected_head then
    return unknown("failure-manifest-commit-mismatch")
  end

  local base_set = {}
  for _, failure in ipairs(base_failures) do
    base_set[failure.identity] = true
  end
  local new_failures = {}
  for _, failure in ipairs(candidate_failures) do
    if not base_set[failure.identity] then
      table.insert(new_failures, failure)
    end
  end
  return {
    kind = #new_failures == 0 and "no-new-failing-identity" or "new-failing-identity",
    base_commit = expected_base,
    tested_candidate_commit = tostring(candidate_manifest.tested_commit):lower(),
    new_failures = new_failures,
  }
end

local function runtime_root()
  local result = exec_sync({ cmd = "printf %s \"$FKST_RUNTIME_ROOT\"", timeout = 30 })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil
  end
  local root = strings.trim(result.stdout)
  if root == "" or root:find("[\r\n]") ~= nil then
    return nil
  end
  return root:gsub("/+$", "")
end

local function report_path(destination, path)
  local prefix = destination .. "/"
  if type(path) ~= "string" or path:sub(1, #prefix) ~= prefix then
    return false
  end
  local relative = path:sub(#prefix + 1)
  return relative ~= ""
    and not relative:find("/", 1, true)
    and relative:sub(-5) == ".json"
end

local function has_report_file(destination)
  local ok, paths = pcall(file.list, destination)
  if not ok or type(paths) ~= "table" then
    return false
  end
  for _, path in ipairs(paths) do
    if report_path(destination, path) then
      return true
    end
  end
  return false
end

local function aggregate_reports(destination, tested_commit, event_name, base_commit, head_commit)
  local ok, paths = pcall(file.list, destination)
  if not ok or type(paths) ~= "table" then
    return nil, "failure-report-files-unavailable"
  end
  local reports = {}
  for _, path in ipairs(paths) do
    if report_path(destination, path) then
      local read_ok, encoded = pcall(file.read, path)
      if not read_ok then
        return nil, "failure-report-file-unavailable"
      end
      local decode_ok, report = pcall(json.decode, encoded)
      if not decode_ok or type(report) ~= "table" then
        return nil, "failure-report-json-invalid"
      end
      local summary = report.summary
      if report.schema ~= REPORT_SCHEMA
        or type(summary) ~= "table"
        or type(summary.passed) ~= "number"
        or type(summary.failed) ~= "number"
        or summary.passed < 0
        or summary.failed < 0
        or summary.passed % 1 ~= 0
        or summary.failed % 1 ~= 0
        or type(report.tests) ~= "table" then
        return nil, "failure-report-invalid"
      end
      local passed = 0
      local failed = 0
      for index, test in ipairs(report.tests) do
        if type(index) ~= "number" or type(test) ~= "table"
          or type(test.owner_namespace) ~= "string" or test.owner_namespace == ""
          or type(test.file) ~= "string" or test.file == ""
          or type(test.name) ~= "string" or test.name == ""
          or (test.status ~= "pass" and test.status ~= "fail") then
          return nil, "failure-report-test-invalid"
        end
        if test.status == "pass" then
          passed = passed + 1
        else
          failed = failed + 1
        end
      end
      if passed ~= summary.passed or failed ~= summary.failed then
        return nil, "failure-report-summary-mismatch"
      end
      table.insert(reports, report)
    end
  end
  if #reports == 0 then
    return nil, "failure-report-missing"
  end
  local failures = {}
  local seen = {}
  for _, report in ipairs(reports) do
    for _, test in ipairs(report.tests) do
      if test.status == "fail" then
        local identity = M.failure_identity(test)
        if identity == nil then
          return nil, "failure-report-identity-missing"
        end
        if not seen[identity] then
          table.insert(failures, {
            identity = identity,
            owner_namespace = test.owner_namespace,
            file = test.file,
            name = test.name,
          })
          seen[identity] = true
        end
      end
    end
  end
  return {
    schema = FAILURE_SET_SCHEMA,
    event_name = event_name,
    tested_commit = tested_commit,
    complete = true,
    report_count = #reports,
    failures = failures,
    base_commit = base_commit,
    head_commit = head_commit,
  }, nil
end

local function read_manifest_from_artifact(github_handle, repo, run_id, tested_commit, event_name, base_commit, head_commit)
  if type(github_handle) ~= "table" then
    return nil, "github-handle-unavailable"
  end
  local root = runtime_root()
  if root == nil then
    return nil, "runtime-root-unavailable"
  end
  local destination = root .. "/ci-test-reports/" .. strings.runtime_safe_segment(repo) .. "/run-" .. tostring(run_id)
  if not has_report_file(destination) then
    local mkdir = exec_sync({ cmd = "mkdir -p '" .. destination:gsub("'", "'\\''") .. "'", timeout = 30 })
    if type(mkdir) ~= "table" or tonumber(mkdir.exit_code) ~= 0 then
      return nil, "artifact-directory-unavailable"
    end
    local download = github_handle.gh_run_download_artifact(repo, run_id, ARTIFACT_NAME, destination, 60)
    if type(download) ~= "table" or tonumber(download.exit_code) ~= 0 then
      return nil, "failure-report-artifact-unavailable"
    end
  end
  return aggregate_reports(destination, tested_commit, event_name, base_commit, head_commit)
end

local function load_manifest(github_handle, repo, run_id, tested_commit, event_name, base_commit, head_commit)
  return read_manifest_from_artifact(
    github_handle, repo, run_id, tested_commit, event_name, base_commit, head_commit
  )
end

local function parsed_check_runs(result)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil
  end
  local ok, runs = pcall(check_runs.parse_commit_check_runs, result.stdout)
  if not ok or type(runs) ~= "table" then
    return nil
  end
  return runs
end

function M.compare_current(repo, current_pr, candidate_runs, github_handle)
  local head_commit = tostring(type(current_pr) == "table" and current_pr.head_sha or "")
  local base_commit = tostring(type(current_pr) == "table" and current_pr.base_ref_oid or "")
  if not forge_validators.is_git_sha(head_commit) or not forge_validators.is_git_sha(base_commit) then
    return unknown("current-pr-commit-binding-missing")
  end
  local candidate_run_id, candidate_run_reason = check_runs.required_test_report_run_id(candidate_runs, head_commit)
  if candidate_run_id == nil then
    return unknown(candidate_run_reason)
  end
  local candidate_manifest, candidate_reason = load_manifest(
    github_handle, repo, candidate_run_id, head_commit, "pull_request", base_commit, head_commit
  )
  if candidate_manifest == nil then
    return unknown(candidate_reason)
  end

  if type(github_handle) ~= "table" then
    return unknown("github-handle-unavailable")
  end
  local base_runs = parsed_check_runs(github_handle.gh_commit_check_runs(repo, base_commit, 30))
  if base_runs == nil then
    return unknown("base-check-runs-unavailable")
  end
  local base_run_id, base_run_reason = check_runs.required_test_report_run_id(base_runs, base_commit)
  if base_run_id == nil then
    return unknown(base_run_reason)
  end
  local base_manifest, base_reason = load_manifest(
    github_handle, repo, base_run_id, base_commit, "push", nil, nil
  )
  if base_manifest == nil then
    return unknown(base_reason)
  end
  return M.compare_manifests(base_manifest, candidate_manifest, {
    base_commit = base_commit,
    head_commit = head_commit,
  })
end

return M
