local base_ids = require("devloop.base_ids")
local check_runs = require("forge.github.check_runs")
local config = require("devloop.config")
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local error_facts = require("contract.error_facts")
local BranchTrain = {}
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")
local forge_validators = require("devloop.forge_validators")
local decimal_checksum = strings.decimal_checksum

local detector = "rollup-health"
local default_red_window_minutes = 30

local function format_timestamp(seconds)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(seconds) or now())
end

local function age_minutes(timestamp, now_seconds)
  local seconds = contract_time.iso_timestamp_epoch_seconds(timestamp)
  if seconds == nil then
    return nil
  end
  local age = (tonumber(now_seconds) or now()) - seconds
  if age < 0 then
    return nil
  end
  return math.floor(age / 60)
end

local function failed_check_timestamp(entry)
  if type(entry) ~= "table" then
    return nil
  end
  return entry.completedAt or entry.completed_at or entry.updatedAt or entry.updated_at or entry.createdAt or entry.created_at
end

local function rollup_red_started_at(pr)
  local entries = type(pr) == "table" and pr.status_check_rollup or nil
  if type(entries) ~= "table" then
    return nil
  end
  local started_at = nil
  for _, entry in ipairs(entries) do
    local single_pr = { status_check_rollup = { entry } }
    local green, reason = check_runs.pr_rollup_green(single_pr)
    if not green and reason == "rollup-red" then
      local timestamp = failed_check_timestamp(entry)
      local seconds = contract_time.iso_timestamp_epoch_seconds(timestamp)
      if seconds ~= nil then
        local current_started_seconds = contract_time.iso_timestamp_epoch_seconds(started_at)
        if current_started_seconds == nil or seconds < current_started_seconds then
          started_at = timestamp
        end
      end
    end
  end
  return started_at
end

