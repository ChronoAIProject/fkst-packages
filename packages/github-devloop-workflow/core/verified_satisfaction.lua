local config = require("devloop.config")
local devloop_base = require("devloop.base")
local gitref = require("forge.gitref")
local local_iteration_result = require("devloop.local_iteration_result")
local workflow_codex = require("workflow_internal.codex")

local M = {}

M.WORKFLOW = "software-feature-flow"
M.SLOT = "production-slice"

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.merged_pr_commit(current_pr)
  if type(current_pr) ~= "table" then
    return nil
  end
  local merged = tostring(current_pr.state or ""):upper() == "MERGED"
    or (type(current_pr.merged_at) == "string" and current_pr.merged_at ~= "")
  local commit = current_pr.merge_commit_sha
  if not merged or not gitref.is_git_sha(commit) then
    return nil
  end
  return commit
end

local function checkout_result_error(detail)
  error("github-devloop-workflow: verified-satisfaction-checkout-result-invalid: " .. detail)
end

local function checkout_command_error(detail)
  error("github-devloop-workflow: verified-satisfaction-checkout-command-failed: " .. detail)
end

local function require_checkout_command(result, label)
  if type(result) ~= "table" then
    checkout_result_error(label .. " returned a non-table result")
  end
  local exit_code = tonumber(result.exit_code)
  if exit_code == nil or type(result.stdout) ~= "string" then
    checkout_result_error(label .. " returned an invalid command result")
  end
  if exit_code ~= 0 then
    checkout_command_error(label .. " exited " .. tostring(exit_code))
  end
  return result
end

local function command_sha(result, label)
  require_checkout_command(result, label)
  local value = trim(result.stdout)
  if not gitref.is_git_sha(value) then
    checkout_result_error(label .. " returned an invalid SHA")
  end
  return value
end

local function require_checkout_observation(checkout, label)
  if type(checkout) ~= "table"
    or not gitref.is_git_sha(checkout.head_sha)
    or not gitref.is_git_sha(checkout.tree)
    or type(checkout.clean) ~= "boolean" then
    checkout_result_error(label .. " returned an invalid checkout observation")
  end
  return checkout
end

local function production_checkout(deps)
  local root = config.project_root() or "."
  local git = deps.git or require("forge.git").production_handle(
    "github-devloop-workflow:verified-satisfaction"
  )
  local status = require_checkout_command(git.status_porcelain(root, 30), "checkout status")
  local head_sha = command_sha(git.head_sha(root, 30), "checkout HEAD")
  local tree = command_sha(git.head_tree(root, 30), "checkout tree")
  return {
    root = root,
    head_sha = head_sha,
    tree = tree,
    clean = trim(status.stdout) == "",
  }
end

function M.current_checkout(deps)
  local selected = deps or {}
  local checkout
  if type(selected.current_checkout) == "function" then
    checkout = require_checkout_observation(
      selected.current_checkout(),
      "injected checkout reader"
    )
  else
    checkout = require_checkout_observation(
      production_checkout(selected),
      "production checkout reader"
    )
  end
  if checkout.clean == false then
    return nil
  end
  return checkout
end

function M.is_ancestor(deps, checkout, ancestor, descendant)
  if type(deps.is_ancestor) == "function" then
    local injected = deps.is_ancestor(ancestor, descendant)
    if type(injected) ~= "boolean" then
      error("github-devloop-workflow: verified-satisfaction-ancestry-result-invalid: "
        .. "injected ancestry reader must return a boolean")
    end
    return injected
  end
  local git = deps.git or require("forge.git").production_handle(
    "github-devloop-workflow:verified-satisfaction"
  )
  local result = git.is_ancestor_worktree(checkout.root or ".", ancestor, descendant, 30)
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  if exit_code == 0 then
    return true
  end
  if exit_code == 1 then
    return false
  end
  if exit_code == nil then
    error("github-devloop-workflow: verified-satisfaction-ancestry-result-invalid: "
      .. "git ancestry check returned no exit status")
  end
  error("github-devloop-workflow: verified-satisfaction-ancestry-command-failed: "
    .. "git ancestry check exited " .. tostring(exit_code))
end

local function run_local_iteration(deps, checkout)
  if type(deps.run_local_iteration) == "function" then
    return deps.run_local_iteration(checkout)
  end
  local command = "cd " .. devloop_base._shell_single_quote(checkout.root or ".")
    .. " && " .. config.local_iteration_test_command()
  return exec_sync({
    cmd = command,
    timeout = workflow_codex.role_timeout_seconds("implement"),
  })
end

local function exact_scope(ctx)
  return type(ctx) == "table"
    and ctx.workflow == M.WORKFLOW
    and ctx.slot == M.SLOT
    and type(ctx.refusal) == "table"
    and ctx.refusal.reason == "already-satisfied"
    and type(ctx.origin) == "string"
    and type(ctx.blueprint_digest) == "string"
    and type(ctx.child_issue) == "string"
end

function M.verify(ctx, deps)
  local selected = deps or {}
  if not exact_scope(ctx) then
    return nil
  end
  local predecessor_commit = M.merged_pr_commit(ctx.predecessor_pr)
  if predecessor_commit == nil then
    return nil
  end
  local before = M.current_checkout(selected)
  if before == nil or not M.is_ancestor(selected, before, predecessor_commit, before.head_sha) then
    return nil
  end
  local verification = local_iteration_result.from_command(run_local_iteration(selected, before))
  if verification.kind ~= "PASS" or verification.fault_class ~= "NONE" then
    return nil
  end
  local after = M.current_checkout(selected)
  if after == nil or after.head_sha ~= before.head_sha or after.tree ~= before.tree then
    return nil
  end
  return {
    origin = ctx.origin,
    workflow = ctx.workflow,
    blueprint_digest = ctx.blueprint_digest,
    slot = ctx.slot,
    child_issue = ctx.child_issue,
    predecessor_commit = predecessor_commit,
    tree = after.tree,
    verification = "PASS",
  }
end

function M.matching_fact(facts, ctx, checkout, deps)
  if type(ctx) ~= "table" or type(checkout) ~= "table" then
    return nil
  end
  local predecessor_commit = M.merged_pr_commit(ctx.predecessor_pr)
  if predecessor_commit == nil then
    return nil
  end
  for _, fact in ipairs(facts or {}) do
    if fact.origin == ctx.origin
      and fact.workflow == M.WORKFLOW
      and fact.blueprint_digest == ctx.blueprint_digest
      and fact.slot == M.SLOT
      and fact.child_issue == tostring(ctx.child_issue or "")
      and fact.predecessor_commit == predecessor_commit
      and fact.tree == checkout.tree
      and fact.verification == "PASS" then
      if M.is_ancestor(deps or {}, checkout, predecessor_commit, checkout.head_sha) then
        return fact
      end
      return nil
    end
  end
  return nil
end

function M.done_reason(predecessor_commit)
  if not gitref.is_git_sha(predecessor_commit) then
    return nil
  end
  return "all-slots-result-ready-delivered-by-" .. predecessor_commit
end

return M
