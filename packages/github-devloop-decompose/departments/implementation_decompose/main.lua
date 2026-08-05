local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local convergence_identity = require("contract.convergence_identity")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local escalation = require("devloop.implementation_escalation")
local m_claims = require("devloop.claims")
local m_facts = require("devloop.markers.facts")
local saga = require("workflow.saga")
local strings = require("contract.strings")
local workflow_codex = require("workflow_internal.codex")
local default_caps = require("implementation_decompose_department_caps")

local spec = {
  consumes = { "devloop_implementation_decompose" },
  published_seam = { "devloop_implementation_decompose" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "2m",
  retry = { max_attempts = 2, base = "5s", cap = "10s" },
}

local function current_issue(caps, repo, issue_number)
  local view = devloop_commands.gh_issue_view_decompose(repo, issue_number, 30)
  if view.exit_code ~= 0 then
    error("github-devloop: implementation-decomposition-issue-read-failed: issue view failed: "
      .. tostring(view.stderr))
  end
  return caps.parse_issue_view(view.stdout)
end

local function evidence_matches(payload, fact, checkpoint)
  return fact ~= nil
    and checkpoint ~= nil
    and fact.attempt == payload.attempt
    and fact.previous_attempt == payload.previous_attempt
    and fact.head_sha == payload.head_sha
    and fact.policy_id == payload.evidence_policy
    and checkpoint.attempt == payload.attempt
    and checkpoint.branch == payload.branch
    and checkpoint.head_sha == payload.head_sha
end

local function run_supervisor(caps, event, repo, issue_number, payload, issue)
  local content_fetch = caps.context_fetch({
    dept = "implementation-decompose",
    repo = repo,
    issue_number = issue_number,
    proposal_id = payload.proposal_id,
    version = payload.version,
    tick = event.ts,
  })
  local prompt = caps.build_prompt(payload, issue, content_fetch)
  local identity = convergence_identity.from_parts(
    "decompose", payload.proposal_id, payload.version, { angle_lane = "implementation-supervisor" })
  local result = workflow_codex.dispatch(identity, {
    prompt = prompt,
    worktree = devloop_base.judgment_worktree_with_exec(
      exec_sync, "implementation-decompose", payload.dedup_key),
    sync = true,
  })
  if type(result) == "table" and result.deferred == true then
    return nil
  end
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop: implementation-decomposition-codex-failed: supervisor codex failed: "
      .. tostring(type(result) == "table" and result.stderr or "nil result"))
  end
  local plan = escalation.parse_decomposition_plan(result.stdout)
  if plan == nil then
    error("github-devloop: implementation-decomposition-output-invalid: supervisor output is not a valid plan")
  end
  return plan
end

local function marker_path(payload)
  return "/tmp/fkst-github-devloop-implementation-decompose-"
    .. strings.runtime_safe_segment(payload.proposal_id .. "-" .. payload.attempt) .. ".md"
end

local function write_decomposition_marker(caps, repo, issue_number, payload, count)
  local path = marker_path(payload)
  local marker = escalation.decomposition_marker(payload, count)
  local body = caps.with_github_debug_stamp(
    "github-devloop implementation decomposition planned " .. tostring(count) .. " child issue(s)\n\n" .. marker,
    {
      emitter = "github-devloop-decompose.implementation-decompose",
      target = "issue:" .. tostring(repo) .. "#" .. tostring(issue_number),
      dedup_key = payload.dedup_key,
      context = payload.proposal_id,
    })
  file.write(path, body)
  local result = devloop_commands.gh_issue_comment(repo, issue_number, path, 30)
  if result.exit_code ~= 0 then
    error("github-devloop: implementation-decomposition-marker-write-failed: issue comment failed: "
      .. tostring(result.stderr))
  end
  require("devloop.github_proxy_entity_view").invalidate_entity_after_write(repo, "issue", issue_number)
  local confirmed = current_issue(caps, repo, issue_number)
  if escalation.decomposition_fact(confirmed.comments, payload.proposal_id, payload.version) == nil then
    error("github-devloop: implementation-decomposition-marker-pending: marker is not visible after write")
  end
