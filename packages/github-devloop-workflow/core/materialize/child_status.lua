local base_ids = require("devloop.base_ids")
local child_result = require("core.child_result")
local commands = require("devloop.commands")
local impl_failure = require("devloop.impl_failure")
local devloop_marker_facts = require("devloop.markers.facts")
local devloop_state = require("devloop.state")
local parsers_misc = require("devloop.parsers.misc")
local parsers_issue = require("devloop.parsers.issue")
local parsers_pr = require("devloop.parsers.pr")

local M = {}

M.ISSUE_VIEW_TIMEOUT_SECONDS = 30
M.PR_VIEW_TIMEOUT_SECONDS = 30

local function child_issue_view(core, repo, issue_number)
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

-- Canonical "is this PR genuinely merged" check, the single source of truth for
-- every PR-merge decision in this reader. Matches libraries/forge/github_view.lua
-- and devloop/github_proxy_entity_view.lua. json.decode represents a JSON null
-- (mergedAt on an OPEN PR) as a NON-NIL sentinel, so `merged_at ~= nil` wrongly
-- reads open PRs as merged; require state==MERGED or a STRING mergedAt timestamp.
local function pr_is_merged(current_pr)
  if current_pr == nil then
    return false
  end
  if tostring(current_pr.state or ""):upper() == "MERGED" then
    return true
  end
  return type(current_pr.merged_at) == "string" and current_pr.merged_at ~= ""
end

local function production_child_status_deps(core, repo)
  local issue_cache = {}
  local pr_cache = {}
  local impl_failure_cache = {}

  local function issue(child_ref)
    local number = tostring(child_ref.issue_number or child_ref.number or "")
    if issue_cache[number] == nil then
      issue_cache[number] = child_issue_view(core, repo, number)
    end
    return issue_cache[number]
  end

  local function linked_pr(child_ref)
    local current = issue(child_ref)
    return devloop_marker_facts.pr_delegation_fact(current.comments, child_ref.proposal_id, nil)
      or devloop_marker_facts.pr_link_fact(current.comments, child_ref.proposal_id)
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
      local link = linked_pr(child_ref)
      if link == nil then
        return false
      end
      local child = issue(child_ref)
      if devloop_marker_facts.merged_fact(child.comments, child_ref.proposal_id, link.pr_number, nil) ~= nil then
        return true
      end
      local current_pr = pr(link)
      return devloop_marker_facts.merged_fact(current_pr and current_pr.comments, child_ref.proposal_id, link.pr_number, nil) ~= nil
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
      local link = linked_pr(child_ref)
      if link == nil then
        return false
      end
      -- A delegated child is merged only when its PR GENUINELY merged (see
      -- pr_is_merged). The old `merged_at ~= nil` check was fooled by json.decode's
      -- non-nil JSON-null sentinel for an OPEN PR -> premature slot materialization
      -- + false terminal-done (real supervise dogfood 2026-07-04, origins #135/#93).
      return pr_is_merged(pr(link))
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
        return not pr_is_merged(current_pr)
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
  local child_deps = production_child_status_deps(core, repo)
  return function(child_ref)
    return child_result.child_result_status(child_deps, child_ref)
  end
end

return M
