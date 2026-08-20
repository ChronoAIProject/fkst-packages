local git_mechanics = require("devloop.git_mechanics")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local base_ids = require("devloop.base_ids")
local dependency_gate = require("devloop.dependency_gate")
local context_bundle = require("devloop.context_bundle")
local m_claims = require("devloop.claims")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
local parsers_issue = require("devloop.parsers.issue")
local core = require("core")
local queue = require("devloop.queue")
local saga = require("workflow.saga")
local convergence_identity = require("contract.convergence_identity")
local workflow_codex = require("workflow_internal.codex")
local pr_child_handoff = require("departments.implement.pr_child_handoff")
local refusal_publication = require("departments.implement.refusal_publication")
local slice_gate = require("departments.implement.slice_gate")
local substrate_pin = require("departments.implement.substrate_pin")
local cache_preparation = require("departments.implement.cache_preparation")
local transitions = require("departments.implement.transitions")
local worktree_lifecycle = require("departments.implement.worktree")
local attempt_runner = require("departments.implement.attempt")
local branch_progress = require("departments.implement.branch_progress")
local result_checkpoint = require("departments.implement.result_checkpoint")
local dispatch_live_run = require("devloop.dispatch_live_run")
local config = require("devloop.config")
local fork_gate = require("departments.implement.fork_gate")
local m_mq = require("devloop.merge_queue")
local external_pr_bridge = require("departments.implement.external_pr_bridge")
local implement_caps = require("implement_department_caps")
local restart_sink_grants = require("restart_sink_grants")
local restart_policy = implement_caps.restart_policy

local dispatch_liveness = {
  restart_transition_table = function(...)
    return restart_policy.restart_transition_table(...)
  end,
  restart_row_receiver_liveness = function(...)
    return restart_policy.restart_row_receiver_liveness(...)
  end,
}

