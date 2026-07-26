local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local config = require("devloop.config")
local payloads_builders = require("devloop.payloads.builders")
local branch_progress = require("departments.implement.branch_progress")
local substrate_pin = require("departments.implement.substrate_pin")
local local_iteration_verdict = require("departments.implement.local_iteration_verdict")
local devloop_logging = require("devloop.logging")

local exec_sync = exec_sync

local M = {}

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

local function checkpoint_outcome(ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref, detail)
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
    outcome = "checkpointed: codex-failed",
  }
end

local function impl_failed_outcome(ready, reason, detail, attempt, started_at, exec_ref, base_sha)
  return {
    kind = "impl-failed",
    ready = ready,
    reason = reason,
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

-- base_head (optional): the candidate worktree's frozen fork-point sha. When
-- present it is pinned as BASE for the local-iteration command so `make preflight`
-- (admission/echo-verify) compares the candidate against ITS OWN base instead of
-- the moving origin/dev default. Without this pin, once origin/dev advances past
-- the frozen base_sha the worktree forks from, admission's
-- `merge-base --is-ancestor <BASE> <candidate HEAD>` no longer holds (origin/dev
-- stops being an ancestor of the frozen base) and the whole check reds out with an
-- infrastructure error ("protected base is not an ancestor of candidate HEAD")
-- unrelated to the candidate diff -> make exit 2 -> base-local-iteration-failed.
-- Pinning BASE=base_head keeps base_head an ancestor of candidate HEAD (it is the
-- fork point) and the diff non-vacuous, so the check stays fully meaningful (real
-- build/verify + admission) but stops wedging on origin/dev drift. Threaded as an
-- environment assignment (not a positional/make argument) so a non-make local test
-- command ignores it harmlessly; the trureturing Makefile consumes it via
-- `BASE ?= origin/dev` and preflight's `${BASE:-origin/dev}` (both env-driven).
-- When base_head is nil/empty the command is byte-for-byte unchanged
-- (base-independent) -- the base probe deliberately relies on that.
function M.local_iteration_check(worktree, base_head)
  local invocation = config.local_iteration_test_command()
  if base_head ~= nil and tostring(base_head) ~= "" then
    invocation = "BASE=" .. devloop_base._shell_single_quote(base_head) .. " " .. invocation
  end
  local command = "cd " .. devloop_base._shell_single_quote(worktree) .. " && " .. invocation
  return exec_sync({ cmd = command, timeout = 7200 })
end

-- Base-health check for the base-probe: runs config.base_health_command (a
-- base-INDEPENDENT engineering command: build + test + selftest) against a worktree
-- whose HEAD IS base_sha, measuring only whether the base tree itself is healthy.
-- Unlike M.local_iteration_check it does NOT run the candidate's local-iteration
-- command (`make preflight`, whose trailing admission gate is base-relative and reds
-- out on origin/dev drift) and it never threads a BASE pin (the probe worktree HEAD
-- already IS base_sha; a self-pin would be a vacuous no-op diff). A healthy base
-- exits 0 (verdict -> OWN_LOCAL_RED, impl-fail the genuinely broken candidate); a
-- genuinely broken base (compile error / failing test / selftest regression) exits
-- non-zero (verdict -> BASE_RED, retry).
function M.base_health_check(worktree)
  local invocation = config.base_health_command()
  local command = "cd " .. devloop_base._shell_single_quote(worktree) .. " && " .. invocation
  return exec_sync({ cmd = command, timeout = 7200 })
end

local function command_detail(result)
  local detail = type(result) == "table" and tostring(result.stderr or "") or ""
  if detail == "" and type(result) == "table" then
    detail = tostring(result.stdout or "")
  end
  return detail
end

local function command_timed_out(result)
  if type(result) ~= "table" then
    return false
  end
  if result.timed_out ~= nil then
    return result.timed_out == true
  end
  return tonumber(result.exit_code) == 124
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

  -- Base-INDEPENDENT base-health probe (see M.base_health_check): measures whether
  -- base_sha itself builds/tests/selftests, NOT the candidate's local-iteration
  -- command. The candidate command is `make preflight`, whose trailing admission gate
  -- is base-relative: on a worktree whose HEAD IS the frozen base_sha it reds out with
  -- an infrastructure error once origin/dev advances past base_sha (origin/dev stops
  -- being an ancestor), which the verdict would misread as BASE_RED and loop a
  -- genuinely broken candidate forever. The base-health command drops that gate, so a
  -- healthy base is green (-> OWN_LOCAL_RED, impl-fail) while a genuinely broken base
  -- still reds (-> BASE_RED, retry). No BASE pin is threaded (the probe worktree HEAD
  -- already IS base_sha; a self-pin would be a vacuous no-op diff).
  local check = M.base_health_check(plan.worktree)
  local exit_code = type(check) == "table" and tonumber(check.exit_code) or nil
  if exit_code == nil then
    return { status = "command-failed", head_readback = head_readback, detail = command_detail(check) }
  end
  if command_timed_out(check) then
    return {
      status = "timeout",
      exit = exit_code,
      head_readback = head_readback,
      timed_out = true,
      detail = command_detail(check),
    }
  end
  return {
    status = "completed",
    exit = exit_code,
    head_readback = head_readback,
    timed_out = check.timed_out,
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
  devloop_logging.log_line(check.exit_code == 0 and "info" or "warn", "implement", ready.proposal_id, "IMPLEMENT_VERIFY", {
    "exit_code=" .. tostring(check.exit_code),
    "reason=pre-handoff-local-iteration",
  })
  return check.exit_code == 0, command_detail(check), check
end

local function base_probe_detail(probe)
  local fields = {
    "base_sha=" .. tostring(probe and probe.base_sha or ""),
    "probe_status=" .. tostring(probe and probe.status or "missing"),
  }
  if probe and probe.exit ~= nil then
    table.insert(fields, "base_exit=" .. tostring(probe.exit))
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

function M.after_codex_success(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, head_sha)
  local green, verify_detail, candidate_check = run_local_iteration_check(ready, worktree, base_head)
  if not green then
    local base_probe = M.base_local_iteration_probe(worktree, base_head, attempt)
    local verdict = local_iteration_verdict.classify(candidate_check.exit_code, base_probe)
    devloop_logging.log_line("info", "implement", ready.proposal_id, "IMPLEMENT_VERIFY_BASE", {
      "base_sha=" .. tostring(base_head),
      "base_exit=" .. tostring(base_probe.exit),
      "head_readback=" .. tostring(base_probe.head_readback),
      "status=" .. tostring(base_probe.status),
      "verdict=" .. tostring(verdict),
    })
    if verdict == "OWN_LOCAL_RED" then
      return impl_failed_outcome(ready, "local-iteration-failed", verify_detail, attempt, started_at, exec_ref, base_head)
    end
    if verdict == "BASE_RED" then
      return impl_failed_outcome(ready, "base-local-iteration-failed", base_probe_detail(base_probe), attempt, started_at, exec_ref, base_head)
    end
    return impl_failed_outcome(ready, "local-iteration-attribution-indeterminate", base_probe_detail(base_probe), attempt, started_at, exec_ref, base_head)
  end
  local verified_head = head_sha or M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  return implementation_outcome(ready, worktree, branch, verified_head, integration_branch, base_head, attempt, started_at, exec_ref)
end

function M.after_codex_failure(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, stderr)
  local status = devloop_commands.git_status(worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end
  local dirty = tostring(status.stdout or "") ~= ""
  local existing_head = M.clean_branch_head(base_head, branch)
  local green = false
  local verify_detail = ""
  if dirty or existing_head ~= nil then
    green, verify_detail = run_local_iteration_check(ready, worktree, base_head)
  end
  if green then
    local head_sha = dirty and M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
      or existing_head
    if head_sha ~= nil then
      return implementation_outcome(ready, worktree, branch, head_sha, integration_branch, base_head, attempt, started_at, exec_ref)
    end
  end
  if existing_head ~= nil then
    return checkpoint_outcome(ready, worktree, branch, existing_head, integration_branch, base_head, attempt, started_at, exec_ref, verify_detail ~= "" and verify_detail or stderr)
  end
  return impl_failed_outcome(ready, "codex-failed", stderr, attempt, started_at, exec_ref, base_head)
end

return M
