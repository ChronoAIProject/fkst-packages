local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")
local parsers_issue = require("devloop.parsers.issue")
local devloop_commands = require("devloop.commands")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local core = require("core")
local intake_capacity = require("core.intake_capacity")

local S = {}

local function current_issue_from_source_ref(source_ref, updated_at)
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil or issue_number == nil then
    return nil, nil, nil, "invalid issue source_ref"
  end
  local view = devloop_commands.gh_issue_view_intake_judge(repo, issue_number, 30)
  if view.exit_code ~= 0 then
    error("github-devloop-intake: gh-issue-admission-view-failed: gh issue admission view failed: " .. tostring(view.stderr))
  end
  local current = parsers_issue.parse_issue_view_intake_judge(core, view.stdout)
  current.updated_at = current.updated_at or updated_at
  current.number = issue_number
  return repo, issue_number, current, nil
end

function S.make_context(deps)
  local selected = deps or {}
  return {
    capacity = selected.capacity or intake_capacity.production(core),
    claims = selected.claims or m_claims,
    read_current_issue = selected.read_current_issue or function(source_ref, updated_at)
      return current_issue_from_source_ref(source_ref, updated_at)
    end,
  }
end

function S.reconcile_capacity(context, repo, proposal_id, department)
  local reconciled, reason = context.capacity.reconcile(repo, proposal_id)
  devloop_logging.log_cas_decision(
    department or "admission",
    proposal_id,
    { state = nil, version = nil },
    "capacity-grant",
    "capacity-grant",
    reconciled and "reconciled" or "deferred",
    reason
  )
  return reconciled
end

function S.has_trusted_progress(current, proposal_id)
  if core.should_skip_known_intake_issue(current.labels) then
    return true, "active devloop label is visible"
  end
  if m_facts.has_intake_decision_marker(current.comments, proposal_id) then
    return true, "trusted intake decision marker is already visible"
  end
  if m_facts.has_state_marker(current.comments, proposal_id) then
    return true, "trusted state marker is already visible"
  end
  return false, nil
end

function S.issue_from_current(issue_number, current)
  return {
    number = issue_number,
    title = current.title,
    body = current.body,
    updated_at = current.updated_at,
  }
end

return S
