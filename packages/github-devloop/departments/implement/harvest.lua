local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local config = require("devloop.config")
local payloads_builders = require("devloop.payloads.builders")
local branch_progress = require("departments.implement.branch_progress")
local substrate_pin = require("departments.implement.substrate_pin")
local local_iteration_result = require("departments.implement.local_iteration_result")
local local_iteration_verdict = require("departments.implement.local_iteration_verdict")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local durable_impl_failure = require("devloop.impl_failure")
local workflow_codex = require("workflow_internal.codex")
local sweep_bounds = require("devloop.sweep_bounds")

local exec_sync = exec_sync

local M = {}

-- One recovery follows the initial observation; the second UNKNOWN exhausts fail-closed.
local MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS = 2
-- One checkpoint permits one outer recovery; a second consecutive checkpoint holds for an operator.
local MAX_CONSECUTIVE_INDETERMINATE_CHECKPOINTS = 2
local WORKTREE_MISSING_MARKER = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:MISSING"
local WORKTREE_ENTERED_MARKER = "FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED"

local local_iteration_failure_reasons = {
  CONFIGURATION_FAIL = "local-iteration-configuration-failed",
  TOOLCHAIN_FAIL = "local-iteration-toolchain-failed",
  INFRASTRUCTURE_FAIL = "local-iteration-infrastructure-failed",
}

local base_local_iteration_failure_reasons = {
  BASE_CONFIGURATION_FAIL = "base-local-iteration-configuration-failed",
  BASE_TOOLCHAIN_FAIL = "base-local-iteration-toolchain-failed",
  BASE_INFRASTRUCTURE_FAIL = "base-local-iteration-infrastructure-failed",
}

local function implementation_outcome(ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref)
  return {
    kind = "implementing",
    ready = ready,
    worktree = worktree,
    branch = branch,
    head_sha = head_sha,
    base_branch = base_branch,
    base_sha = base_sha,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    outcome = "completed-after-timeout",
  }
end

local function checkpoint_outcome(ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref, detail, reason)
  local checkpoint_reason = reason or "codex-failed"
  return {
    kind = "implement-checkpoint",
    ready = ready,
    worktree = worktree,
    branch = branch,
    head_sha = head_sha,
    base_branch = base_branch,
    base_sha = base_sha,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    detail = detail,
    reason = checkpoint_reason,
    outcome = "checkpointed: " .. tostring(checkpoint_reason),
  }
end

local function impl_failed_outcome(
    ready, reason, fault_class, retryable, detail, attempt, started_at, exec_ref, base_sha)
  if durable_impl_failure.valid_fault_class(fault_class) == nil then
    error("github-devloop: invalid-fault-class: invalid implementation failure outcome fault class")
  end
  if type(retryable) ~= "boolean" then
    error("github-devloop: invalid-retry-disposition: implementation failure outcome retryable must be boolean")
  end
  return {
    kind = "impl-failed",
    ready = ready,
    reason = reason,
    fault_class = fault_class,
    retryable = retryable,
    detail = detail,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    base_sha = base_sha,
    outcome = "failed: " .. tostring(reason),
  }
end

M.impl_failed_outcome = impl_failed_outcome

function M.bound_verification_checkpoint(outcome, comments)
  if type(outcome) ~= "table"
    or outcome.kind ~= "implement-checkpoint"
    or outcome.reason ~= "verification-indeterminate" then
    return outcome
  end
  local count = m_facts.consecutive_implement_checkpoint_count(
      comments, outcome.ready.proposal_id, outcome.ready.dedup_key, outcome.reason) + 1
  local detail = "consecutive_indeterminate_checkpoints=" .. tostring(count)
    .. "/" .. tostring(MAX_CONSECUTIVE_INDETERMINATE_CHECKPOINTS)
    .. "\n" .. tostring(outcome.detail or "")
  if count < MAX_CONSECUTIVE_INDETERMINATE_CHECKPOINTS then
    outcome.detail = detail
    return outcome
  end
  return impl_failed_outcome(
    outcome.ready, "local-iteration-attribution-indeterminate", "UNKNOWN", false, detail,
    outcome.attempt, outcome.started_at, outcome.exec_ref, outcome.base_sha)
end

