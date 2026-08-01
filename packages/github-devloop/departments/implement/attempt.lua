local branch_progress = require("departments.implement.branch_progress")
local convergence_identity = require("contract.convergence_identity")
local context_bundle = require("devloop.context_bundle")
local core = require("core")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local harvest = require("departments.implement.harvest")
local implementation_result = require("departments.implement.implementation_result")
local implement_caps = require("implement_department_caps")
local implement_profile = require("departments.implement.profile")
local proof_attempt = require("departments.implement.proof_attempt")
local restart_sink_grants = require("restart_sink_grants")
local substrate_pin = require("departments.implement.substrate_pin")
local workflow_codex = require("workflow_internal.codex")

local M = {}

local function invalid_result(ready, detail, attempt, started_at, exec_ref, base_head)
  return harvest.impl_failed_outcome(
    ready,
    "lean-proof-invalid-result",
    "Invalid typed result envelope: " .. tostring(detail),
    attempt,
    started_at,
    exec_ref,
    base_head
  )
end

local function preserve_incomplete_source(repo, issue_number, ready, worktree, branch)
  local status = devloop_commands.git_status(worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end
  if tostring(status.stdout or "") ~= "" then
    return harvest.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  end
  return nil
end

local function proof_context(ready, current, target, attempt, timeout_seconds)
  local phase = tonumber(attempt) == 1 and "construction" or "strong-repair"
  local context = {
    target = target,
    phase = phase,
    attempt = tonumber(attempt),
    implementation_version = ready.dedup_key,
    timeout_seconds = timeout_seconds,
  }
  if phase == "strong-repair" then
    local prior = proof_attempt.previous_receipt(current.comments, {
      proposal_id = ready.proposal_id,
      target = target,
      before_attempt = attempt,
      checker_command = proof_attempt.checker_command(target),
    })
    if prior == nil then
      return nil, "strong repair requires a validated prior proof receipt from the issue source"
    end
    context.prior_receipt = prior
  end
  return context
end

local function completed_proof_outcome(args, receipt, timeout_seconds)
  local verification = proof_attempt.verify_candidate(args.worktree, receipt.target, timeout_seconds)
  if not verification.ok then
    return harvest.impl_failed_outcome(
      args.ready,
      verification.reason,
      verification.detail,
      args.attempt,
      args.codex_started_at,
      args.exec_ref,
      args.base_head
    )
  end
  return nil
end

local function proof_result_outcome(args, result, profile_context, timeout_seconds)
  local receipt, err = proof_attempt.decode(result.stdout, {
    proposal_id = args.ready.proposal_id,
    implementation_version = args.ready.dedup_key,
    attempt = args.attempt,
    phase = profile_context.phase,
    target = profile_context.target,
    checker_command = proof_attempt.checker_command(profile_context.target),
  })
  if receipt == nil then
    return invalid_result(args.ready, err, args.attempt, args.codex_started_at, args.exec_ref, args.base_head), false
  end
  if receipt.status == "repair-needed" then
    preserve_incomplete_source(args.repo, args.issue_number, args.ready, args.worktree, args.branch)
    local reason = tonumber(args.attempt) == 1 and "lean-proof-repair-needed" or "lean-proof-exhausted"
    return harvest.impl_failed_outcome(
      args.ready,
      reason,
      receipt.raw,
      args.attempt,
      args.codex_started_at,
      args.exec_ref,
      args.base_head
    ), false
  end
  local rejected = completed_proof_outcome(args, receipt, timeout_seconds)
  return rejected, rejected == nil
end

local function dispatch_prompt(args, framing, profile, target)
  if profile ~= "lean-proof" then
    return core.build_implement_prompt(
      args.ready.proposal_id,
      args.current,
      framing,
      args.content_fetch,
      profile,
      {
        implementation_version = args.ready.dedup_key,
        attempt = args.attempt,
      }
    ), nil, nil
  end
  local timeout_seconds = workflow_codex.with_resolved_timeout("implement", {}).timeout
  local context, err = proof_context(args.ready, args.current, target, args.attempt, timeout_seconds)
  if context == nil then
    return nil, invalid_result(
      args.ready,
      err,
      args.attempt,
      args.codex_started_at,
      args.exec_ref,
      args.base_head
    ), nil
  end
  return core.build_implement_prompt(
    args.ready.proposal_id,
    args.current,
    framing,
    args.content_fetch,
    profile,
    context
  ), nil, { context = context, timeout_seconds = timeout_seconds }
end

local function run_attempt(args)
  devloop_logging.log_codex_start("implement", args.ready.proposal_id, "implement")
  args.content_fetch = context_bundle.context_fetch_from_bundle(core, {
    dept = "implement",
    repo = args.repo,
    issue_number = args.issue_number,
    proposal_id = args.ready.proposal_id,
    version = args.ready.dedup_key,
    tick = args.event_ts,
  })
  local framing = implement_profile.accepted_framing(args.ready, args.current.comments)
  local profile, target = implement_profile.resolve(core.git, args.branch, framing)
  local prompt, prompt_failure, proof = dispatch_prompt(args, framing, profile, target)
  if prompt_failure ~= nil then
    return prompt_failure
  end

  restart_sink_grants.consume(implement_caps, args.receiver_authorization, "codex.dispatch:implement",
    "github-devloop: implement codex dispatch grant")
  local dispatch_opts = {
    prompt = prompt,
    worktree = args.worktree,
    sync = true,
  }
  if proof ~= nil then
    dispatch_opts.timeout = proof.timeout_seconds
  end
  local codex_dispatch = args.codex_dispatch or workflow_codex.dispatch
  local identity = args.codex_identity or convergence_identity.from_parts(
    "implement", args.ready.proposal_id, args.ready.dedup_key, { angle_lane = "worker" })
  local result = codex_dispatch(identity, dispatch_opts)

  if type(result) == "table" and result.deferred then
    devloop_logging.log_codex_result("implement", args.ready.proposal_id, "implement", result, "result=deferred", nil)
    return nil
  end
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local stderr = type(result) == "table" and result.stderr or "nil result"
    devloop_logging.log_codex_result("implement", args.ready.proposal_id, "implement", result, nil, stderr, {
      queue = args.event_queue,
      source_ref = args.ready.source_ref,
      terminal = false,
    })
    return harvest.after_codex_failure(
      args.repo,
      args.issue_number,
      args.ready,
      args.branches.integration,
      args.branch,
      args.base_head,
      args.worktree,
      args.attempt,
      args.codex_started_at,
      args.exec_ref,
      stderr
    )
  end
  devloop_logging.log_codex_result("implement", args.ready.proposal_id, "implement", result, "result=completed", nil)

  if proof ~= nil then
    local proof_outcome, complete = proof_result_outcome(args, result, proof.context, proof.timeout_seconds)
    if not complete then
      return proof_outcome
    end
  end

  local status = devloop_commands.git_status(args.worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end

  if tostring(status.stdout or "") == "" then
    local head_sha = branch_progress.implemented_branch_head(args.base_head, args.branch)
    if head_sha ~= nil and not substrate_pin.is_only_pin_delta(args.base_head, args.branch) then
      devloop_logging.log_line("info", "implement", args.ready.proposal_id, "IMPLEMENT", {
        "branch=" .. tostring(args.branch),
        "head_sha=" .. tostring(head_sha),
        "reason=reusing clean ahead implementation branch",
      })
      return harvest.after_codex_success(
        args.repo, args.issue_number, args.ready, args.branches.integration, args.branch,
        args.base_head, args.worktree, args.attempt, args.codex_started_at, args.exec_ref, head_sha
      )
    end

    if proof == nil then
      local receipt, receipt_err = implementation_result.decode(result.stdout, {
        proposal_id = args.ready.proposal_id,
        implementation_version = args.ready.dedup_key,
        attempt = args.attempt,
      })
      if receipt ~= nil and receipt.outcome == "cannot-implement-here" then
        return harvest.implementation_refusal_outcome(
          args.ready,
          receipt,
          args.attempt,
          args.codex_started_at,
          args.exec_ref,
          args.base_head
        )
      end
      if receipt == nil and tostring(result.stdout or "") ~= "" then
        local invalid_detail = "Invalid typed result envelope: " .. tostring(receipt_err)
        devloop_logging.log_codex_result(
          "implement", args.ready.proposal_id, "implement", result, nil, invalid_detail, {
            error_class = "invalid-implementation-result",
            queue = args.event_queue,
            source_ref = args.ready.source_ref,
            terminal = false,
          })
        return harvest.impl_failed_outcome(
          args.ready,
          "invalid-implementation-result",
          invalid_detail,
          args.attempt,
          args.codex_started_at,
          args.exec_ref,
          args.base_head
        )
      end
    end

    local detail = tostring(result.stdout or "")
    if detail == "" then
      detail = tostring(result.stderr or "")
    end
    devloop_logging.log_codex_result("implement", args.ready.proposal_id, "implement", result, nil, "no-changes", {
      queue = args.event_queue,
      source_ref = args.ready.source_ref,
      terminal = false,
    })
    return harvest.impl_failed_outcome(
      args.ready,
      "no-changes",
      detail,
      args.attempt,
      args.codex_started_at,
      args.exec_ref,
      args.base_head
    )
  end

  return harvest.after_codex_success(
    args.repo,
    args.issue_number,
    args.ready,
    args.branches.integration,
    args.branch,
    args.base_head,
    args.worktree,
    args.attempt,
    args.codex_started_at,
    args.exec_ref
  )
end

M.run = run_attempt

return M
