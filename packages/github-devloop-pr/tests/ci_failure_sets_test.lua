local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local fix_rounds = require("core.fix_rounds")

local BASE_SHA = string.rep("a", 40)
local HEAD_SHA = string.rep("b", 40)
local CANDIDATE_SHA = string.rep("c", 40)
local BASE_RUN_ID = "101"
local HEAD_RUN_ID = "202"
local BASE_VERSION = h.reviewing().version

local function failure(name)
  return {
    owner_namespace = "github-devloop-pr",
    file = "tests/example_test.lua",
    name = name,
  }
end

local function own_ci_classification(comparison)
  return {
    kind = "OWN_CI_RED",
    head_sha = HEAD_SHA,
    ci_failure_key = "head:" .. HEAD_SHA .. "/checks:digest-0000000001",
    current_pr = { head_sha = HEAD_SHA, state = "OPEN" },
    failure_set_comparison = comparison,
  }
end

local function admission_context()
  return {
    dept = "fix",
    from_state = "fixing",
    proposal_id = "github-devloop/issue/owner/repo/42",
    review_proposal_id = "consensus:review",
    review_dedup_key = "consensus:review/dedup",
    pr_number = 7,
    source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    reason = "own-ci-red",
  }
end

local function manifest(fields)
  return {
    schema = "fkst.test.failure-set.v1",
    repository = fields.repository or "owner/repo",
    workflow_run_id = fields.workflow_run_id or BASE_RUN_ID,
    workflow_run_attempt = fields.workflow_run_attempt or 1,
    event_name = fields.event_name or "push",
    tested_commit = fields.tested_commit,
    complete = fields.complete ~= false,
    report_count = fields.report_count or 1,
    failures = fields.failures or {},
    base_commit = fields.base_commit,
    head_commit = fields.head_commit,
  }
end

local function compare(base_failures, candidate_failures)
  local ci_failure_sets = require("core.ci_failure_sets")
  return ci_failure_sets.compare_manifests(
    manifest({ tested_commit = BASE_SHA, failures = base_failures }),
    manifest({
      workflow_run_id = HEAD_RUN_ID,
      event_name = "pull_request",
      tested_commit = CANDIDATE_SHA,
      base_commit = BASE_SHA,
      head_commit = HEAD_SHA,
      failures = candidate_failures,
    }),
    {
      repository = "owner/repo",
      base_run_id = BASE_RUN_ID,
      head_run_id = HEAD_RUN_ID,
      base_commit = BASE_SHA,
      head_commit = HEAD_SHA,
    }
  )
end

local function manifest_json(run_id, event_name, tested_commit, base_commit, head_commit)
  local association = ""
  if base_commit ~= nil and head_commit ~= nil then
    association = ',"base_commit":"' .. base_commit .. '","head_commit":"' .. head_commit .. '"'
  end
  return '{"schema":"fkst.test.failure-set.v1","repository":"owner/repo"'
    .. ',"workflow_run_id":"' .. run_id .. '","workflow_run_attempt":1'
    .. ',"event_name":"' .. event_name .. '","tested_commit":"' .. tested_commit .. '"'
    .. ',"complete":true,"report_count":1'
    .. ',"failures":[{"owner_namespace":"github-devloop-pr"'
    .. ',"file":"tests/example_test.lua","name":"test_k"}]'
    .. association .. '}'
end