local function snapshot_path(repo, pr_number, head_sha)
  local safe_repo = base_ids.safe_repo(repo):gsub("/", "-"):gsub("%-+", "-")
  local safe_head = strings.sanitize_key(tostring(head_sha or "unknown"), false):gsub("[/%s]+", "-")
  safe_head = safe_head:gsub("[^%w%._%-]", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if safe_head == "" then
    safe_head = "unknown"
  end
  if #safe_head > 80 then
    safe_head = safe_head:sub(1, 80):gsub("%-+$", "")
  end
  return "/tmp/fkst-github-devloop-rollup-health-" .. safe_repo .. "-pr-" .. tostring(pr_number) .. "-" .. safe_head .. ".json"
end

local function write_snapshot(repo, evidence)
  local path = snapshot_path(repo, evidence.pr_number, evidence.head_sha)
  file.write(path, "{"
    .. '"detector":' .. strings.json_string(detector)
    .. ',"repo":' .. strings.json_string(repo)
    .. ',"pr_number":' .. tostring(tonumber(evidence.pr_number) or 0)
    .. ',"upstream_branch":' .. strings.json_string(evidence.upstream_branch)
    .. ',"integration_branch":' .. strings.json_string(evidence.integration_branch)
    .. ',"head_sha":' .. strings.json_string(evidence.head_sha)
    .. ',"updated_at":' .. strings.json_string(evidence.updated_at)
    .. ',"red_started_at":' .. strings.json_string(evidence.red_started_at)
    .. ',"age_minutes":' .. tostring(tonumber(evidence.age_minutes) or 0)
    .. ',"threshold_minutes":' .. tostring(tonumber(evidence.threshold_minutes) or 0)
    .. ',"failing_check":' .. strings.json_string(evidence.failing_check)
    .. ',"generated_at":' .. strings.json_string(format_timestamp(evidence.now_seconds))
    .. "}\n")
  return path
end

local function failure_identity(failing_check)
  local identity = tostring(failing_check or "rollup-red")
  identity = identity:gsub(";.*$", "")
  identity = identity:gsub(":.*$", "")
  identity = devloop_base.neutralize_untrusted_comment_text(devloop_base._neutralize_fkst_markers(identity))
  identity = error_facts.one_line(identity):gsub("^%s+", ""):gsub("%s+$", "")
  if identity == "" then
    identity = "rollup-red"
  end
  if #identity > 80 then
    identity = identity:sub(1, 80):gsub("%s+$", "")
  end
  return identity
end

local function require_rollup_head_sha(value)
  if not forge_validators.is_git_sha(value) then
    error("github-devloop: rollup-health-head-sha-invalid: rollup head SHA is missing or invalid")
  end
  return tostring(value):lower()
end

function BranchTrain.install_rollup_health(M)
  function M.rollup_red_window_minutes(exec)
    local raw = devloop_base.read_env("FKST_DEVLOOP_ROLLUP_RED_WINDOW_MINUTES", exec)
    if raw == nil or strings.trim(raw) == "" then
      return default_red_window_minutes
    end
    local value = tonumber(strings.trim(raw))
    if value == nil or value ~= math.floor(value) or value < 1 or value > 1440 then
      error("github-devloop: config-invalid: invalid FKST_DEVLOOP_ROLLUP_RED_WINDOW_MINUTES")
    end
    return value
  end

  function M.rollup_health_dedup_key(repo, failing_check, head_sha)
    return base_ids.dedup_key({
      detector,
      tostring(repo or ""),
      failure_identity(failing_check),
      require_rollup_head_sha(head_sha),
    })
  end

  local function alert_title(evidence)
    return "Rollup health: integration->dev is red on " .. failure_identity(evidence.failing_check)
  end

  local function alert_body(evidence, snapshot)
    local lines = {
      "Rollup health watchdog fired from deterministic CI status signals.",
      "",
      "Detector: `" .. detector .. "`",
      "Rollup PR: #" .. tostring(evidence.pr_number),
      "Branches: `" .. tostring(evidence.integration_branch) .. "` -> `" .. tostring(evidence.upstream_branch) .. "`",
      "Head: `" .. tostring(evidence.head_sha) .. "`",
      "Failing check: `" .. tostring(evidence.failing_check) .. "`",
      "Red age: " .. tostring(evidence.age_minutes) .. " minutes",
      "Threshold: " .. tostring(evidence.threshold_minutes) .. " minutes",
      "Evidence snapshot: `" .. tostring(snapshot) .. "`",
      "",
      "Requested outcome:",
      "- Diagnose why the rollup PR is red and blocking integration delivery.",
      "- File any fix through the normal intake, consensus, implementation, and review pipeline.",
      "- This watchdog must not repair, merge, relabel, or mutate runtime state directly.",
    }
    local body = table.concat(lines, "\n")
    if #body > M._max_body_len then
      body = base_ids.truncate_utf8(body, M._max_body_len)
    end
    return body
  end

  function M.build_rollup_health_issue_create_request(repo, evidence, snapshot)
    return {
      schema = "github-proxy.issue-create.v1",
      repo = repo,
      title = alert_title(evidence),
      body = alert_body(evidence, snapshot),
      -- When rollup auto-fix is on, the watchdog issue is born as an enabled,
      -- expedite work-item so the loop claims + fixes the red rollup ahead of new
      -- issues. Default off ⇒ no labels (passive watchdog, today's behavior).
      labels = evidence.rollup_autofix
        and json.decode('["fkst-dev:enabled","fkst-class:expedite"]')
        or json.decode("[]"),
      dedup_key = M.rollup_health_dedup_key(repo, evidence.failing_check, evidence.head_sha),
      parent_comment_target = {
        repo = repo,
        issue_number = tostring(evidence.pr_number),
      },
      source_ref = {
        kind = "external",
        ref = tostring(repo or "") .. "#" .. detector .. "/pr/" .. tostring(evidence.pr_number),
      },
    }
  end

  function M.observe_rollup_health(repo, upstream, integration, pr, now_seconds, threshold_minutes)
    local current_seconds = tonumber(now_seconds) or now()
    local threshold = tonumber(threshold_minutes) or M.rollup_red_window_minutes()
    local green, reason = check_runs.pr_rollup_green(pr)
    if green then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=no-op reason=rollup-green")
      return { action = "no-op", reason = "rollup-green" }
    end
    if reason ~= "rollup-red" then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=no-op reason=" .. tostring(reason))
      return { action = "no-op", reason = reason }
    end

    local head_sha = require_rollup_head_sha(pr and pr.head_sha)
    local failing_head_sha = parsers_misc.rollup_failure_gate_sha(pr)
    if failing_head_sha == nil then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=no-op"
        .. " reason=red-check-head-unknown"
        .. " rollup_head=" .. head_sha)
      return { action = "no-op", reason = "red-check-head-unknown" }
    end
    local check_head_sha = tostring(failing_head_sha):lower()
    if check_head_sha ~= head_sha then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=no-op"
        .. " reason=stale-red-check-head"
        .. " rollup_head=" .. head_sha
        .. " check_head=" .. check_head_sha)
      return { action = "no-op", reason = "stale-red-check-head" }
    end

    local red_started_at = rollup_red_started_at(pr)
    local age = age_minutes(red_started_at, current_seconds)
    if age == nil then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=no-op reason=age-unknown")
      return { action = "no-op", reason = "age-unknown" }
    end
    if age < threshold then
      log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH action=suppress"
        .. " reason=red-window"
        .. " age_minutes=" .. tostring(age)
        .. " threshold_minutes=" .. tostring(threshold))
      return { action = "suppress", reason = "red-window", age_minutes = age }
    end

    local failing_check = parsers_misc.pr_rollup_failure_summary(pr)
    if failing_check == "" then
      failing_check = "rollup-red"
    end
    local evidence = {
      now_seconds = current_seconds,
      repo = repo,
      pr_number = pr and pr.number,
      upstream_branch = upstream,
      integration_branch = integration,
      head_sha = head_sha,
      updated_at = pr and pr.updated_at,
      red_started_at = red_started_at,
      age_minutes = age,
      threshold_minutes = threshold,
      failing_check = failing_check,
      rollup_autofix = config.rollup_autofix_enabled(),
    }
    local snapshot = write_snapshot(repo, evidence)
    local request = M.build_rollup_health_issue_create_request(repo, evidence, snapshot)
    devloop_logging.log_raise("rollup_scan", detector .. "/" .. tostring(pr and pr.number or "unknown"), "github-proxy.github_issue_create_request", request)
    log.info("github-devloop dept=rollup_scan tag=ROLLUP_HEALTH"
      .. " action=raise"
      .. " pr=" .. tostring(pr and pr.number or "")
      .. " head_sha=" .. tostring(pr and pr.head_sha or "")
      .. " age_minutes=" .. tostring(age)
      .. " threshold_minutes=" .. tostring(threshold)
      .. " failing_check=" .. error_facts.one_line(failing_check)
      .. " snapshot_path=" .. tostring(snapshot)
      .. " dedup_key=" .. tostring(request.dedup_key))
    return {
      action = "raise",
      request = request,
      snapshot_path = snapshot,
    }
  end