end

local function accepted(event)
  local payload = event and event.payload or nil
  if escalation.is_supported_payload(payload) then
    return true
  end
  devloop_logging.log_entry("implementation_decompose", event, "unknown",
    devloop_logging.payload_field(payload, "dedup_key"))
  devloop_logging.log_cas_decision("implementation_decompose", "unknown",
    { state = nil, version = nil }, "implementation-escalating", "implementation-escalating",
    "skip-foreign(payload)", "unsupported implementation escalation payload")
  return false
end

local function done(_event)
  return false
end

local function make_department(caps)
  caps = caps or default_caps

  local function act(event)
    local payload = event.payload
    local repo, issue_number = base_ids.parse_proposal_id(payload.proposal_id)
    local lock_key = require("devloop.entity").transition_lock_key(payload.proposal_id)
    if repo == nil or lock_key == nil then
      error("github-devloop: implementation-decomposition-identity-invalid: proposal identity is invalid")
    end
    with_lock(lock_key, function()
      devloop_base.assert_trusted_bot_configured()
      local issue = current_issue(caps, repo, issue_number)
      local open = caps.rederive_issue_is_open(repo, issue_number)
      if not open then
        devloop_logging.log_cas_decision("implementation_decompose", payload.proposal_id,
          { state = nil, version = payload.version }, "implementation-escalating", "implementation-escalating",
          "skip-stale(original-closed)", "parent issue is closed")
        return
      end
      if not m_claims.verify_pr_review_issue_claim(
        "implementation_decompose", repo, issue_number, issue, payload.proposal_id) then
        return
      end
      local escalation_reached = devloop_state.reached(
        issue.comments,
        payload.proposal_id,
        "implementation-escalating",
        { domain = "github-devloop-issue", lineage_base = payload.version }
      )
      local escalation_state = { state = "implementation-escalating", version = payload.version }
      if not escalation_reached then
        devloop_logging.log_cas_decision("implementation_decompose", payload.proposal_id, escalation_state,
          "implementation-escalating", "implementation-escalating", "skip-stale(state-advanced)",
          "implementation escalation milestone is not present in the requested lineage")
        return
      end
      local fact = escalation.escalation_fact(issue.comments, payload.proposal_id, payload.version)
      local checkpoint = m_facts.implement_checkpoint_fact(
        issue.comments, payload.proposal_id, payload.version)
      if not evidence_matches(payload, fact, checkpoint) then
        error("github-devloop: implementation-decomposition-evidence-mismatch: trusted escalation evidence does not match checkpoint")
      end
      local plan = run_supervisor(caps, event, repo, issue_number, payload, issue)
      if plan == nil then
        return
      end
      local existing = escalation.decomposition_fact(issue.comments, payload.proposal_id, payload.version)
      local count = existing and existing.count or #plan
      if #plan < count then
        error("github-devloop: implementation-decomposition-output-invalid: replayed plan has fewer children than durable plan")
      end
      if config.write_mode() ~= "real" then
        devloop_logging.log_cas_decision("implementation_decompose", payload.proposal_id, escalation_state,
          "implementation-escalating", "implementation-escalating", "dry-run(marker-write-required)",
          "FKST_GITHUB_WRITE=1 is required before decomposition effects")
        return
      end
      if existing == nil then
        write_decomposition_marker(caps, repo, issue_number, payload, count)
      end
      devloop_logging.log_apply("implementation_decompose", payload.proposal_id, nil, nil,
        { add = {}, remove = {} }, { "github-proxy.github_issue_create_request" })
      for index = 1, count do
        local request = escalation.build_child_issue_request(repo, issue_number, payload, plan[index], index)
        devloop_logging.log_raise("implementation_decompose", payload.proposal_id,
          "github-proxy.github_issue_create_request", request)
      end
    end)
  end

  local department = saga.department(spec, {
    accept = accepted,
    done = done,
    act = act,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = "implementation_decompose",
  })
  department.make_department = make_department
  return department
end

return make_department(default_caps)
