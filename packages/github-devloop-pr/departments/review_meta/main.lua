local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local strings = require("contract.strings")
local m_claims = require("devloop.claims")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local m_facts = require("devloop.markers.facts")
local core, saga, context_bundle = require("core"), require("workflow.saga"), require("devloop.context_bundle")
local v_review_meta = require("devloop.validators.review_meta")
local convergence_identity = require("contract.convergence_identity")
local workflow_codex = require("workflow_internal.codex")
local dispatch_live_run = require("devloop.dispatch_live_run")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local devloop_commands = require("devloop.commands")
local review_meta_caps = require("review_meta_department_caps").production()

local dispatch_liveness = {
  restart_transition_table = function(...)
    return core.restart_transition_table(...)
  end,
  restart_row_receiver_liveness = function(...)
    return core.restart_row_receiver_liveness(...)
  end,
}

-- Preserve existing body line coordinates for the coverage ratchet.

local spec = {
  consumes = { "devloop_review_meta" },
  produces = {
    "github-proxy.github_issue_label_request",
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "2m",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

local function load_review_meta_context(repo, issue_number, review_meta, event, current_pr, current_issue, state)
  local durable_start_marker = "state:v1 review-meta"
  if not devloop_state.has_state_marker(current_pr.comments, review_meta.proposal_id, "review-meta", review_meta.version) then
    error("github-devloop: review-meta-marker-missing: " .. durable_start_marker .. " marker not visible during context load")
  end
  local content_fetch = context_bundle.context_fetch_from_bundle(core, {
    dept = "review_meta",
    repo = repo,
    issue_number = issue_number,
    pr_number = review_meta.pr_number,
    proposal_id = review_meta.proposal_id,
    version = review_meta.dedup_key,
    tick = event.ts,
  })
  return {
    repo = repo,
    issue_number = issue_number,
    review_meta = review_meta,
    current_pr = current_pr,
    current_issue = current_issue,
    state = state,
    content_fetch = content_fetch,
    event_queue = event.queue,
  }
end

local function review_meta_codex_decision(plan)
  devloop_logging.log_cas_decision("review_meta", plan.review_meta.proposal_id, plan.state, "review-meta", "fixing|blocked", "applied", "running review-meta codex decision")
  devloop_logging.log_codex_start("review_meta", plan.review_meta.proposal_id, "review-meta")
  local codex_opts = workflow_codex.judgment_codex_opts(
    core.build_review_meta_prompt(plan.review_meta, plan.current_issue, plan.content_fetch),
    devloop_base.judgment_worktree_with_exec(exec_sync, "review-meta", plan.review_meta.dedup_key)
  )
  codex_opts.sync = true
  local result = workflow_codex.dispatch(convergence_identity.from_parts("review-meta", plan.review_meta.proposal_id, plan.review_meta.version, {
    angle_lane = "worker",
  }), codex_opts)
  if type(result) == "table" and result.deferred then
    devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, "result=deferred", nil)
    return nil
  end
  if type(result) ~= "table" or result.exit_code ~= 0 or result.stdout == nil then
    local stderr = type(result) == "table" and result.stderr or "nil result"
    devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, nil, stderr, {
      queue = plan.event_queue,
      source_ref = plan.review_meta.source_ref,
      terminal = false,
    })
    error("github-devloop: review-meta-codex-failed: review-meta codex failed: " .. tostring(stderr))
  end
  local parsed = core.parse_review_meta_action(result.stdout)
  if parsed == nil then
    devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, nil, "parse-failed", {
      queue = plan.event_queue,
      source_ref = plan.review_meta.source_ref,
      terminal = false,
    })
    parsed = {
      action = "block",
      reason = "Review-meta codex output was unparseable.",
    }
  end
  local is_reflection = plan.review_meta.mode == "fix-reflection"
  local allowed_action = false
  if is_reflection then
    allowed_action = parsed.action == "continue" or parsed.action == "spec-gap"
  else
    allowed_action = parsed.action == "fix" or parsed.action == "block" or parsed.action == "spec-amendment"
  end
  if not allowed_action then
    devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, nil, "invalid-action-for-mode")
    parsed = {
      action = is_reflection and "spec-gap" or "block",
      reason = "Review-meta codex output used an action outside this decision mode.",
    }
  end
  if parsed.action == "fix"
    and not strings.is_bounded_string(parsed.blocking_gap, devloop_base._max_blocking_gap_len) then
    devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, nil, "missing-blocking-gap")
    parsed = {
      action = "block",
      reason = "Review-meta fix output omitted a bounded blocking gap.",
    }
  end
  devloop_logging.log_codex_result("review_meta", plan.review_meta.proposal_id, "review-meta", result, "action=" .. tostring(parsed.action) .. " reason=" .. tostring(parsed.reason), nil)
  return parsed
