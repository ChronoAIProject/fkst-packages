local devloop_entity_view = require("devloop.github_proxy_entity_view")
local entity_highwater = require("devloop.entity_highwater")
local entity_lib = require("devloop.entity")
local m_facts = require("devloop.markers.facts")
local parsers_pr = require("devloop.parsers.pr")
local v_pr = require("devloop.validators.pr")
local devloop_logging = require("devloop.logging")

local P = {}

local function source_pr_lock(pr)
  return entity_lib.observe_lock_key(pr.repo, pr.number, "pr")
end

local function fetch_current(event, pr)
  local pr_view = devloop_entity_view.fetch_pr_view_origin(pr.repo, pr.number, pr.updated_at, {
    force_fresh = true,
    allow_cached_validator = true,
    consumer = "observe_issue",
  })
  if pr_view.exit_code ~= 0 then
    error("github-devloop: pr-read-failed: observe-issue-pr-view-failed: " .. tostring(pr_view.stderr))
  end

  local current_pr = parsers_pr.parse_pr_view_origin(pr_view.stdout)
  current_pr.number = pr.number
  current_pr.force_fresh = true
  local origin = m_facts.pr_origin_fact(current_pr.comments)
  local prepared = {
    current_pr = current_pr,
    event = event,
    origin = origin,
    pr = pr,
  }
  if origin == nil or origin.pr_native == true or origin.repo ~= pr.repo or tonumber(origin.issue_number) == nil then
    return source_pr_lock(pr), prepared
  end
  return entity_lib.observe_lock_key(origin.repo, origin.issue_number), prepared
end

local function replay_parent(prepared, process_issue_event, record_authoritative_version)
  local current_pr = prepared.current_pr
  local event = prepared.event
  local origin = prepared.origin
  local pr = prepared.pr
  record_authoritative_version(current_pr.updated_at)

  if origin == nil or origin.pr_native == true or origin.repo ~= pr.repo or tonumber(origin.issue_number) == nil then
    devloop_logging.log_entry("observe_issue", event, "unknown", devloop_logging.payload_field(pr, "dedup_key"))
    devloop_logging.log_cas_decision("observe_issue", "unknown", { state = nil, version = nil }, "awaiting-pr", "awaiting-pr", "skip-foreign(pr-origin)", "PR entity change has no issue-backed devloop origin")
    return
  end
  if tostring(origin.branch or "") ~= tostring(current_pr.head_ref_name or "")
    or tostring(origin.base_branch or "") ~= tostring(current_pr.base_ref_name or "") then
    devloop_logging.log_entry("observe_issue", event, origin.proposal_id, devloop_logging.payload_field(pr, "dedup_key"))
    devloop_logging.log_cas_decision("observe_issue", origin.proposal_id, { state = nil, version = nil }, "awaiting-pr", "awaiting-pr", "skip-stale(pr-origin)", "PR origin no longer matches current PR head/base")
    return
  end

  return process_issue_event({
    queue = event.queue,
    ts = event.ts,
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = origin.repo,
      number = tonumber(origin.issue_number),
      title = "PR-backed parent issue",
      state = "OPEN",
      updated_at = pr.updated_at,
      dedup_key = tostring(pr.dedup_key or "") .. "/parent-awaiting-pr",
      source_ref = entity_lib.issue_source_ref(origin.repo, origin.issue_number),
      source = "pr-entity-change",
      child_pr = current_pr,
    },
  }, {
    highwater_enabled = false,
    lock_held = true,
  })
end

function P.make(process_issue_event)
  if type(process_issue_event) ~= "function" then
    error("github-devloop: observe-issue-pr-parent-processor-missing: PR parent processor is required")
  end
  return function(event)
    local pr = event.payload or {}
    if not v_pr.is_supported_pr(pr) then
      devloop_logging.log_entry("observe_issue", event, "unknown", devloop_logging.payload_field(pr, "dedup_key"))
      devloop_logging.log_cas_decision("observe_issue", "unknown", { state = nil, version = nil }, "awaiting-pr", "awaiting-pr", "skip-foreign(pr)", "unsupported PR payload")
      return
    end

    return entity_highwater.reconcile({
      consumer = "github-devloop/observe_issue",
      event = event,
      resolve_lock = function()
        return fetch_current(event, pr)
      end,
      work = function(prepared, record_authoritative_version)
        return replay_parent(prepared, process_issue_event, record_authoritative_version)
      end,
    })
  end
end

return P
