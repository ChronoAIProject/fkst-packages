local base_ids = require("devloop.base_ids")
local child_completion = require("core.child_completion")
local child_result = require("core.child_result")
local commands = require("devloop.commands")
local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local devloop_state = require("devloop.state")
local parsers_misc = require("devloop.parsers.misc")
local parsers_issue = require("devloop.parsers.issue")
local parsers_pr = require("devloop.parsers.pr")
local workflow_child_disposition = require("child_disposition")

local M = {}

M.ISSUE_VIEW_TIMEOUT_SECONDS = 30
M.PR_VIEW_TIMEOUT_SECONDS = 30

local function child_issue_view(core, repo, issue_number, deps)
  if type(deps) == "table" and type(deps.read_child_issue) == "function" then
    local current = deps.read_child_issue(core, repo, issue_number)
    if type(current) ~= "table" then
      error("github-devloop-workflow: child-issue-result-invalid: child issue result reader returned an invalid value")
    end
    current.repo = repo
    current.number = issue_number
    current.proposal_id = base_ids.proposal_id(repo, issue_number)
    return current
  end
  local result = commands.gh_issue_view(
    repo,
    issue_number,
    "title,body,updatedAt,labels,comments,state,assignees,author",
    M.ISSUE_VIEW_TIMEOUT_SECONDS
  )
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop-workflow: child-issue-result-view-failed: child issue result view failed: " .. tostring(result and result.stderr or "nil result"))
  end
  local current = parsers_issue.parse_issue_view_intake_judge(core, result.stdout)
  current.repo = repo
  current.number = issue_number
  current.proposal_id = base_ids.proposal_id(repo, issue_number)
  return current
end

local function pr_view(core, repo, pr_number)
  local result = commands.gh_pr_view_origin(repo, pr_number, M.PR_VIEW_TIMEOUT_SECONDS)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop-workflow: child-pr-result-view-failed: child PR result view failed: " .. tostring(result and result.stderr or "nil result"))
  end
  local current = parsers_pr.parse_pr_view_origin(result.stdout)
  current.number = pr_number
  return current
end