local function worktree_unavailable_outcome(ready, worktree, reason, attempt, started_at, exec_ref, base_sha)
  return {
    kind = reason,
    ready = ready,
    worktree = worktree,
    reason = reason,
    terminal = false,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    base_sha = base_sha,
    outcome = "retry: " .. tostring(reason),
  }
end

local function worktree_unavailable_reason(worktree, branch)
  local result = exec_sync({ cmd = devloop_commands.path_is_directory_cmd(worktree), timeout = 30 })
  if result.exit_code ~= 0 and result.exit_code ~= 1 then
    error("github-devloop: worktree-path-check-failed: implementation worktree path check failed: "
      .. tostring(result.stderr))
  end
  if result.exit_code == 1 then
    return "worktree-missing"
  end
  local list = devloop_commands.git_worktree_list(30)
  if list.exit_code ~= 0 then
    error("github-devloop: worktree-list-failed: implementation worktree registration check failed: "
      .. tostring(list.stderr))
  end
  if not devloop_commands.worktree_registered_for_branch(list.stdout, worktree, branch) then
    return "worktree-unregistered"
  end
  return nil
end

function M.worktree_unavailable_outcome(ready, worktree, branch, attempt, started_at, exec_ref, base_sha)
  local reason = worktree_unavailable_reason(worktree, branch)
  if reason == nil then
    return nil
  end
  return worktree_unavailable_outcome(
    ready, worktree, reason, attempt, started_at, exec_ref, base_sha)
end

function M.implementation_refusal_outcome(ready, receipt, attempt, started_at, exec_ref, base_sha)
  return {
    kind = "implementation-refusal",
    ready = ready,
    reason = receipt.reason,
    evidence = receipt.evidence,
    blocker = receipt.blocker,
    receipt = receipt,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    base_sha = base_sha,
    outcome = "refused: " .. tostring(receipt.reason),
  }
end

local function execute_local_iteration_check(worktree, base_head, observe_worktree, exec)
  local quoted_worktree = devloop_base._shell_single_quote(worktree)
  local command = "cd " .. quoted_worktree
  if observe_worktree then
    command = command
      .. " || { if [ ! -d " .. quoted_worktree .. " ]; then printf '%s\\n' "
      .. devloop_base._shell_single_quote(WORKTREE_MISSING_MARKER)
      .. " >&2; fi; exit 1; }\nprintf '%s\\n' "
      .. devloop_base._shell_single_quote(WORKTREE_ENTERED_MARKER)
      .. " >&2\n"
  else
    command = command .. " && "
  end
  if base_head ~= nil then
    command = command .. "export BASE=" .. devloop_base._shell_single_quote(base_head) .. " && "
  end
  command = command .. config.local_iteration_test_command()
  -- The gate verifies the attempt, so it must live inside the attempt's own budget rather than
  -- restate it: a hardcoded gate timeout drifts the moment a deployment raises
  -- FKST_CODEX_TIMEOUT_IMPLEMENT, and then times out on work still within budget, losing the
  -- attempt's real outcome to UNKNOWN (#2887).
  return (exec or exec_sync)({ cmd = command, timeout = workflow_codex.role_timeout_seconds("implement") })
end

function M.local_iteration_check(worktree, base_head, deps)
  if base_head == nil or tostring(base_head) == "" then
    error("github-devloop: local-iteration-base-missing: candidate base head is required")
  end
  return execute_local_iteration_check(worktree, base_head, true, deps and deps.exec or nil)
end

local function worktree_unavailability_from_command(result)
  if type(result) ~= "table" or tonumber(result.exit_code) == 0 then
    return nil
  end
  local missing = false
  local entered = false
  for _, text in ipairs({ result.stdout, result.stderr }) do
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
      if line == WORKTREE_MISSING_MARKER then
        missing = true
      elseif line == WORKTREE_ENTERED_MARKER then
        entered = true
      end
    end
  end
  if missing and not entered then
    return "worktree-missing"
  end
  return nil
end

local function command_detail(result)
  local detail = type(result) == "table" and tostring(result.stderr or "") or ""
  if detail == "" and type(result) == "table" then
    detail = tostring(result.stdout or "")
  end
  return detail
end

