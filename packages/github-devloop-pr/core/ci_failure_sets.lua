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

function M.compare_check_runs(base_runs, candidate_runs, expected)
  return check_runs.compare_failure_sets(base_runs, candidate_runs, expected)
end

function M.compare_current(repo, current_pr, candidate_runs, github_handle)
  local head_commit = tostring(type(current_pr) == "table" and current_pr.head_sha or "")
  local base_commit = tostring(type(current_pr) == "table" and current_pr.base_ref_oid or "")
  if not forge_validators.is_git_sha(head_commit) or not forge_validators.is_git_sha(base_commit) then
    return unknown("current-pr-commit-binding-missing")
  end
  if type(github_handle) ~= "table" then
    return unknown("github-handle-unavailable")
  end
  local candidate_probe = M.compare_check_runs({}, candidate_runs, {
    base_commit = base_commit,
    head_commit = head_commit,
  })
  if candidate_probe.kind == "UNKNOWN" then
    return candidate_probe
  end
  local ok, base_result = pcall(github_handle.gh_commit_check_runs, repo, base_commit, 30)
  if not ok then
    return unknown("base-check-runs-unavailable")
  end
  local base_runs = parsed_check_runs(base_result)
  if base_runs == nil then
    return unknown("base-check-runs-unavailable")
  end
  return M.compare_check_runs(base_runs, candidate_runs, {
    base_commit = base_commit,
    head_commit = head_commit,
  })
end

return M