local payloads_predicates = require("devloop.payloads.predicates")
local v_ready = require("devloop.validators.ready")
local m_facts = require("devloop.markers.facts")
local entity_lib = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local devloop_commands = require("devloop.commands")
local MAX_IMPLEMENT_ATTEMPTS = 2
-- Single source of truth lives in core (implement_attempt.lua); the liveness anti-spin
-- (libraries/devloop/liveness/timeout.lua) reads the same constant so re-drive and
-- receiver agree on the budget.
local MAX_VERSION_MISMATCH_DELIVERIES = core.max_implement_version_mismatch_deliveries
local spec = {
  consumes = { "devloop_ready" },
  produces = {
    "github-proxy.github_issue_label_request",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_blocked_by_request",
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "10m",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

local function decide_implementation_transition(repo, issue_number, lock_key, state, expected_states, ready, phase, accepted_handoff)
  local intent = transitions.activation_intent(expected_states, ready.dedup_key, ready.operator_reentry, phase, accepted_handoff)
  if intent.semantic_variant == nil then
    error("github-devloop: restart-effect-variant-unsupported: implement activation source is not declared")
  end
  local current_version = state.version or (accepted_handoff and ready.dedup_key or nil)
  local snapshot = implement_caps.restart_effects.seal_snapshot({
    owner = implement_caps.restart_package_name,
    entity = { kind = "issue", repo = repo, number = issue_number },
    proposal_id = ready.proposal_id,
    current = { state = state.state, version = current_version },
    snapshot_fingerprint = table.concat({ "implement-activation", ready.proposal_id,
      state.state or "unmanaged", current_version or "unversioned", phase }, "|"),
    lock_epoch = lock_key .. "@" .. ready.dedup_key,
    generation = ready.dedup_key,
  })
  local decision = implement_caps.restart_effects.decide_transition(snapshot, intent)
  implement_caps.restart_effects.assert_decision_admissible(
    decision,
    "github-devloop: restart-effect-decision-illegal: implement activation rejected"
  )
  return snapshot, decision
end

local function raise_impl_failed(repo, issue_number, ready, reason, fault_class, retryable, detail, attempt)
  local comment_request = requests_lifecycle.build_impl_failure_comment_request(
    implement_caps.impl_failure_marker, implement_caps.output_language, repo, issue_number, ready, reason, detail, attempt, fault_class, retryable)
  local label_request = requests_labels.build_impl_failed_label_request(repo, issue_number, ready, reason)
  local add_labels, remove_labels = devloop_state.state_label_changes("impl-failed")
  devloop_logging.log_apply("implement", ready.proposal_id, "impl-failed", ready.dedup_key, { add = add_labels, remove = remove_labels }, {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  })
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_label_request", label_request)
end

local function raise_implementing_state(repo, issue_number, ready, worktree, branch, base_branch, base_sha, attempt, started_at, exec_ref, snapshot, decision)
  local comment_request, label_request
  if decision ~= nil then
    local grant = implement_caps.restart_effects.mint_grant(snapshot, decision, "comment:issue:implementation-start")
    local facade = implement_caps.restart_effect_facade.make({ family = "implement-activation",
      verify_grant = implement_caps.restart_effects.verify_grant, sink_inventory = implement_caps.sink_inventory })
    if grant == nil or type(facade.emit) ~= "function" then
      error("github-devloop: restart-effect-grant-invalid: implement activation grant or facade is unavailable")
    end
    local payloads, args = {}, { core = core, issue = { repo = repo, number = issue_number }, ready = ready,
      worktree = worktree, branch = branch, base_branch = base_branch, base_sha = base_sha,
      attempt = attempt, started_at = started_at, exec_ref = exec_ref }
    for _, effect_id in ipairs(decision.granted_effect_ids) do
      local payload, rejection = facade.emit(grant, effect_id, snapshot, args)
      if payload == nil then
        error("github-devloop: restart-effect-facade-rejected: implement activation effect "
          .. tostring(effect_id) .. " rejected: " .. tostring(rejection))
      end
      payloads[effect_id] = payload
    end
    comment_request = payloads["github-proxy.github_issue_comment_request"]
    label_request = payloads["github-proxy.github_issue_label_request"]
  else
    comment_request = requests_lifecycle.build_implementing_state_comment_request(implement_caps.implement_attempt_marker, implement_caps.output_language, repo, issue_number, ready, worktree, branch, base_branch, base_sha, attempt, started_at, exec_ref)
    label_request = requests_labels.build_implementing_label_request(repo, issue_number, ready)
  end
  local add_labels, remove_labels = devloop_state.state_label_changes("implementing")
  devloop_logging.log_apply("implement", ready.proposal_id, "implementing", ready.dedup_key, { add = add_labels, remove = remove_labels }, {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  })
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_label_request", label_request)
end

local function raise_implementing(repo, issue_number, ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref)
  local comment_request = requests_lifecycle.build_implementing_comment_request(implement_caps.implement_attempt_marker, implement_caps.output_language, repo, issue_number, ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref)
  devloop_logging.log_apply("implement", ready.proposal_id, "implementing", ready.dedup_key, { add = {}, remove = {} }, {
    "github-proxy.github_issue_comment_request",
  })
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
end

local function raise_implement_attempt(repo, issue_number, ready, attempt, started_at, exec_ref)
  local request = requests_lifecycle.build_implement_attempt_comment_request(implement_caps.implement_attempt_marker, repo, issue_number, ready, attempt, started_at, exec_ref)
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_comment_request", request)
end

local function publish_implementation_branch(repo, issue_number, ready, worktree, branch, authorization)
  if config.write_mode() ~= "real" then
    devloop_logging.log_line("info", "implement", ready.proposal_id, "OUTBOUND", {
      "mode=dry-run",
      "repo=" .. tostring(repo),
      "issue=" .. tostring(issue_number),
      "branch=" .. tostring(branch),
      "reason=would push implementation branch requires FKST_GITHUB_WRITE=1",
    })
    return
  end
  restart_sink_grants.consume(implement_caps, authorization, "git.push:implementation-branch",
    "github-devloop: implementation branch publish grant")
  local push = git_mechanics.git_push_worktree_branch_update(implement_caps.git_handle, worktree, branch, 120)
  if push.exit_code ~= 0 then
    error("github-devloop: branch-push-failed: git implementation branch push failed: " .. tostring(push.stderr))
  end
end

local function handoff_existing_pr_link(repo, issue_number, ready, current, link, reason)
  pr_child_handoff.raise_awaiting_pr_from_fact("implement", repo, issue_number, ready, current, {
    proposal_id = ready.proposal_id,
    dedup_key = ready.dedup_key,
    branch = link.branch,
    head_sha = nil,
    base_branch = link.base_branch,
  }, reason)
end

local function ready_for_implementation_version(ready, version)
  local copy = {}
  for key, value in pairs(ready or {}) do
    copy[key] = value
  end
  copy.dedup_key = version
  return copy
end


local function raise_implement_version_mismatch(repo, issue_number, ready, state, expected_version, attempt)
  local request = requests_lifecycle.build_implement_version_mismatch_comment_request(implement_caps.implement_version_mismatch_marker,
    repo,
    issue_number,
    ready,
    expected_version,
    state and state.version,
    attempt
  )
  devloop_logging.log_raise("implement", ready.proposal_id, "github-proxy.github_issue_comment_request", request)
end

local function handle_implementing_version_mismatch(repo, issue_number, current, ready, state, expected_version)
  local prior_attempts = core.implement_version_mismatch_attempt_count(
    current and current.comments,
    ready.proposal_id,
    expected_version,
    state and state.version
  )
  local attempt = prior_attempts + 1
  local message = "ready event does not match current implementing version"
  if attempt < MAX_VERSION_MISMATCH_DELIVERIES then
    devloop_logging.log_error_fact("warn", "implement", ready.proposal_id, "STALE_VERSION_MISMATCH", "stale-version-mismatch", "devloop_ready", message, {
      source_ref = ready.source_ref,
      attempt = attempt,
      terminal = false,
    })
    devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "skip-stale(version-mismatch)", message)
    -- Persist the attempt marker so the mismatch budget still accrues across
    -- redeliveries, then return cleanly. Raising here dead-letters the whole
    -- pipeline dispatch (wrap_pipeline_failure re-raises), which crash-loops the
    -- queue and starves every sibling implement (#2908).
    raise_implement_version_mismatch(repo, issue_number, ready, state, expected_version, attempt)
    return
  end
  devloop_logging.log_error_fact("error", "implement", ready.proposal_id, "STALE_VERSION_MISMATCH", "stale-version-mismatch", "devloop_ready", message, {
    source_ref = ready.source_ref,
    attempt = attempt,
    terminal = true,
  })
  devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "fail-closed(version-mismatch-budget)", message)
  -- Budget exhausted: drop the diverged trigger permanently (#718 / #373) without
  -- a fatal error. Authoritative state still governs; the liveness sweep redrives
  -- from the current marker when that state is genuinely stuck.
  return
end

local function implementing_mismatch_is_durable(current, proposal_id, state)
  local version = state and state.version
  return core.latest_implement_attempt_fact(current and current.comments, proposal_id, version) ~= nil
    or m_facts.implementing_fact(current and current.comments, proposal_id, version) ~= nil
end

local function prepare_attempt(repo, issue_number, ready, branches, branch, base_head, attempt, bridge_marker, checkpoint, completed_result, receiver_state, snapshot, decision, lock_key)
  local worktree = bridge_marker ~= nil and completed_result == nil
    and worktree_lifecycle.prepare_worktree_from_base(repo, issue_number, ready, branch, base_head)
    or worktree_lifecycle.prepare_worktree(repo, issue_number, ready, branch, base_head, checkpoint)
  local codex_started_at, exec_ref = now(), core.implement_exec_ref(ready.proposal_id, ready.dedup_key)
  local merge_clean = worktree_lifecycle.merge_integration(
    implement_caps.git_handle, worktree, branches.integration, base_head)
  completed_result = completed_result ~= nil and merge_clean
    and result_checkpoint.reseal(implement_caps.git_handle, worktree, completed_result, ready.dedup_key) or nil
  if completed_result ~= nil then return worktree, codex_started_at, exec_ref, nil, completed_result end
  merge_clean = external_pr_bridge.provision(worktree, bridge_marker, ready.proposal_id) and merge_clean
  substrate_pin.refresh(worktree, branch, base_head, merge_clean)
  cache_preparation.run(worktree)

  raise_implementing_state(repo, issue_number, ready, worktree, branch, branches.integration,
    base_head, attempt, codex_started_at, exec_ref, snapshot, decision)
  local receiver_authorization = restart_sink_grants.implement_receiver(implement_caps, {
    repo = repo, issue_number = issue_number, ready = ready,
    receiver_state = receiver_state, lock_key = lock_key,
  })
  return worktree, codex_started_at, exec_ref, receiver_authorization, completed_result
end

local function run_attempt(repo, issue_number, ready, current, branches, branch, base_head, worktree,
    codex_started_at, exec_ref, receiver_authorization, attempt, event_ts, event_queue, completed_result)
  local args = {
    repo = repo,
    issue_number = issue_number,
    ready = ready,
    current = current,
    branches = branches,
    branch = branch,
    base_head = base_head,
    worktree = worktree,
    codex_started_at = codex_started_at,
    exec_ref = exec_ref,
    receiver_authorization = receiver_authorization,
    attempt = attempt,
    event_ts = event_ts,
    event_queue = event_queue,
    context_fetch = function(args)
      return context_bundle.context_fetch_from_bundle(args)
    end,
    codex_dispatch = function(identity, opts)
      return workflow_codex.dispatch(identity, opts)
    end,
    codex_identity = convergence_identity.from_parts("implement", ready.proposal_id, ready.dedup_key, {
      angle_lane = "worker",
    }),
  }
  if completed_result ~= nil then args.head_sha = completed_result.head_sha end
  if completed_result ~= nil then return attempt_runner.resume(args) end
  return attempt_runner.run(args)
end

local function raise_attempt_outcome(repo, issue_number, outcome, publish_authorization)
  if outcome == nil then
    return
  end
  if outcome.kind == "worktree-missing" or outcome.kind == "worktree-unregistered" then
    local error_class = outcome.kind == "worktree-missing" and "WORKTREE_MISSING" or "WORKTREE_UNREGISTERED"
    devloop_logging.log_error_fact("warn", "implement", outcome.ready.proposal_id,
      "WORKTREE_UNAVAILABLE", error_class, "devloop_ready",
      "implementation worktree is unavailable during harvest: " .. tostring(outcome.reason), {
        source_ref = outcome.ready.source_ref,
        attempt = outcome.attempt,
        terminal = false,
        worktree = outcome.worktree,
      })
    return
  end
  raise_implement_attempt(repo, issue_number, outcome.ready, outcome.attempt, outcome.started_at, outcome.exec_ref)
  if outcome.kind == "implementing" then
    publish_implementation_branch(repo, issue_number, outcome.ready, outcome.worktree, outcome.branch, publish_authorization)
    raise_implementing(
      repo,
      issue_number,
      outcome.ready,
      outcome.worktree,
      outcome.branch,
      outcome.head_sha,
      outcome.base_branch,
      outcome.base_sha,
      outcome.attempt,
      outcome.started_at,
      outcome.exec_ref
    )
    pr_child_handoff.raise_awaiting_pr_from_fact(
      "implement",
      repo,
      issue_number,
      outcome.ready,
      { title = nil, comments = {} },
      {
        branch = outcome.branch,
        head_sha = outcome.head_sha,
        base_branch = outcome.base_branch,
      },
      "implementation output published; waiting for visible delegated PR child"
    )
    return
  end
  if outcome.kind == "implement-checkpoint" then
    publish_implementation_branch(repo, issue_number, outcome.ready, outcome.worktree, outcome.branch, publish_authorization)
    local request = requests_lifecycle.build_implement_checkpoint_comment_request(
      implement_caps.implement_attempt_marker, implement_caps.output_language,
      repo,
      issue_number,
      outcome.ready,
      outcome.worktree,
      outcome.branch,
      outcome.head_sha,
      outcome.base_branch,
      outcome.base_sha,
      outcome.attempt,
      outcome.started_at,
      outcome.exec_ref,
      outcome.detail,
      outcome.reason
    )
    devloop_logging.log_raise("implement", outcome.ready.proposal_id, "github-proxy.github_issue_comment_request", request)
    return
  end
  if outcome.kind == "impl-failed" then
    raise_impl_failed(repo, issue_number, outcome.ready, outcome.reason, outcome.fault_class,
      outcome.retryable, outcome.detail, outcome.attempt)
    return
  end
  if outcome.kind == "implementation-refusal" then
    refusal_publication.publish(core, repo, issue_number, outcome)
    return
  end
  error("github-devloop: invalid-implementation-outcome: unknown implementation outcome")
end

local function recheck_implementation_write_gate(repo, issue_number, lock_key, marker_ready, expected_from_states, accepted_ready_hand_off, allow_same_version_implementing)
  local view = devloop_commands.gh_issue_view_implement(repo, issue_number, 30)
  if view.exit_code ~= 0 then
    error("github-devloop: issue-recheck-failed: gh issue implement recheck failed: " .. tostring(view.stderr))
  end
  local current = parsers_issue.parse_issue_view_implement(view.stdout)
  devloop_logging.log_forged_markers("implement", marker_ready.proposal_id, current.comments)
  local state = devloop_state.current_state(current.comments, marker_ready.proposal_id)
  local receiver_state = { state = "implementing", version = marker_ready.dedup_key }
  if state.state == "implementing"
    and tostring(state.version or "") == tostring(marker_ready.dedup_key or "") then
    local link = m_facts.pr_link_fact(current.comments, marker_ready.proposal_id)
    if link ~= nil and tostring(link.impl_version or "") == tostring(marker_ready.dedup_key) then
      handoff_existing_pr_link(repo, issue_number, marker_ready, current, link, "linked PR fact is already visible")
      return false
    end
    local fact = m_facts.implementing_fact(current.comments, marker_ready.proposal_id, marker_ready.dedup_key)
    if fact ~= nil then
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "implementing", "implementing", "skip-idempotent(implementation marker already visible)", "implementation fact marker already visible")
      return false
    end
    if not transitions.expected_states_include(expected_from_states, "implementing") and not allow_same_version_implementing then
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "ready", "implementing", "skip-idempotent(already at to_state)", "implementation state marker already visible")
      return false
    end
    return true, receiver_state, current
  end
  if state.state == "impl-failed" and tostring(state.version or "") == tostring(marker_ready.dedup_key or "") then
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "implementing", "impl-failed", "skip-idempotent(already failed)", "implementation failure marker already visible")
    return false
  end
  local structural_match = false
  for _, expected in ipairs(expected_from_states or {}) do
    if transitions.expected_state_matches(state, expected) then
      if (type(expected) == "table" and expected.state or expected) == "implementing" then return true, receiver_state, current end
      structural_match = true
    end
  end
  local accepted_handoff = payloads_predicates.is_ready_hand_off(accepted_ready_hand_off, marker_ready)
  local _, decision = decide_implementation_transition(repo, issue_number, lock_key, state,
    expected_from_states or { "ready" }, marker_ready, "recheck", accepted_handoff)
  if decision.status ~= "apply" then
    if decision.status == "pending" and accepted_handoff then
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, {
        state = "ready",
        version = marker_ready.dedup_key,
        stage_rank = devloop_state.stage_rank("ready"),
      }, "ready", "implementing", "apply(own-ready-hand-off)", "write-time ready hand-off still matches this generation")
      return true, receiver_state, current
    end
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "ready", "implementing", decision.cas_outcome, "write-time issue state changed")
    return false
  end
  if accepted_handoff and not structural_match then
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, {
      state = "ready", version = marker_ready.dedup_key, stage_rank = devloop_state.stage_rank("ready"),
    }, "ready", "implementing",
      "apply(own-ready-hand-off)", "write-time ready hand-off still matches this generation")
  end
  return true, receiver_state, current