local function command_timed_out(result)
  return sweep_bounds.exec_result_timed_out(result)
end

local function clean_probe_worktree(worktree)
  local ok, result = pcall(devloop_commands.git_worktree_force_clean, worktree, 60)
  if not ok then
    return false, tostring(result)
  end
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return false, command_detail(result)
  end
  return true, ""
end

-- Counts non-empty lines; `git ls-files` / `ls-tree` emit one path per line.
local function line_count(stdout)
  local n = 0
  for line in tostring(stdout or ""):gmatch("[^\n]+") do
    if line:gsub("%s+", "") ~= "" then
      n = n + 1
    end
  end
  return n
end

-- Two independent witnesses that the checkout finished. `status --porcelain` catches a tracked file
-- that is present-then-deleted; the census catches the case it cannot see -- a file whose index
-- entry has not been written yet, which reports as clean precisely because git does not yet know
-- the file is expected.
local function probe_tree_is_materialized(git, worktree, base_sha)
  local status = git.status_porcelain(worktree, 30)
  if type(status) ~= "table" or tonumber(status.exit_code) ~= 0 then
    return false, "status-unavailable: " .. command_detail(status)
  end
  local dirty = tostring(status.stdout or ""):gsub("%s+$", "")
  if dirty ~= "" then
    return false, "worktree-dirty: " .. dirty:sub(1, 200)
  end

  local tracked = git.tracked_files(worktree, 60)
  if type(tracked) ~= "table" or tonumber(tracked.exit_code) ~= 0 then
    return false, "tracked-census-unavailable: " .. command_detail(tracked)
  end
  local expected = git.commit_tracked_files(worktree, base_sha, 60)
  if type(expected) ~= "table" or tonumber(expected.exit_code) ~= 0 then
    return false, "commit-census-unavailable: " .. command_detail(expected)
  end

  local have, want = line_count(tracked.stdout), line_count(expected.stdout)
  if have ~= want then
    return false, "tracked-census-mismatch: worktree=" .. tostring(have) .. " commit=" .. tostring(want)
  end
  return true, nil
end

local function run_base_probe(worktree, base_sha)
  local git = require("forge.git").production_handle("github-devloop")
  local plan = git.git_worktree_add_detached_plan(worktree, base_sha)
  local mkdir_result = exec_sync({ cmd = devloop_commands.mkdir_p_cmd(plan.parent_dir), timeout = 30 })
  if type(mkdir_result) ~= "table" or tonumber(mkdir_result.exit_code) ~= 0 then
    return { status = "setup-failed", detail = command_detail(mkdir_result) }
  end

  local add_result = git.git_worktree_add_detached(plan.worktree, plan.sha, 60)
  if type(add_result) ~= "table" or tonumber(add_result.exit_code) ~= 0 then
    return { status = "checkout-failed", detail = command_detail(add_result) }
  end

  local head_result = git.git_head_sha(plan.worktree, 30)
  if type(head_result) ~= "table" or tonumber(head_result.exit_code) ~= 0 then
    return { status = "head-read-failed", detail = command_detail(head_result) }
  end
  local head_readback = tostring(head_result.stdout or ""):gsub("%s+$", "")
  if head_readback ~= base_sha then
    return { status = "head-mismatch", head_readback = head_readback }
  end

  -- A matching HEAD proves the ref, not that the working tree finished materializing. Reading a
  -- half-written tree produced `No such file or directory` for files that are present at that sha,
  -- and `run.sh` reports that as a test failure -- so an unmaterialized tree became a
  -- `retryable="false"` SEMANTIC verdict against a candidate that had verified clean. Gate on the
  -- tree itself before any test verdict can be formed; every status other than `completed` is
  -- routed to INDETERMINATE by `local_iteration_verdict.classify`, which is a retryable setup
  -- outcome and never a verdict about the code.
  local materialized, materialize_detail = probe_tree_is_materialized(git, plan.worktree, base_sha)
  if not materialized then
    return {
      status = "tree-not-materialized",
      head_readback = head_readback,
      detail = materialize_detail,
    }
  end

  -- A raw-base probe has no candidate diff and must not inherit candidate comparison context.
  local check = execute_local_iteration_check(plan.worktree, nil, true)
  local exit_code = type(check) == "table" and tonumber(check.exit_code) or nil
  local result = local_iteration_result.from_command(check)
  if exit_code == nil then
    return {
      status = "command-failed",
      head_readback = head_readback,
      result = result,
      detail = command_detail(check),
    }
  end
  if command_timed_out(check) then
    return {
      status = "timeout",
      exit = exit_code,
      head_readback = head_readback,
      timed_out = true,
      result = result,
      detail = command_detail(check),
    }
  end
  return {
    status = "completed",
    exit = exit_code,
    head_readback = head_readback,
    timed_out = check.timed_out,
    result = result,
    detail = command_detail(check),
  }
