local devloop_base = require("devloop.base")
local check_runs = require("forge.github.check_runs")
local forge_validators = require("devloop.forge_validators")
local strings = require("contract.strings")

local M = {}

local ARTIFACT_NAME = "test-failure-manifest"
local MANIFEST_FILE = "failure-manifest.json"
local SCHEMA = "fkst.test.failure-manifest.v1"
local github = require("devloop.github_factory").production_handle

local function incomparable(reason)
  return { kind = "incomparable", reason = tostring(reason or "failure-manifest-incomparable") }
end

local function is_exact_commit_oid(value)
  return type(value) == "string" and #value == 40 and value:match("^%x+$") ~= nil
end

function M.failure_identity(failure)
  if type(failure) ~= "table" then return nil end
  local fields = {
    failure.owner_namespace,
    failure.file,
    failure.name,
  }
  for _, value in ipairs(fields) do
    if type(value) ~= "string" or value == "" then return nil end
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
    or manifest.schema ~= SCHEMA
    or manifest.complete ~= true
    or type(report_count) ~= "number"
    or report_count < 1
    or report_count % 1 ~= 0
    or manifest.incomplete_reasons ~= nil
    or not is_exact_commit_oid(manifest.tested_commit)
    or type(manifest.failures) ~= "table" then
    return nil
  end
  local failure_count = 0
  for key in pairs(manifest.failures) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil end
    failure_count = failure_count + 1
  end
  local failures = {}
  local seen = {}
  for index = 1, failure_count do
    local failure = manifest.failures[index]
    local identity = M.failure_identity(failure)
    if identity == nil then return nil end
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
    return incomparable("comparison-commit-binding-missing")
  end
  local base_failures = validated_failures(base_manifest)
  local candidate_failures = validated_failures(candidate_manifest)
  if base_failures == nil or candidate_failures == nil then
    return incomparable("failure-manifest-invalid-or-incomplete")
  end
  if not is_exact_commit_oid(candidate_manifest.base_commit)
    or not is_exact_commit_oid(candidate_manifest.head_commit)
    or base_manifest.tested_commit:lower() ~= expected_base
    or tostring(candidate_manifest.event_name or "") ~= "pull_request"
    or candidate_manifest.base_commit:lower() ~= expected_base
    or candidate_manifest.head_commit:lower() ~= expected_head then
    return incomparable("failure-manifest-commit-mismatch")
  end

  local base_set = {}
  for _, failure in ipairs(base_failures) do base_set[failure.identity] = true end
  local new_failures = {}
  for _, failure in ipairs(candidate_failures) do
    if not base_set[failure.identity] then table.insert(new_failures, failure) end
  end
  local result = {
    kind = #new_failures == 0 and "no-new-failing-identity" or "new-failing-identity",
    base_commit = expected_base,
    tested_candidate_commit = tostring(candidate_manifest.tested_commit):lower(),
    new_failures = new_failures,
  }
  return result
end

function M.manifest_cache_key(repo, run_id)
  local id = tostring(run_id or "")
  if id == "" or id:find("[^0-9]") ~= nil then
    error("github-devloop: failure-manifest-run-id-invalid: workflow run id must be numeric")
  end
  return "github-devloop-pr/ci-failure-manifests/"
    .. strings.runtime_safe_segment(repo)
    .. "/run-"
    .. id
end

local function decode_manifest(encoded)
  if type(encoded) ~= "string" or encoded == "" then return nil end
  local ok, decoded = pcall(json.decode, encoded)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function runtime_root()
  local result = exec_sync({ cmd = devloop_base.read_runtime_root_cmd(), timeout = 30 })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then return nil end
  local root = strings.trim(result.stdout)
  if root == "" or root:find("[\r\n]") ~= nil then return nil end
  return root:gsub("/+$", "")
end

local function load_manifest(repo, run_id)
  local cache_key = M.manifest_cache_key(repo, run_id)
  local cached = decode_manifest(cache_get(cache_key))
  if cached ~= nil then return cached, nil end
  return with_lock(cache_key .. "/download", function()
    cached = decode_manifest(cache_get(cache_key))
    if cached ~= nil then return cached, nil end
    local root = runtime_root()
    if root == nil then return nil, "runtime-root-unavailable" end
    local destination = root .. "/ci-failure-manifests/" .. strings.runtime_safe_segment(repo) .. "/run-" .. tostring(run_id)
    local manifest_path = destination .. "/" .. MANIFEST_FILE
    if not file.exists(manifest_path) then
      local mkdir = exec_sync({ cmd = devloop_base.mkdir_p_cmd(destination), timeout = 30 })
      if type(mkdir) ~= "table" or tonumber(mkdir.exit_code) ~= 0 then
        return nil, "artifact-directory-unavailable"
      end
      local download = github().gh_run_download_artifact(repo, run_id, ARTIFACT_NAME, destination, 60)
      if type(download) ~= "table" or tonumber(download.exit_code) ~= 0 then
        return nil, "failure-manifest-artifact-unavailable"
      end
    end
    local ok, encoded = pcall(file.read, manifest_path)
    if not ok then return nil, "failure-manifest-file-unavailable" end
    local manifest = decode_manifest(encoded)
    if manifest == nil then return nil, "failure-manifest-json-invalid" end
    cache_set(cache_key, encoded)
    return manifest, nil
  end)
end

local function parsed_check_runs(result)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil
  end
  local ok, runs = pcall(check_runs.parse_commit_check_runs, result.stdout)
  if not ok or type(runs) ~= "table" then return nil end
  return runs
end

function M.compare_current(repo, current_pr, candidate_runs)
  local head_commit = tostring(type(current_pr) == "table" and current_pr.head_sha or "")
  local base_commit = tostring(type(current_pr) == "table" and current_pr.base_ref_oid or "")
  if not forge_validators.is_git_sha(head_commit) or not forge_validators.is_git_sha(base_commit) then
    return incomparable("current-pr-commit-binding-missing")
  end
  local candidate_run_id, candidate_run_reason = check_runs.required_test_report_run_id(candidate_runs, head_commit)
  if candidate_run_id == nil then return incomparable(candidate_run_reason) end
  local candidate_manifest, candidate_reason = load_manifest(repo, candidate_run_id)
  if candidate_manifest == nil then return incomparable(candidate_reason) end

  local base_runs = parsed_check_runs(github().gh_commit_check_runs(repo, base_commit, 30))
  if base_runs == nil then return incomparable("base-check-runs-unavailable") end
  local base_run_id, base_run_reason = check_runs.required_test_report_run_id(base_runs, base_commit)
  if base_run_id == nil then return incomparable(base_run_reason) end
  local base_manifest, base_reason = load_manifest(repo, base_run_id)
  if base_manifest == nil then return incomparable(base_reason) end
  return M.compare_manifests(base_manifest, candidate_manifest, {
    base_commit = base_commit,
    head_commit = head_commit,
  })
end

return M