end

local function precheck_implementation_write_gate(repo, issue_number, lock_key, marker_ready, expected_from_states, accepted_ready_hand_off)
  local view = devloop_commands.gh_issue_view_implement(repo, issue_number, 30)
  if view.exit_code ~= 0 then
    error("github-devloop: issue-recheck-failed: gh issue implement recheck failed: " .. tostring(view.stderr))
  end
  local current = parsers_issue.parse_issue_view_implement(view.stdout)
  devloop_logging.log_forged_markers("implement", marker_ready.proposal_id, current.comments)
  local state = devloop_state.current_state(current.comments, marker_ready.proposal_id)
  if state.state == "implementing"
    and tostring(state.version or "") == tostring(marker_ready.dedup_key or "") then
    local link = m_facts.pr_link_fact(current.comments, marker_ready.proposal_id)
    if link ~= nil and tostring(link.impl_version or "") == tostring(marker_ready.dedup_key) then
      handoff_existing_pr_link(repo, issue_number, marker_ready, current, link, "linked PR fact is already visible")
      return nil
    end
    if not transitions.expected_states_include(expected_from_states, "implementing") then
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "ready", "implementing", "skip-idempotent(already at to_state)", "implementation state marker already visible")
      return nil
    end
    return state, current
  end
  if state.state == "impl-failed" and tostring(state.version or "") == tostring(marker_ready.dedup_key or "") then
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "implementing", "impl-failed", "skip-idempotent(already failed)", "implementation failure marker already visible")
    return nil
  end
  for _, expected in ipairs(expected_from_states or {}) do
    if transitions.expected_state_matches(state, expected)
      and (type(expected) == "table" and expected.state or expected) == "implementing" then
      return state, current
    end
  end
  local accepted_handoff = payloads_predicates.is_ready_hand_off(accepted_ready_hand_off, marker_ready)
  local snapshot, decision = decide_implementation_transition(repo, issue_number, lock_key, state,
    expected_from_states or { "ready" }, marker_ready, "recheck", accepted_handoff)
  if decision.status ~= "apply" then
    if decision.status == "pending" and accepted_handoff then
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, {
        state = "ready",
        version = marker_ready.dedup_key,
        stage_rank = devloop_state.stage_rank("ready"),
      }, "ready", "implementing", "apply(own-ready-hand-off)", "pre-spawn ready hand-off still matches this generation")
      return {
        state = "ready",
        version = marker_ready.dedup_key,
        stage_rank = devloop_state.stage_rank("ready"),
      }, current, snapshot, decision
    end
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "ready", "implementing",
      decision.cas_outcome, "pre-spawn issue state changed")
    return nil
  end
  if accepted_handoff and state.state ~= "ready" then
    state = { state = "ready", version = marker_ready.dedup_key,
      stage_rank = devloop_state.stage_rank("ready") }
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, state, "ready", "implementing",
      "apply(own-ready-hand-off)", "pre-spawn ready hand-off still matches this generation")
  end
  return state, current, snapshot, decision
