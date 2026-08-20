local branch_progress = require("departments.implement.branch_progress")
local convergence_identity = require("contract.convergence_identity")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local result_facts = require("devloop.markers.result_facts")
local harvest = require("departments.implement.harvest")
local implementation_result = require("departments.implement.implementation_result")
local implement_caps = require("implement_department_caps")
local result_checkpoint = require("departments.implement.result_checkpoint")
local restart_sink_grants = require("restart_sink_grants")
local substrate_pin = require("departments.implement.substrate_pin")
local workflow_codex = require("workflow_internal.codex")

local M = {}

local function accepted_framing(ready, comments)
  if type(ready) ~= "table" then
    return nil
  end
  if ready.framing ~= nil then
    return ready.framing
  end
  local fact = result_facts.current_result_fact(comments, ready.proposal_id, ready.dedup_key)
  if fact ~= nil and fact.decision == "approve" then
    return fact.framing
  end
  return nil
end

local function no_changes_outcome(args, result)
  local detail = tostring(result.stdout or "")
  if detail == "" then detail = tostring(result.stderr or "") end
  devloop_logging.log_codex_result("implement", args.ready.proposal_id, "implement", result, nil, "no-changes", {
    queue = args.event_queue,
    source_ref = args.ready.source_ref,
    terminal = false,
  })
  return harvest.impl_failed_outcome(
    args.ready, "no-changes", "UNKNOWN", false, detail, args.attempt,
    args.codex_started_at, args.exec_ref, args.base_head)
end

local function run_attempt(args)
  devloop_logging.log_codex_start("implement", args.ready.proposal_id, "implement")
  args.content_fetch = args.context_fetch({
    dept = "implement",
    repo = args.repo,
    issue_number = args.issue_number,
    proposal_id = args.ready.proposal_id,
    version = args.ready.dedup_key,
    tick = args.event_ts,
  })
  local framing = accepted_framing(args.ready, args.current.comments)
  local prompt = implement_caps.prompts.build_implement_prompt(
    args.ready.proposal_id,
    args.current,
    framing,
    args.content_fetch,
    {
      implementation_version = args.ready.dedup_key,
      attempt = args.attempt,
    }
  )

  restart_sink_grants.consume(implement_caps, args.receiver_authorization, "codex.dispatch:implement",
    "github-devloop: implement codex dispatch grant")
  local dispatch_opts = {
    prompt = prompt,
    worktree = args.worktree,
    sync = true,
  }
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

  local unavailable = harvest.worktree_unavailable_outcome(
    args.ready,
    args.worktree,
    args.attempt,
    args.codex_started_at,
    args.exec_ref,
    args.base_head
  )
  if unavailable ~= nil then
    return unavailable
  end

  local status = devloop_commands.git_status(args.worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end

  if tostring(status.stdout or "") == "" then
    local head_sha = branch_progress.implemented_worktree_head(args.base_head, args.worktree)
    if head_sha ~= nil and not substrate_pin.is_only_pin_delta(
      args.base_head, head_sha, args.worktree) then
      devloop_logging.log_line("info", "implement", args.ready.proposal_id, "IMPLEMENT", {
        "branch=" .. tostring(args.branch),
        "head_sha=" .. tostring(head_sha),
        "reason=clean implementation attempt worktree contains progress",
      })
    else
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
          "UNKNOWN",
          false,
          invalid_detail,
          args.attempt,
          args.codex_started_at,
          args.exec_ref,
          args.base_head
        )
      end
      return no_changes_outcome(args, result)
    end
  else
    harvest.commit_dirty_worktree(args.repo, args.issue_number, args.ready, args.worktree, args.branch)
  end

  local result_head = result_checkpoint.persist(implement_caps.git_handle, args.worktree, args.ready.dedup_key)
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
    args.exec_ref,
    result_head
  )
end

M.run = run_attempt
M.bound_verification_checkpoint = harvest.bound_verification_checkpoint

function M.resume(args)
  return harvest.after_codex_success(
    args.repo, args.issue_number, args.ready, args.branches.integration, args.branch,
    args.base_head, args.worktree, args.attempt, args.codex_started_at, args.exec_ref,
    args.head_sha)
end

return M