end

-- Probe worktree path: a deterministic sibling of the (already deterministic)
-- candidate worktree, tagged by attempt, pre-cleaned before use. The deterministic
-- path is intentional -- a later run's pre-clean reaps any probe worktree a crashed
-- prior run leaked, which a random/unique path would defeat -- and mirrors how the
-- candidate worktree itself is named and reclaimed. The attempt tag keeps distinct
-- attempts from ever sharing a probe path. (If the same attempt were somehow probed
-- concurrently they would share this path; that degrades fail-closed to
-- INDETERMINATE -- a safe re-drive, never a misattribution.)
-- Exported so the materialization gate can be exercised with an injected git handle: it is the
-- whole point of the fix and must be provable without a real half-written checkout.
M.probe_tree_is_materialized = probe_tree_is_materialized

function M.base_local_iteration_probe(candidate_worktree, base_sha, probe_tag)
  local suffix = probe_tag ~= nil and ("-" .. tostring(probe_tag)) or ""
  local probe_worktree = tostring(candidate_worktree) .. "-base-probe" .. suffix
  local observation = { status = "cleanup-failed", base_sha = base_sha, worktree = probe_worktree }
  local preclean_ok, preclean_detail = clean_probe_worktree(probe_worktree)
  if preclean_ok then
    local ok, result = pcall(run_base_probe, probe_worktree, base_sha)
    if ok and type(result) == "table" then
      observation = result
      observation.base_sha = base_sha
      observation.worktree = probe_worktree
    else
      observation = {
        status = "probe-failed",
        base_sha = base_sha,
        worktree = probe_worktree,
        detail = tostring(result),
      }
    end
  else
    observation.detail = preclean_detail
  end

  local cleanup_ok, cleanup_detail = clean_probe_worktree(probe_worktree)
  if not cleanup_ok then
    observation.status = "cleanup-failed"
    observation.detail = cleanup_detail
  end
  return observation
end

local function run_local_iteration_check(ready, worktree, base_head)
  local check = M.local_iteration_check(worktree, base_head)
  local unavailable_reason = worktree_unavailability_from_command(check)
  local result = local_iteration_result.from_command(check)
  devloop_logging.log_line(result.kind == "PASS" and "info" or "warn", "implement", ready.proposal_id, "IMPLEMENT_VERIFY", {
    "exit_code=" .. tostring(check.exit_code),
    "result=" .. tostring(result.kind),
    "result_reason=" .. tostring(result.reason),
    "reason=pre-handoff-local-iteration",
  })
  return result.kind == "PASS", command_detail(check), result, unavailable_reason
end

local function run_candidate_local_iteration_check(ready, worktree, base_head)
  local green, detail, result, unavailable_reason
  for verification_attempt = 1, MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS do
    green, detail, result, unavailable_reason = run_local_iteration_check(ready, worktree, base_head)
    if unavailable_reason ~= nil or result.kind ~= "UNKNOWN" then
      return green, detail, result, verification_attempt, unavailable_reason
    end
  end
  return green, detail, result, MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS, unavailable_reason
end

local function base_probe_detail(probe)
  local fields = {
    "base_sha=" .. tostring(probe and probe.base_sha or ""),
    "probe_status=" .. tostring(probe and probe.status or "missing"),
  }
  if probe and probe.exit ~= nil then
    table.insert(fields, "base_exit=" .. tostring(probe.exit))
  end
  if probe and probe.result ~= nil then
    table.insert(fields, "base_result=" .. tostring(probe.result.kind))
    table.insert(fields, "base_result_reason=" .. tostring(probe.result.reason))
  end
  if probe and probe.verification_attempt ~= nil then
    table.insert(fields, "verification_attempt=" .. tostring(probe.verification_attempt)
      .. "/" .. tostring(MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS))
  end
  if probe and probe.head_readback ~= nil then
    table.insert(fields, "head_readback=" .. tostring(probe.head_readback))
  end
  if probe and tostring(probe.detail or "") ~= "" then
    table.insert(fields, tostring(probe.detail))
  end
  return table.concat(fields, "\n")