end

local function checkpoint_matches_progress(checkpoint, progress)
  return checkpoint ~= nil
    and progress ~= nil
    and checkpoint.branch == progress.branch
    and checkpoint.head_sha == progress.head_sha
end

local function process_ready_event(event)
  local ready = event.payload or {}
  if not v_ready.is_supported_ready(ready) then
    devloop_logging.log_entry("implement", event, "unknown", devloop_logging.payload_field(ready, "dedup_key"))
    devloop_logging.log_cas_decision("implement", "unknown", { state = nil, version = nil }, "ready", "implementing", "skip-foreign(proposal_id)", "unsupported event payload")
    return
  end

  local delivery_dedup_key = ready.dedup_key
  if ready.implementation_version ~= nil then
    local logical = {}
    for key, value in pairs(ready) do
      logical[key] = value
    end
    logical.dedup_key = ready.implementation_version
    logical.implementation_version = nil
    logical.redrive_delivery = nil
    logical.operator_reimplement_delivery = nil
    ready = logical
  end
  devloop_logging.log_entry("implement", event, ready.proposal_id, delivery_dedup_key)
  local repo, issue_number = base_ids.parse_proposal_id(ready.proposal_id)
  if repo == nil then
    devloop_logging.log_cas_decision("implement", ready.proposal_id, { state = nil, version = nil }, "ready", "implementing", "skip-foreign(proposal_id)", "proposal_id is outside github-devloop")
    return
  end

  local lock_key = entity_lib.implement_lock_key(ready.proposal_id)
  if lock_key == nil then
    devloop_logging.log_cas_decision("implement", ready.proposal_id, { state = nil, version = nil }, "ready", "implementing", "skip-foreign(proposal_id)", "no transition lock key")
    return
  end

  local attempt_plan = nil
  with_lock(lock_key, function()
    parsers_misc.assert_trusted_bot_configured()

    local view = devloop_commands.gh_issue_view_implement(repo, issue_number, 30)
    if view.exit_code ~= 0 then
      error("github-devloop: issue-read-failed: gh issue implement view failed: " .. tostring(view.stderr))
    end

    local current = parsers_issue.parse_issue_view_implement(view.stdout)
    current.repo = repo
    current.number = issue_number
    local managed = m_claims.managed_bot_logins()
    devloop_logging.log_forged_markers("implement", ready.proposal_id, current.comments)
    if tostring(current.state or ""):upper() ~= "OPEN" then
      devloop_logging.log_cas_decision("implement", ready.proposal_id, { state = nil, version = ready.dedup_key }, "ready", "implementing", "skip-stale(original-closed)", "current issue is not open")
      return
    end
    if slice_gate.check(repo, issue_number, ready, current) then
      return
    end
    if fork_gate.check(repo, issue_number, ready, current, managed) then
      return
    end
    local state = devloop_state.current_state(current.comments, ready.proposal_id)
    -- The dependency gate is a ready-phase entry precondition. A redelivered ready
    -- event past that phase can emit a newer ready-split marker whose version-first
    -- ordering regresses the lifecycle without a generation bump.
    if state == nil or state.state == nil or devloop_state.stage_rank(state.state) <= devloop_state.stage_rank("ready") then
      local gate = core.dependency_gate(repo, issue_number, {
        proposal_id = ready.proposal_id,
        version = core.ready_payload_inner_version(ready.dedup_key),
        comments = current.comments,
      })
      if not dependency_gate.dependency_gate_is_satisfied(gate) then
        local inner_ready_version = core.ready_payload_inner_version(ready.dedup_key)
        local dep_version = core.ready_split_version(inner_ready_version)
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "dependency_wait", "hold-dependency-backstop", gate.reason)
        core.raise_ready_split_effects("implement", {
          repo = repo,
          number = issue_number,
          source_ref = ready.source_ref,
        }, ready.proposal_id, inner_ready_version, "dependency_wait", dep_version, gate,
          base_ids.dedup_key({ "dependency", "label", "hold", tostring(ready.proposal_id), tostring(dep_version), tostring(gate.hold_kind) }))
        return
      end
    end

    local branches = config.branch_config()
    local lineage_ok, implementation_version, branch_version = pcall(function()
      return core.implementation_attempt_version(ready.dedup_key, ready.impl_retry_attempt),
        core.implementation_branch_version(ready.dedup_key, ready.impl_retry_attempt)
    end)
    if not lineage_ok then
      local lineage_error = tostring(implementation_version)
      if not lineage_error:find("github-devloop: invalid-version-lineage:", 1, true) then
        error(implementation_version, 0)
      end
      devloop_logging.log_error_fact("error", "implement", ready.proposal_id, "INVALID_VERSION_LINEAGE",
        "invalid-version-lineage", "devloop_ready", lineage_error, {
          source_ref = ready.source_ref,
          attempt = ready.impl_retry_attempt,
          terminal = true,
        })
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "impl-failed",
        "fail-closed(invalid-version-lineage)", "implementation retry lineage is malformed")
      raise_impl_failed(repo, issue_number, ready, "invalid-version-lineage", "UNKNOWN", false,
        "Implementation retry lineage was rejected because its version suffix does not match the current or immediate-next structured attempt.",
        ready.impl_retry_attempt)
      return
    end
    local marker_ready = ready_for_implementation_version(ready, implementation_version)
    local branch = devloop_base.implement_branch(repo, issue_number, branch_version)

    if state.state == "implementing" then
      if tostring(state.version or "") ~= tostring(marker_ready.dedup_key or "") then
        if not implementing_mismatch_is_durable(current, ready.proposal_id, state) then
          devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "skip-stale(version-mismatch)", "implementing state marker has no durable progress fact")
          return
        end
        handle_implementing_version_mismatch(repo, issue_number, current, ready, state, marker_ready.dedup_key)
        return
      end
      local link = m_facts.pr_link_fact(current.comments, ready.proposal_id)
      if link ~= nil and tostring(link.impl_version or "") == tostring(marker_ready.dedup_key) then
        handoff_existing_pr_link(repo, issue_number, marker_ready, current, link, "linked PR fact is already visible")
        return
      end
      local fact = m_facts.implementing_fact(current.comments, ready.proposal_id, marker_ready.dedup_key)
      if fact == nil and dispatch_live_run.dispatch_live_run_dedup(dispatch_liveness, "implement", ready.proposal_id, marker_ready.dedup_key, {
        state = state,
        proposal_id = ready.proposal_id,
        current = current,
        now_seconds = now(),
      }) then
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "skip-idempotent(already at to_state)", "implementation attempt heartbeat is still live")
        return
      end
      local progress, completed_result = nil, nil
      local checkpoint = fact == nil and m_facts.implement_checkpoint_fact(current.comments, ready.proposal_id, marker_ready.dedup_key) or nil
      local resume_checkpoint = checkpoint
      if fact ~= nil then
        progress = branch_progress.remote_branch_fact(implement_caps.git_handle, fact.branch, fact.base_branch, fact)
      else
        progress = branch_progress.remote_branch_fact(implement_caps.git_handle, branch, branches.integration, {
          proposal_id = ready.proposal_id,
          dedup_key = marker_ready.dedup_key,
        })
      end
      if progress ~= nil then
        if fact ~= nil then
          progress.proposal_id = ready.proposal_id
          progress.dedup_key = marker_ready.dedup_key
          pr_child_handoff.raise_awaiting_pr_from_fact("implement", repo, issue_number, marker_ready, current, progress, "implementing remote branch progress is visible")
          return
        elseif result_checkpoint.rehydrate(implement_caps.git_handle, progress, marker_ready.dedup_key) ~= nil then
          completed_result = progress
          resume_checkpoint = progress
          devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "implementing", "resume-completed-result(remote-progress)", "version-bound implementation result is durable; resuming harvest")
        elseif checkpoint_matches_progress(checkpoint, progress) then
          resume_checkpoint = checkpoint
          devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "implementing", "skip-wip-checkpoint(remote-progress)", "remote branch progress is a WIP checkpoint; retrying implementation attempt")
        else
          resume_checkpoint = progress
          devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "implementing", "skip-unmarked-progress(remote-progress)", "remote branch progress has no durable implementing fact; retrying implementation attempt")
        end
      end
      local base_head = worktree_lifecycle.prepare_base(branches)
      local local_progress = nil
      if resume_checkpoint == nil then
        local_progress = branch_progress.local_branch_fact(base_head, branch, branches.integration, marker_ready.dedup_key)
        if local_progress ~= nil then
          if fact ~= nil then
            local_progress.proposal_id = ready.proposal_id
            pr_child_handoff.raise_awaiting_pr_from_fact("implement", repo, issue_number, marker_ready, current, local_progress, "local implementation branch progress is visible")
            return
          end
          completed_result = result_checkpoint.rehydrate(implement_caps.git_handle, local_progress, marker_ready.dedup_key)
          local decision = completed_result ~= nil and "resume-completed-result(local-progress)" or "skip-unmarked-progress(local-progress)"
          local reason = completed_result ~= nil and "version-bound implementation result is durable; resuming harvest" or "local branch progress has no durable implementing fact; retrying implementation attempt"
          devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "implementing", decision, reason)
        end
      end
      local has_recoverable_progress = progress ~= nil or local_progress ~= nil
      local attempts = core.implement_attempt_count(current.comments, ready.proposal_id, marker_ready.dedup_key)
      if attempts >= MAX_IMPLEMENT_ATTEMPTS and not has_recoverable_progress then
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "impl-failed", "applied(attempts-exhausted)", "implementation attempts exhausted with no PR or branch progress")
        raise_impl_failed(repo, issue_number, marker_ready, "retry-exhausted", "UNKNOWN", false,
          "No linked PR, remote branch, or local branch progress was visible after "
            .. tostring(attempts) .. " attempts.", attempts)
        return
      end
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "implementing", "implementing",
        has_recoverable_progress and "applied(retry-progress)" or "applied(retry-no-progress)",
        has_recoverable_progress and "recoverable branch progress is visible; retrying implementation attempt"
          or "no PR or branch progress is visible; retrying implementation attempt")
      attempt_plan = {
        marker_ready = marker_ready,
        current = current,
        branches = branches,
        branch = branch,
        base_head = base_head,
        attempt = completed_result ~= nil and math.max(attempts, 1) or attempts + 1,
        expected_from_states = { "implementing" },
        bridge_marker = external_pr_bridge.detect(current, repo, managed),
        checkpoint = resume_checkpoint,
        completed_result = completed_result,
      }
      return
    end

    local retry_failure = nil
    local blocked_reentry = false
    if state.state == "impl-failed" and ready.impl_retry_attempt ~= nil and state.version == ready.dedup_key then
      retry_failure = core.impl_failure_fact(current.comments, ready.proposal_id, ready.dedup_key)
      if retry_failure ~= nil
        and tonumber(ready.impl_retry_attempt) ~= core.next_implementation_retry_attempt(state.version) then
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "impl-failed", "implementing", "skip-idempotent(retry-not-advanced)", "implementation retry event does not advance the lifecycle lineage")
        return
      end
    elseif state.state == "blocked" and ready.impl_retry_attempt ~= nil
      and transitions.operator_blocked_reimplement_allowed(core, ready, current, state) then
      blocked_reentry = true
    elseif state.state == "implementing" or state.state == "impl-failed" then
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "skip-idempotent(already at to_state)", "implementation fact marker already visible")
      return
    end
    local expected_states = blocked_reentry
      and { { state = "blocked", version = ready.operator_reentry.state_version, target_version = ready.dedup_key } }
      or (retry_failure ~= nil and { "impl-failed" } or { "ready" })
    local _, decision = decide_implementation_transition(repo, issue_number, lock_key, state,
      expected_states, marker_ready, "initial", false)
    local transition = decision.status
    if transition == "idempotent" or transition == "stale" then
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing",
        decision.cas_outcome, "ready event cannot advance current marker")
      return
    end
    local accepted_ready_hand_off = nil
    if transition == "pending" then
      local verified_state = nil
      local hand_off_reason = "missing"
      if ready.ready_hand_off ~= nil then
        verified_state, hand_off_reason = payloads_predicates.verified_hand_off_state(repo, ready.ready_hand_off, {
          proposal_id = ready.proposal_id,
          state = "ready",
          marker_version = ready.ready_hand_off.marker_version,
          event_version = ready.dedup_key,
        })
      end
      if retry_failure == nil and ready.impl_retry_attempt == nil and verified_state ~= nil then
        state = verified_state
        accepted_ready_hand_off = ready.ready_hand_off
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "apply(verified-own-ready-hand-off)", "ready marker comment verified by direct id lookup")
      else
        devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing",
          decision.cas_outcome, "ready state marker not yet visible")
        if ready.ready_hand_off ~= nil then
          devloop_logging.log_line("info", "implement", ready.proposal_id, "HANDOFF", {
            "state=ready",
            "outcome=verify-failed",
            "reason=" .. tostring(hand_off_reason),
          })
        end
        error("github-devloop: state-marker-pending: ready state marker not yet visible for implement; retrying")
      end
    else
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing",
        decision.cas_outcome, "ready marker visible; attempting implementation")
    end

    local wip_ok, wip_reason, wip_count, wip_max = m_mq.wip_capacity_allows_start(repo, issue_number)
    if not wip_ok then
      devloop_logging.log_cas_decision("implement", ready.proposal_id, state, "ready", "implementing", "hold-wip-cap", wip_reason .. ": " .. tostring(wip_count) .. "/" .. tostring(wip_max))
      return
    end

    local issue_slug = devloop_base.safe_issue_slug(repo, issue_number)
    devloop_logging.log_line("info", "implement", ready.proposal_id, "IMPLEMENT", {
      "issue_slug=" .. tostring(issue_slug),
      "branch=" .. tostring(branch),
      "reason=implementation fact marker absent for this version",
    })

    attempt_plan = {
      marker_ready = marker_ready,
      current = current,
      branches = branches,
      branch = branch,
      attempt = ready.impl_retry_attempt or 1,
      expected_from_states = expected_states,
      accepted_ready_hand_off = accepted_ready_hand_off,
      bridge_marker = external_pr_bridge.detect(current, repo, managed),
    }
  end)
  if attempt_plan == nil then
    return
  end

  local worktree, codex_started_at, exec_ref, receiver_authorization
  with_lock(lock_key, function()
    local pre_spawn_state, pre_spawn_current, activation_snapshot, activation_decision = precheck_implementation_write_gate(
      repo,
      issue_number,
      lock_key,
      attempt_plan.marker_ready,
      attempt_plan.expected_from_states,
      attempt_plan.accepted_ready_hand_off
    )
    if pre_spawn_state ~= nil then
      if dispatch_live_run.dispatch_live_run_dedup(dispatch_liveness, "implement", attempt_plan.marker_ready.proposal_id, attempt_plan.marker_ready.dedup_key, {
        state = pre_spawn_state,
        current = pre_spawn_current,
        proposal_id = attempt_plan.marker_ready.proposal_id,
        now_seconds = now(),
      }) then
        devloop_logging.log_cas_decision(
          "implement",
          attempt_plan.marker_ready.proposal_id,
          { state = "ready", version = attempt_plan.marker_ready.dedup_key, stage_rank = devloop_state.stage_rank("ready") },
          "ready",
          "implementing",
          "skip-idempotent(live-exec-ref)",
          "matching implementation codex run is still live"
        )
        return
      end
      if attempt_plan.base_head == nil then
        attempt_plan.base_head = worktree_lifecycle.prepare_base(attempt_plan.branches)
      end
      worktree, codex_started_at, exec_ref, receiver_authorization, attempt_plan.completed_result = prepare_attempt(
        repo, issue_number, attempt_plan.marker_ready, attempt_plan.branches,
        attempt_plan.branch, attempt_plan.base_head, attempt_plan.attempt,
        attempt_plan.bridge_marker, attempt_plan.checkpoint, attempt_plan.completed_result, pre_spawn_state,
        activation_snapshot, activation_decision, lock_key)
    end
  end)
  if worktree == nil then
    return
  end

  local outcome = run_attempt(repo, issue_number, attempt_plan.marker_ready,
    attempt_plan.current, attempt_plan.branches, attempt_plan.branch,
    attempt_plan.base_head, worktree, codex_started_at, exec_ref,
    receiver_authorization, attempt_plan.attempt, event.ts, event.queue,
    attempt_plan.completed_result)
  if outcome == nil then return end
  with_lock(lock_key, function()
    local write_gate_ok, publish_state, publish_current = recheck_implementation_write_gate(repo, issue_number, lock_key,
      attempt_plan.marker_ready, attempt_plan.expected_from_states, attempt_plan.accepted_ready_hand_off, true)
    if write_gate_ok then
      outcome = attempt_runner.bound_verification_checkpoint(outcome, publish_current.comments)
      local publish_authorization = nil
      if outcome.kind == "implementing" or outcome.kind == "implement-checkpoint" then
        publish_authorization = restart_sink_grants.implementation_publish(implement_caps, {
          repo = repo, issue_number = issue_number, ready = attempt_plan.marker_ready,
          publish_state = publish_state, outcome_kind = outcome.kind, lock_key = lock_key,
        })
      end
      raise_attempt_outcome(repo, issue_number, outcome, publish_authorization)
    end
  end)
end

local function act_implement(event)
  queue.dispatch_consumed_queue("implement", spec, event, {
    devloop_ready = process_ready_event,
  })
end

return saga.department(spec, {
  done = function() return false end,
  act = act_implement,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "implement",
})