end

function BranchTrain.install(M, shared, bounded_lock_key)
  local require_safe_branch = shared.require_safe_branch
  local require_safe_sha = shared.require_safe_sha
  local require_safe_repo = shared.require_safe_repo
  local require_sync_result = shared.require_sync_result
  local runtime_root_path = shared.runtime_root_path

  function M.branch_sync_lock_key(repo, upstream, integration)
    return bounded_lock_key("github-devloop/branch-sync", repo, {
      { name = "upstream branch", value = upstream },
      { name = "integration branch", value = integration },
    })
  end

  function M.rollup_lock_key(repo, upstream, integration)
    return bounded_lock_key("github-devloop/rollup", repo, {
      { name = "upstream branch", value = upstream },
      { name = "integration branch", value = integration },
    })
  end

  function M.rollup_source_ref(repo, pr_number)
    return {
      kind = "external",
      ref = require_safe_repo(repo) .. "#pr/" .. tostring(pr_number),
    }
  end

  function M.rollup_dedup_key(repo, upstream, integration, pr_number, head_sha)
    return base_ids.dedup_key({
      "rollup",
      require_safe_repo(repo),
      require_safe_branch("upstream branch", upstream),
      require_safe_branch("integration branch", integration),
      tostring(pr_number),
      require_safe_sha("head sha", head_sha),
    })
  end

  function M.rollup_ready_payload(repo, upstream, integration, pr_number, head_sha)
    return {
      schema = "github-devloop.v1",
      repo = require_safe_repo(repo),
      pr_number = pr_number,
      upstream_branch = require_safe_branch("upstream branch", upstream),
      integration_branch = require_safe_branch("integration branch", integration),
      head_sha = require_safe_sha("head sha", head_sha),
      dedup_key = M.rollup_dedup_key(repo, upstream, integration, pr_number, head_sha),
      source_ref = M.rollup_source_ref(repo, pr_number),
    }
  end

  function M.validate_rollup_ready(payload)
    if type(payload) ~= "table" then
      return false, "payload-not-table"
    end
    if payload.schema ~= "github-devloop.v1" then
      return false, "schema"
    end
    if not forge_validators.is_git_ref_safe(payload.upstream_branch) then
      return false, "upstream-branch"
    end
    if not forge_validators.is_git_ref_safe(payload.integration_branch) then
      return false, "integration-branch"
    end
    if not forge_validators.is_git_sha(payload.head_sha) then
      return false, "head-sha"
    end
    if type(payload.source_ref) ~= "table" then
      return false, "source-ref"
    end
    if payload.source_ref.kind ~= "external" then
      return false, "source-ref-kind"
    end
    local repo_ok, repo_err = pcall(function()
      require_safe_repo(payload.repo)
    end)
    if not repo_ok then
      return false, "repo-validation: " .. tostring(repo_err)
    end
    if tostring(payload.source_ref.ref or "") ~= M.rollup_source_ref(payload.repo, payload.pr_number).ref then
      return false, "source-ref-ref"
    end
    if tostring(payload.dedup_key or "") ~= M.rollup_dedup_key(
      payload.repo,
      payload.upstream_branch,
      payload.integration_branch,
      payload.pr_number,
      payload.head_sha
    ) then
      return false, "dedup-key"
    end
    return true, "ok"
  end

  function M.branch_sync_source_ref(repo, upstream, integration)
    return {
      kind = "external",
      ref = require_safe_repo(repo)
        .. "#branch-sync/"
        .. require_safe_branch("upstream branch", upstream)
        .. "/"
        .. require_safe_branch("integration branch", integration),
    }
  end

  function M.branch_sync_dedup_key(repo, upstream, integration, upstream_sha)
    return base_ids.dedup_key({
      "branch-sync",
      require_safe_repo(repo),
      require_safe_branch("upstream branch", upstream),
      require_safe_branch("integration branch", integration),
      require_safe_sha("upstream sha", upstream_sha),
    })
  end

  function M.sync_commit_marker(repo, upstream, integration, upstream_sha, integration_parent, result)
    return '<!-- fkst:github-devloop:sync:v1 repo="' .. require_safe_repo(repo)
      .. '" upstream="' .. require_safe_branch("upstream branch", upstream)
      .. '" integration="' .. require_safe_branch("integration branch", integration)
      .. '" upstream_sha="' .. require_safe_sha("upstream sha", upstream_sha)
      .. '" integration_parent="' .. require_safe_sha("integration parent", integration_parent)
      .. '" result="' .. require_sync_result(result)
      .. '" -->'
  end

  function M.sync_commit_message(repo, upstream, integration, upstream_sha, integration_parent, result)
    return "Sync " .. require_safe_branch("upstream branch", upstream)
      .. " into " .. require_safe_branch("integration branch", integration)
      .. "\n\n"
      .. M.sync_commit_marker(repo, upstream, integration, upstream_sha, integration_parent, result)
  end

  function M.branch_sync_worktree_path(runtime_root, repo, upstream, integration, integration_sha)
    local slug = strings.sanitize_key(
      require_safe_repo(repo)
        .. "-"
        .. require_safe_branch("upstream branch", upstream)
        .. "-"
        .. require_safe_branch("integration branch", integration),
      false
    ):gsub("/", "-")
    slug = slug:gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then
      slug = "branch-sync"
    end
    if #slug > 90 then
      slug = slug:sub(1, 90):gsub("%-+$", "")
    end
    local suffix = decimal_checksum(
      require_safe_repo(repo)
        .. "#"
        .. require_safe_branch("upstream branch", upstream)
        .. "#"
        .. require_safe_branch("integration branch", integration)
        .. "#"
        .. require_safe_sha("integration sha", integration_sha)
    )
    return runtime_root_path(runtime_root) .. "/worktrees/sync-" .. slug .. "-" .. suffix
  end

  function M.branch_sync_message_file(runtime_root, repo, upstream, integration, upstream_sha, integration_sha)
    local suffix = decimal_checksum(
      require_safe_repo(repo)
        .. "#"
        .. require_safe_branch("upstream branch", upstream)
        .. "#"
        .. require_safe_branch("integration branch", integration)
        .. "#"
        .. require_safe_sha("upstream sha", upstream_sha)
        .. "#"
        .. require_safe_sha("integration sha", integration_sha)
    )
    runtime_root_path(runtime_root)
    return "/tmp/fkst-github-devloop-sync-message-" .. suffix .. ".txt"
  end

  function M.is_supported_sync_conflict(payload)
    if type(payload) ~= "table"
      or payload.schema ~= "github-devloop.v1"
      or not forge_validators.is_git_ref_safe(payload.upstream_branch)
      or not forge_validators.is_git_ref_safe(payload.integration_branch)
      or not forge_validators.is_git_sha(payload.upstream_sha)
      or not forge_validators.is_git_sha(payload.integration_sha)
      or type(payload.source_ref) ~= "table"
      or payload.source_ref.kind ~= "external" then
      return false
    end

    local ok = pcall(function()
      require_safe_repo(payload.repo)
    end)
    if not ok then
      return false
    end

    local expected_ref = M.branch_sync_source_ref(payload.repo, payload.upstream_branch, payload.integration_branch)
    local expected_branch_sync = tostring(payload.source_ref.ref or "") == expected_ref.ref
      and tostring(payload.dedup_key or "") == M.branch_sync_dedup_key(
      payload.repo,
      payload.upstream_branch,
      payload.integration_branch,
      payload.upstream_sha
    )
    if expected_branch_sync then
      return true
    end

    local expected_pr_freshness = tostring(payload.source_ref.ref or ""):match("^" .. require_safe_repo(payload.repo):gsub("([^%w])", "%%%1") .. "#pr/%d+$") ~= nil
      and tostring(payload.dedup_key or "") == M.pr_freshness_dedup_key(
        payload.repo,
        payload.integration_branch,
        payload.upstream_sha
      )
    return expected_pr_freshness
  end
end

return BranchTrain