end

function M.clean_branch_head(base_head, branch)
  local head_sha = branch_progress.implemented_branch_head(base_head, branch)
  if head_sha == nil or substrate_pin.is_only_pin_delta(base_head, branch) then
    return nil
  end
  return head_sha
end

function M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  local add_result = devloop_commands.git_add_all(worktree, 30)
  if add_result.exit_code ~= 0 then
    error("github-devloop: git-add-failed: git add failed: " .. tostring(add_result.stderr))
  end

  local commit_result = devloop_commands.git_commit(worktree, payloads_builders.implement_commit_subject(
      issue_number,
      require("devloop.github_proxy_entity_view").commit_issue_subject_snapshot(repo, issue_number)
    ), 60)
  if commit_result.exit_code ~= 0 then
    error("github-devloop: git-commit-failed: git commit failed: " .. tostring(commit_result.stderr))
  end

  local branch_result = devloop_commands.git_current_branch(worktree, 30)
  if branch_result.exit_code ~= 0 then
    error("github-devloop: branch-fact-read-failed: git branch fact failed: " .. tostring(branch_result.stderr))
  end
  local actual_branch = tostring(branch_result.stdout or ""):gsub("%s+$", "")
  if actual_branch ~= branch then
    error("github-devloop: branch-mismatch: deterministic implementing branch mismatch")
  end
  if not require("devloop.pr_safety").is_safe_branch(branch) then
    error("github-devloop: unsafe-branch: unsafe implementing branch")
  end

  local head_result = require("forge.git").production_handle("github-devloop").git_head_sha(worktree, 30)
  if head_result.exit_code ~= 0 then
    error("github-devloop: git-head-read-failed: git head fact failed: " .. tostring(head_result.stderr))
  end
  local head_sha = tostring(head_result.stdout or ""):gsub("%s+$", "")
  if not require("devloop.pr_safety").is_safe_head_sha(head_sha) then
    error("github-devloop: unsafe-head-sha: unsafe implementing head_sha")
  end
  return head_sha
end

local function verification_checkpoint_outcome(repo, issue_number, ready, integration_branch, branch,
    base_head, worktree, attempt, started_at, exec_ref, head_sha, detail)
  local checkpoint_head = head_sha or M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  return checkpoint_outcome(ready, worktree, branch, checkpoint_head, integration_branch, base_head,
    attempt, started_at, exec_ref, detail, "verification-indeterminate")
end

