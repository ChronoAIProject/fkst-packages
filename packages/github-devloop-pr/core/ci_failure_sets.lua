local check_runs = require("forge.github.check_runs")
local forge_validators = require("devloop.forge_validators")

local M = {}

local FAILURE_SET_SCHEMA = "fkst.test.failure-set.v1"

local function unknown(reason)
  return { kind = "UNKNOWN", reason = tostring(reason or "failure-report-unavailable") }
end

local function is_exact_commit_oid(value)
  return type(value) == "string" and #value == 40 and value:match("^%x+$") ~= nil
end

local function is_numeric_id(value)
  return type(value) == "string" and value ~= "" and value:match("^%d+$") ~= nil
end

local function is_repository(value)
  return type(value) == "string" and value:match("^[^/%s]+/[^/%s]+$") ~= nil
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

local function validated_failures(manifest, expected_repository, expected_run_id)
  local report_count = type(manifest) == "table" and manifest.report_count or nil
  if type(manifest) ~= "table"
    or manifest.schema ~= FAILURE_SET_SCHEMA
    or manifest.complete ~= true
    or type(report_count) ~= "number"
    or report_count < 0
    or report_count % 1 ~= 0
    or manifest.incomplete_reasons ~= nil
    or not is_repository(manifest.repository)
    or not is_numeric_id(manifest.workflow_run_id)
    or type(manifest.workflow_run_attempt) ~= "number"
    or manifest.workflow_run_attempt < 1
    or manifest.workflow_run_attempt % 1 ~= 0
    or (manifest.event_name ~= "push" and manifest.event_name ~= "pull_request")
    or not is_exact_commit_oid(manifest.tested_commit)
    or type(manifest.failures) ~= "table" then
    return nil, "failure-manifest-invalid-or-incomplete"
  end
  if manifest.repository:lower() ~= expected_repository:lower()
    or manifest.workflow_run_id ~= expected_run_id then
    return nil, "failure-manifest-run-association-mismatch"
  end

  local failure_count = 0
  for key in pairs(manifest.failures) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil, "failure-manifest-invalid-or-incomplete"
    end
    failure_count = failure_count + 1
  end

  local failures = {}
  local seen = {}
  for index = 1, failure_count do
    local failure = manifest.failures[index]
    local identity = M.failure_identity(failure)
    if identity == nil then
      return nil, "failure-manifest-invalid-or-incomplete"
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
  return failures, nil
end

function M.compare_manifests(base_manifest, candidate_manifest, expected)
  expected = type(expected) == "table" and expected or {}
  local expected_base = type(expected.base_commit) == "string" and expected.base_commit:lower() or ""
  local expected_head = type(expected.head_commit) == "string" and expected.head_commit:lower() or ""
  local expected_repository = expected.repository
  local expected_base_run = expected.base_run_id
  local expected_head_run = expected.head_run_id
  if not is_exact_commit_oid(expected_base) or not is_exact_commit_oid(expected_head) then
    return unknown("comparison-commit-binding-missing")
  end
  if not is_repository(expected_repository)
    or not is_numeric_id(expected_base_run)
    or not is_numeric_id(expected_head_run) then
    return unknown("comparison-run-binding-missing")
  end

  local base_failures, base_reason = validated_failures(base_manifest, expected_repository, expected_base_run)
  local candidate_failures, candidate_reason = validated_failures(candidate_manifest, expected_repository, expected_head_run)
  if base_failures == nil or candidate_failures == nil then
    return unknown(base_reason or candidate_reason)
  end
  if not is_exact_commit_oid(candidate_manifest.base_commit)
    or not is_exact_commit_oid(candidate_manifest.head_commit)
    or base_manifest.tested_commit:lower() ~= expected_base
    or tostring(candidate_manifest.event_name or "") ~= "pull_request"
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

local function download_manifest(repo, run_id, destination, github_handle)
  local ok, result = pcall(
    github_handle.gh_run_download_artifact,
    repo,
    run_id,
    "test-reports",
    destination,
    30
  )
  if not ok or type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil, "failure-manifest-download-failed"
  end
  local read_ok, encoded = pcall(file.read, destination .. "/failure-set.json")
  if not read_ok then
    return nil, "failure-manifest-read-failed"
  end
  local decode_ok, manifest = pcall(json.decode, encoded)
  if not decode_ok or type(manifest) ~= "table" then
    return nil, "failure-manifest-json-invalid"
  end
  return manifest, nil
end

function M.compare_current(repo, current_pr, candidate_runs, github_handle)
  local head_commit = tostring(type(current_pr) == "table" and current_pr.head_sha or "")
  local base_commit = tostring(type(current_pr) == "table" and current_pr.base_ref_oid or "")
  if not is_exact_commit_oid(head_commit) or not is_exact_commit_oid(base_commit) then
    return unknown("current-pr-commit-binding-missing")
  end
  if not is_repository(repo) or not forge_validators.is_positive_pr_number(current_pr.number) then
    return unknown("current-pr-identity-missing")
  end
  if type(github_handle) ~= "table"
    or type(github_handle.gh_commit_check_runs) ~= "function"
    or type(github_handle.gh_run_download_artifact) ~= "function"
    or type(file) ~= "table"
    or type(file.read) ~= "function"
    or type(json) ~= "table"
    or type(json.decode) ~= "function"
    or type(now) ~= "function" then
    return unknown("github-handle-unavailable")
  end
  local head_run_id, head_run_reason = check_runs.required_test_report_run_id(candidate_runs, head_commit)
  if head_run_id == nil then
    return unknown(head_run_reason)
  end
  local ok, base_result = pcall(github_handle.gh_commit_check_runs, repo, base_commit, 30)
  if not ok then
    return unknown("base-check-runs-unavailable")
  end
  local base_runs = parsed_check_runs(base_result)
  if base_runs == nil then
    return unknown("base-check-runs-unavailable")
  end
  local base_run_id, base_run_reason = check_runs.required_test_report_run_id(base_runs, base_commit)
  if base_run_id == nil then
    return unknown(base_run_reason)
  end

  local artifact_root = "/tmp/fkst-ci-failure-set-"
    .. tostring(current_pr.number) .. "-" .. base_run_id .. "-" .. head_run_id .. "-" .. tostring(now())
  local base_manifest, base_manifest_reason = download_manifest(
    repo,
    base_run_id,
    artifact_root .. "/base",
    github_handle
  )
  if base_manifest == nil then
    return unknown(base_manifest_reason)
  end
  local head_manifest, head_manifest_reason = download_manifest(
    repo,
    head_run_id,
    artifact_root .. "/head",
    github_handle
  )
  if head_manifest == nil then
    return unknown(head_manifest_reason)
  end
  return M.compare_manifests(base_manifest, head_manifest, {
    repository = repo,
    base_run_id = base_run_id,
    head_run_id = head_run_id,
    base_commit = base_commit,
    head_commit = head_commit,
  })
end

return M