end

local function apply_review_meta_decision(plan, parsed, restart_effect)
  local review_meta = plan.review_meta
  local to_state = (parsed.action == "fix" or parsed.action == "continue") and "fixing" or "blocked"
  local exit_version = devloop_state.next_review_meta_action_version(review_meta.version)
  local args = {
    core = core,
    repo = plan.repo,
    issue_number = plan.issue_number,
    review_meta = review_meta,
    action = parsed.action,
    reason = parsed.reason,
    version = exit_version,
    blocking_gap = parsed.blocking_gap,
  }
  local effects = {}
  local raised = {}
  for _, effect_id in ipairs(restart_effect.decision.granted_effect_ids) do
    if effect_id ~= "github-proxy.github_issue_label_request" or plan.issue_number ~= nil then
      local payload, rejection = restart_effect.facade.emit(
        restart_effect.grant,
        effect_id,
        restart_effect.snapshot,
        args
      )
      if payload == nil then
        error("github-devloop: restart-effect-facade-rejected: PR review-meta effect "
          .. tostring(effect_id) .. " rejected: " .. tostring(rejection))
      end
      table.insert(effects, { queue = effect_id, payload = payload })
      table.insert(raised, effect_id)
    end
  end

  local add_labels, remove_labels = devloop_state.state_label_changes(to_state)
  devloop_logging.log_apply("review_meta", review_meta.proposal_id, to_state, exit_version, {
    add = add_labels,
    remove = remove_labels,
  }, raised)
  for _, effect in ipairs(effects) do
    devloop_logging.log_raise("review_meta", review_meta.proposal_id, effect.queue, effect.payload)
  end
end