local function production_child_status_deps(core, repo, deps)
  local issue_cache = {}
  local pr_cache = {}
  local impl_failure_cache = {}
  local completion_cache = {}

  local function issue(child_ref)
    local number = tostring(child_ref.issue_number or child_ref.number or "")
    if issue_cache[number] == nil then
      issue_cache[number] = child_issue_view(core, repo, number, deps)
    end
    return issue_cache[number]
  end

  local function linked_pr(child_ref)
    return child_completion.linked_pr(issue(child_ref), child_ref)
  end

  local function pr(link)
    if link == nil then
      return nil
    end
    local number = tostring(link.pr_number)
    if pr_cache[number] == nil then
      pr_cache[number] = pr_view(core, repo, link.pr_number)
    end
    return pr_cache[number]
  end

  local function completion(child_ref)
    local number = tostring(child_ref.issue_number or child_ref.number or "")
    if completion_cache[number] == nil then
      local child = issue(child_ref)
      local link = linked_pr(child_ref)
      local evidence = child_completion.evidence(child, nil, child_ref)
      if not evidence.marker and link ~= nil then
        evidence = child_completion.evidence(child, pr(link), child_ref)
      end
      completion_cache[number] = evidence
    end
    return completion_cache[number]
  end

  local function current_impl_failure(child_ref)
    local number = tostring(child_ref.issue_number or child_ref.number or "")
    if impl_failure_cache[number] == nil then
      local child = issue(child_ref)
      impl_failure_cache[number] = {
        fact = impl_failure.current_fact(
          core._max_key_len,
          core._max_dedup_len,
          child.comments,
          child_ref.proposal_id
        ),
      }
    end
    return impl_failure_cache[number]
  end

  return {
    has_merged_marker = function(child_ref)
      return completion(child_ref).marker
    end,
    current_entity = function(child_ref)
      local child = issue(child_ref)
      local link = linked_pr(child_ref)
      child.proposal_id = child_ref.proposal_id
      if link ~= nil then
        child.pr_number = link.pr_number
        child.version = link.impl_version or link.version
      end
      return child
    end,
    github_closed_with_merged_pr = function(child_ref)
      return completion(child_ref).native
    end,
    current_obligation_disposition = function(child_ref)
      local lineage = child_ref.workflow_lineage
      if type(lineage) ~= "table"
        or type(lineage.origin) ~= "string"
        or lineage.origin == ""
        or type(lineage.blueprint_digest) ~= "string"
        or lineage.blueprint_digest == ""
        or type(lineage.slot) ~= "string"
        or lineage.slot == "" then
        return nil
      end
      local fact = workflow_child_disposition.current_fact(deps, {
        repo = repo,
        origin = lineage.origin,
        blueprint_digest = lineage.blueprint_digest,
        slot = lineage.slot,
        child_issue = tostring(child_ref.issue_number or child_ref.number or ""),
      })
      if fact ~= nil and fact.disposition == "transferred" then
        local successor_repo, successor_issue = devloop_base.parse_issue_source_ref(fact.successor_source_ref)
        if successor_repo ~= repo or successor_issue == nil then
          error("github-devloop-workflow: transferred-successor-ref-invalid: transferred successor must remain in the workflow repository")
        end
        fact.successor_ref = {
          kind = "issue",
          repo = repo,
          issue_number = tostring(successor_issue),
          proposal_id = base_ids.proposal_id(repo, successor_issue),
          source_ref = fact.successor_source_ref,
          workflow_lineage = {
            origin = lineage.origin,
            blueprint_digest = lineage.blueprint_digest,
            slot = lineage.slot,
          },
        }
      end
      return fact
    end,
    irreversible_terminal = function(child_ref)
      local child = issue(child_ref)
      local current = devloop_state.route_current(
        child.comments,
        child.proposal_id or child_ref.proposal_id,
        { blocked = true }
      )
      if current.route == true then
        return true
      end
      if tostring(child.state or ""):upper() == "CLOSED" then
        local link = linked_pr(child_ref)
        if link == nil then
          return true
        end
        local current_pr = pr(link)
        -- A CLOSED child whose PR did NOT genuinely merge is irreversibly terminal.
        -- Use pr_is_merged so the JSON-null sentinel is not mistaken for a merge.
        return not child_completion.pr_is_merged(current_pr)
      end
      return false
    end,
    recovery_in_progress = function()
      return false
    end,
    impl_failed_retryable = function(child_ref)
      local current = current_impl_failure(child_ref)
      return current.fact ~= nil and impl_failure.retry_allowed(current.fact)
    end,
    impl_failed_non_retryable = function(child_ref)
      local current = current_impl_failure(child_ref)
      return current.fact ~= nil and not impl_failure.retry_allowed(current.fact)
    end,
    impl_failed_reason = function(child_ref)
      local current = current_impl_failure(child_ref)
      return current.fact and current.fact.reason or nil
    end,
  }
end

function M.reader(core, deps, repo)
  if type(deps.child_status) == "function" then
    return function(child_ref)
      return deps.child_status(core, child_ref)
    end
  end
  local child_deps = production_child_status_deps(core, repo, deps)
  local function status_of(child_ref, ancestors)
    local identity = child_ref and child_ref.source_ref and child_ref.source_ref.ref
      or child_ref and child_ref.proposal_id
      or child_ref and child_ref.issue_number
    identity = tostring(identity or "")
    if identity == "" or ancestors[identity] == true then
      return child_result.STATUS_UNKNOWN
    end
    local next_ancestors = {}
    for key, value in pairs(ancestors) do
      next_ancestors[key] = value
    end
    next_ancestors[identity] = true
    local scoped_deps = {}
    for key, value in pairs(child_deps) do
      scoped_deps[key] = value
    end
    scoped_deps.transferred_child_status = function(successor_ref)
      return status_of(successor_ref, next_ancestors)
    end
    return child_result.child_result_status(scoped_deps, child_ref)
  end
  return function(child_ref)
    return status_of(child_ref, {})
  end
end

return M