function M.after_codex_success(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, head_sha)
  local unavailable = M.worktree_unavailable_outcome(
    ready, worktree, branch, attempt, started_at, exec_ref, base_head)
  if unavailable ~= nil then
    return unavailable
  end
  local green, verify_detail, candidate_result, candidate_verification_attempt, verify_unavailable_reason =
    run_candidate_local_iteration_check(ready, worktree, base_head)
  if verify_unavailable_reason ~= nil then
    return worktree_unavailable_outcome(ready, worktree, verify_unavailable_reason,
      attempt, started_at, exec_ref, base_head)
  end
  if not green then
    local typed_failure_reason = local_iteration_failure_reasons[candidate_result.kind]
    if typed_failure_reason ~= nil then
      return impl_failed_outcome(
        ready, typed_failure_reason, candidate_result.fault_class, false, verify_detail,
        attempt, started_at, exec_ref, base_head)
    end
    if candidate_result.kind == "UNKNOWN" then
      return verification_checkpoint_outcome(repo, issue_number, ready, integration_branch, branch,
        base_head, worktree, attempt, started_at, exec_ref, head_sha,
        "candidate_result=" .. tostring(candidate_result.kind)
          .. "\ncandidate_result_reason=" .. tostring(candidate_result.reason)
          .. "\ncandidate_verification_attempt=" .. tostring(candidate_verification_attempt)
          .. "/" .. tostring(MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS)
          .. "\n" .. tostring(verify_detail))
    end

    local base_probe = nil
    local verdict = "INDETERMINATE"
    for verification_attempt = 1, MAX_LOCAL_ITERATION_VERIFICATION_ATTEMPTS do
      local probe_tag = tostring(attempt) .. "-verification-" .. tostring(verification_attempt)
      base_probe = M.base_local_iteration_probe(worktree, base_head, probe_tag)
      base_probe.verification_attempt = verification_attempt
      verdict = local_iteration_verdict.classify(candidate_result, base_probe)
      devloop_logging.log_line("info", "implement", ready.proposal_id, "IMPLEMENT_VERIFY_BASE", {
        "base_sha=" .. tostring(base_head),
        "base_exit=" .. tostring(base_probe.exit),
        "base_result=" .. tostring(base_probe.result and base_probe.result.kind),
        "base_result_reason=" .. tostring(base_probe.result and base_probe.result.reason),
        "head_readback=" .. tostring(base_probe.head_readback),
        "status=" .. tostring(base_probe.status),
        "verification_attempt=" .. tostring(verification_attempt),
        "verdict=" .. tostring(verdict),
      })
      if verdict ~= "INDETERMINATE" then
        break
      end
    end
    if verdict == "OWN_LOCAL_RED" then
      return impl_failed_outcome(ready, "local-iteration-failed", candidate_result.fault_class, false,
        verify_detail, attempt, started_at, exec_ref, base_head)
    end
    if verdict == "BASE_RED" then
      return impl_failed_outcome(ready, "base-local-iteration-failed", base_probe.result.fault_class, false,
        base_probe_detail(base_probe), attempt, started_at, exec_ref, base_head)
    end
    local typed_base_failure_reason = base_local_iteration_failure_reasons[verdict]
    if typed_base_failure_reason ~= nil then
      return impl_failed_outcome(
        ready, typed_base_failure_reason, base_probe.result.fault_class, false,
        base_probe_detail(base_probe),
        attempt, started_at, exec_ref, base_head)
    end
    if verdict == "INDETERMINATE" then
      return verification_checkpoint_outcome(repo, issue_number, ready, integration_branch, branch,
        base_head, worktree, attempt, started_at, exec_ref, head_sha, base_probe_detail(base_probe))
    end
    return impl_failed_outcome(ready, "local-iteration-attribution-indeterminate", "UNKNOWN", false,
      base_probe_detail(base_probe), attempt, started_at, exec_ref, base_head)
  end
  local verified_head = head_sha or M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  return implementation_outcome(ready, worktree, branch, verified_head, integration_branch, base_head, attempt, started_at, exec_ref)
end

function M.after_codex_failure(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, stderr)
  local unavailable = M.worktree_unavailable_outcome(
    ready, worktree, branch, attempt, started_at, exec_ref, base_head)
  if unavailable ~= nil then
    return unavailable
  end
  local status = devloop_commands.git_status(worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end
  local dirty = tostring(status.stdout or "") ~= ""
  local existing_head = M.clean_branch_head(base_head, branch)
  local progress_head = dirty and M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
    or existing_head
  local green = false
  local verify_detail = ""
  if progress_head ~= nil then
    local ignored_result, verify_unavailable_reason
    green, verify_detail, ignored_result, verify_unavailable_reason =
      run_local_iteration_check(ready, worktree, base_head)
    if verify_unavailable_reason ~= nil then
      return worktree_unavailable_outcome(ready, worktree, verify_unavailable_reason,
        attempt, started_at, exec_ref, base_head)
    end
  end
  if green and progress_head ~= nil then
    return implementation_outcome(ready, worktree, branch, progress_head, integration_branch, base_head, attempt, started_at, exec_ref)
  end
  if progress_head ~= nil then
    return checkpoint_outcome(ready, worktree, branch, progress_head, integration_branch, base_head, attempt, started_at, exec_ref, verify_detail ~= "" and verify_detail or stderr)
  end
  return impl_failed_outcome(
    ready, "codex-failed", "UNKNOWN", true, stderr, attempt, started_at, exec_ref, base_head)
end

return M