return {
  test_failure_identity_is_commit_independent = function()
    local ci_failure_sets = require("core.ci_failure_sets")
    local first = failure("test_same_assertion")
    local second = failure("test_same_assertion")
    first.tested_commit = BASE_SHA
    second.tested_commit = CANDIDATE_SHA
    t.eq(ci_failure_sets.failure_identity(first), ci_failure_sets.failure_identity(second))
  end,

  test_equal_failure_sets_are_base_inherited = function()
    local result = compare({ failure("test_k") }, { failure("test_k") })
    t.eq(result.kind, "no-new-failing-identity")
    t.eq(result.base_commit, BASE_SHA)
    t.eq(result.tested_candidate_commit, CANDIDATE_SHA)
  end,

  test_candidate_only_failure_is_diff_caused = function()
    local result = compare({ failure("test_k") }, { failure("test_k_prime") })
    t.eq(result.kind, "new-failing-identity")
    t.eq(#result.new_failures, 1)
  end,

  test_mixed_inherited_and_new_failures_is_diff_caused = function()
    local result = compare({ failure("test_k") }, { failure("test_k"), failure("test_k_prime") })
    t.eq(result.kind, "new-failing-identity")
    t.eq(#result.new_failures, 1)
    t.eq(result.new_failures[1].name, "test_k_prime")
  end,

  test_failure_identity_rejects_non_string_fields = function()
    local malformed = failure("test_k")
    malformed.name = 42
    t.eq(require("core.ci_failure_sets").failure_identity(malformed), nil)
  end,

  test_missing_identity_evidence_is_unknown = function()
    local ci_failure_sets = require("core.ci_failure_sets")
    local result = ci_failure_sets.compare_manifests(nil, nil, {})
    t.eq(result.kind, "UNKNOWN")
  end,

  test_mismatched_candidate_association_is_unknown = function()
    local result = compare({ failure("test_k") }, { failure("test_k") })
    result = require("core.ci_failure_sets").compare_manifests(
      manifest({ tested_commit = BASE_SHA, failures = { failure("test_k") } }),
      manifest({
        event_name = "pull_request",
        tested_commit = CANDIDATE_SHA,
        base_commit = string.rep("d", 40),
        head_commit = HEAD_SHA,
        failures = { failure("test_k") },
      }),
      { base_commit = BASE_SHA, head_commit = HEAD_SHA }
    )
    t.eq(result.kind, "UNKNOWN")
  end,

  test_manifest_workflow_run_association_mismatch_is_unknown = function()
    local result = require("core.ci_failure_sets").compare_manifests(
      manifest({ tested_commit = BASE_SHA, workflow_run_id = "999", failures = { failure("test_k") } }),
      manifest({
        workflow_run_id = HEAD_RUN_ID,
        event_name = "pull_request",
        tested_commit = CANDIDATE_SHA,
        base_commit = BASE_SHA,
        head_commit = HEAD_SHA,
        failures = { failure("test_k") },
      }),
      {
        repository = "owner/repo",
        base_run_id = BASE_RUN_ID,
        head_run_id = HEAD_RUN_ID,
        base_commit = BASE_SHA,
        head_commit = HEAD_SHA,
      }
    )
    t.eq(result.kind, "UNKNOWN")
  end,

  test_compare_current_downloads_and_compares_exact_base_and_head_manifests = function()
    local ci_failure_sets = require("core.ci_failure_sets")
    local downloads = {}
    local downloaded_manifests = {}
    local github_handle = {
      gh_commit_check_runs = function(repo, sha, timeout)
        t.eq(repo, "owner/repo")
        t.eq(sha, BASE_SHA)
        t.eq(timeout, 30)
        return {
          exit_code = 0,
          stderr = "",
          stdout = '{"check_runs":[{"name":"test","status":"completed"'
            .. ',"conclusion":"failure","head_sha":"' .. BASE_SHA .. '"'
            .. ',"details_url":"https://github.com/owner/repo/actions/runs/' .. BASE_RUN_ID .. '"}]}'
        }
      end,
      gh_run_download_artifact = function(repo, run_id, artifact_name, destination, timeout)
        table.insert(downloads, {
          repo = repo,
          run_id = run_id,
          artifact_name = artifact_name,
          destination = destination,
          timeout = timeout,
        })
        local encoded = run_id == BASE_RUN_ID
          and manifest_json(BASE_RUN_ID, "push", BASE_SHA)
          or manifest_json(HEAD_RUN_ID, "pull_request", CANDIDATE_SHA, BASE_SHA, HEAD_SHA)
        downloaded_manifests[destination .. "/failure-set.json"] = encoded
        return { exit_code = 0, stdout = "", stderr = "" }
      end,
    }
    local candidate_runs = {
      {
        name = "test",
        status = "completed",
        conclusion = "failure",
        head_sha = HEAD_SHA,
        details_url = "https://github.com/owner/repo/actions/runs/" .. HEAD_RUN_ID,
      },
    }
    local original_read = file.read
    file.read = function(path)
      local encoded = downloaded_manifests[path]
      if encoded == nil then
        error("unexpected manifest path: " .. tostring(path))
      end
      return encoded
    end
    local ok, result = pcall(ci_failure_sets.compare_current, "owner/repo", {
      number = 7,
      head_sha = HEAD_SHA,
      base_ref_oid = BASE_SHA,
    }, candidate_runs, github_handle)
    file.read = original_read
    if not ok then
      error(result)
    end

    t.eq(result.kind, "no-new-failing-identity")
    t.eq(#downloads, 2)
    t.eq(downloads[1].run_id, BASE_RUN_ID)
    t.eq(downloads[2].run_id, HEAD_RUN_ID)
    for _, download in ipairs(downloads) do
      t.eq(download.repo, "owner/repo")
      t.eq(download.artifact_name, "test-reports")
      t.eq(download.timeout, 30)
    end
  end,

  test_missing_report_count_is_unknown = function()
    local base = manifest({ tested_commit = BASE_SHA, failures = { failure("test_k") } })
    base.report_count = nil
    local result = require("core.ci_failure_sets").compare_manifests(
      base,
      manifest({
        event_name = "pull_request",
        tested_commit = CANDIDATE_SHA,
        base_commit = BASE_SHA,
        head_commit = HEAD_SHA,
        failures = { failure("test_k") },
      }),
      { base_commit = BASE_SHA, head_commit = HEAD_SHA }
    )
    t.eq(result.kind, "UNKNOWN")
  end,

  test_fix_loop_holds_when_producer_failure_is_inherited_from_base = function()
    local comparison = compare({ failure("test_k") }, { failure("test_k") })
    local decision = fix_rounds.admit_own_ci_continuation(
      { state = "fixing", version = BASE_VERSION },
      own_ci_classification(comparison),
      admission_context()
    )
    t.eq(comparison.kind, "no-new-failing-identity")
    t.eq(decision.kind, "hold")
    t.eq(decision.reason, "no-new-failing-identity")
  end,

  test_fix_loop_admits_when_producer_failure_is_new_on_head = function()
    local comparison = compare({}, { failure("test_new") })
    local decision = fix_rounds.admit_own_ci_continuation(
      { state = "fixing", version = BASE_VERSION },
      own_ci_classification(comparison),
      admission_context()
    )
    t.eq(comparison.kind, "new-failing-identity")
    t.eq(decision.kind, "admit")
    t.eq(core.version_fix_round(decision.version), 1)
  end,

}