return saga.department(spec, { done = function() return false end, act = function(event)
  local review_meta = event.payload or {}
  if not v_review_meta.is_supported_review_meta(review_meta) then
    devloop_logging.log_entry("review_meta", event, "unknown", devloop_logging.payload_field(review_meta, "dedup_key"))
    devloop_logging.log_cas_decision("review_meta", "unknown", { state = nil, version = nil }, "review-meta", "fixing|blocked", "skip-foreign(payload)", "unsupported event payload")
    return
  end

  devloop_logging.log_entry("review_meta", event, review_meta.proposal_id, review_meta.dedup_key)
  local entity = entity_lib.parse_entity_proposal_id(review_meta.proposal_id)
  if entity == nil then
    devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, { state = nil, version = nil }, "review-meta", "fixing|blocked", "skip-foreign(proposal_id)", "proposal_id is outside github-devloop")
    return
  end
  local repo = entity.repo
  local issue_number = entity.issue_number
  if not m_claims.verify_pr_review_issue_claim("review_meta", repo, issue_number, nil, review_meta.proposal_id) then
    return
  end

  local lock_key = entity_lib.transition_lock_key(review_meta.proposal_id)
  if lock_key == nil then
    devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, { state = nil, version = nil }, "review-meta", "fixing|blocked", "skip-foreign(proposal_id)", "no transition lock key")
    return
  end

  with_lock(lock_key, function()
    devloop_base.assert_trusted_bot_configured()

    local view = devloop_commands.gh_pr_view_origin(repo, review_meta.pr_number, 30)
    if view.exit_code ~= 0 then
      error("github-devloop: gh-pr-review-meta-view-failed: gh pr review-meta view failed: " .. tostring(view.stderr))
    end
    local current_pr = parsers_pr.parse_pr_view_origin(view.stdout)
    local current_issue = {
      title = "PR #" .. tostring(review_meta.pr_number),
      body = "(PR-only review-meta context; issue backing is absent)",
      comments = current_pr.comments,
    }
    if issue_number ~= nil then
      local issue_view = devloop_commands.gh_issue_view_fix(repo, issue_number, 30)
      if issue_view.exit_code ~= 0 then
        error("github-devloop: gh-issue-review-meta-view-failed: gh issue review-meta view failed: " .. tostring(issue_view.stderr))
      end
      local parsed_issue = parsers_issue.parse_issue_view_fix(core, issue_view.stdout)
      if parsed_issue.title ~= nil and parsed_issue.title ~= "" then
        current_issue.title = parsed_issue.title
      end
    end
    devloop_logging.log_forged_markers("review_meta", review_meta.proposal_id, current_pr.comments)

    local state = require("devloop.entity").current_entity_state(current_pr.comments, review_meta.proposal_id)
    local result_marker_visible = m_facts.has_review_meta_marker(current_pr.comments, review_meta.proposal_id, review_meta.dedup_key)
    local source_marker_visible = devloop_state.has_state_marker(current_pr.comments, review_meta.proposal_id, "review-meta", review_meta.version)
    if not result_marker_visible
      and not source_marker_visible
      and devloop_state.compare_state_marker_order(state, "review-meta", review_meta.version) < 0 then
      devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, state, "review-meta", "fixing|blocked", "retry-pending(from-state marker not yet visible)", "review-meta state marker not yet visible")
      error("github-devloop: review-meta-marker-missing: review-meta state marker not yet visible; retrying")
    end
    local snapshot = review_meta_caps.restart_effects.seal_snapshot({
      owner = review_meta_caps.restart_package_name,
      entity = { kind = "pr", repo = repo, number = review_meta.pr_number },
      proposal_id = review_meta.proposal_id,
      current = state,
      snapshot_fingerprint = table.concat({
        "pr-review-meta", review_meta.proposal_id, state.state or "missing", state.version or "missing",
      }, "|"),
      lock_epoch = lock_key .. "@" .. tostring(state.version or "missing"),
      generation = state.version or "missing",
    })
    local admission = review_meta_caps.restart_effects.decide_transition(snapshot, {
      semantic_variant = "fix",
      target = "fixing",
      incoming_version = review_meta.version,
      overlay_version = review_meta.version,
    })
    if admission.status == "pending" then
      devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, state, "review-meta", "fixing|blocked", "retry-pending(from-state marker not yet visible)", "review-meta state marker not yet visible")
      error("github-devloop: review-meta-marker-missing: review-meta state marker not yet visible; retrying")
    end
    if result_marker_visible then
      devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, state, "review-meta", "fixing|blocked", "skip-idempotent(review-meta marker already visible)", "review-meta result marker for incoming version is already visible")
      return
    end
    if state.state ~= "review-meta" or admission.status == "stale" then
      local stale_reason = "current marker is no longer review-meta"
      if admission.reason_code == "version-mismatch" then
        stale_reason = "review-meta event version does not match canonical issue marker"
      end
      devloop_logging.log_cas_decision("review_meta", review_meta.proposal_id, state, "review-meta", "fixing|blocked", admission.cas_outcome, stale_reason)
      return
    end
    if admission.status ~= "apply" then
      error("github-devloop: restart-effect-decision-illegal: PR review-meta admission rejected: "
        .. tostring(admission.reason_code))
    end
    local plan = load_review_meta_context(repo, issue_number, review_meta, event, current_pr, current_issue, state)
    if dispatch_live_run.dispatch_live_run_dedup(dispatch_liveness, "review-meta", review_meta.proposal_id, review_meta.version, {
      state = state,
      current_pr = current_pr,
      proposal_id = review_meta.proposal_id,
      now_seconds = now(),
    }) then
      devloop_logging.log_cas_decision(
        "review_meta",
        review_meta.proposal_id,
        { state = "review-meta", version = review_meta.version, stage_rank = devloop_state.stage_rank("review-meta") },
        "review-meta",
        "fixing|blocked",
        "skip-idempotent(live-exec-ref)",
        "matching review-meta codex run is still live"
      )
      return
    end

    local parsed = review_meta_codex_decision(plan)
    if parsed == nil then
      return
    end

    -- The legacy gate probes fixing before the codex result exists. Reselect only
    -- block outcomes so the minted grant is bound to the actual routed edge.
    local selected_decision = admission
    local selected_variant = "fix"
    if parsed.action ~= "fix" and parsed.action ~= "continue" then
      selected_variant = "block"
      selected_decision = review_meta_caps.restart_effects.decide_transition(snapshot, {
        semantic_variant = selected_variant,
        target = "blocked",
        incoming_version = review_meta.version,
        overlay_version = review_meta.version,
      })
    end
    if selected_decision.status ~= "apply" then
      error("github-devloop: restart-effect-decision-illegal: PR review-meta "
        .. selected_variant .. " decision rejected: " .. tostring(selected_decision.reason_code))
    end
    local grant = review_meta_caps.restart_effects.mint_grant(
      snapshot,
      selected_decision,
      "comment:pr:review-meta-result"
    )
    if grant == nil then
      error("github-devloop: restart-effect-grant-mint-failed: PR review-meta grant was not minted")
    end
    local facade = review_meta_caps.restart_effect_facade.make({
      family = "pr-review-meta",
      verify_grant = review_meta_caps.restart_effects.verify_grant,
      sink_inventory = review_meta_caps.sink_inventory,
    })
    if type(facade.emit) ~= "function" then
      error("github-devloop: restart-effect-facade-invalid: PR review-meta facade emit is unavailable")
    end
    apply_review_meta_decision(plan, parsed, {
      snapshot = snapshot,
      decision = selected_decision,
      grant = grant,
      facade = facade,
    })
  end)
end, wrap = devloop_logging.wrap_pipeline_failure, name = "review_meta" })
