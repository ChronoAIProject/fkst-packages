local git_mechanics = require("devloop.git_mechanics")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local payloads_builders = require("devloop.payloads.builders")
local m_facts = require("devloop.markers.facts")
local C = {}
local replay_thinking_convergence = require("devloop.replay_thinking_convergence")
local replay_fields = require("devloop.replay_fields")
local forge_validators = require("devloop.forge_validators")
local context_bundle = require("devloop.context_bundle")
local decompose_lib = require("devloop.decompose")
local devloop_logging = require("devloop.logging")
local dispatch_live_run = require("devloop.dispatch_live_run")
local devloop_state = require("devloop.state")
local restart_metadata = require("devloop.restart_metadata")

local replay_required_facts = require("devloop.replay_required_facts")
local find_linked_pr = replay_required_facts.find_linked_pr
local gather_required_facts = replay_required_facts.gather_required_facts

local function resolve_payload_fields(row, state, facts)
  return replay_fields.resolve(row, state, facts or {}, entity_lib.pr_source_ref)
end

local function restart_row(restart_policy, state_name)
  return replay_fields.restart_transition_row(restart_policy.restart_transition_table(), state_name)
end

local function raise_effects(dept, proposal_id, apply_state, version, label_changes, effects)
  return replay_fields.replay_raise_effects(devloop_logging.log_apply, devloop_logging.log_raise, dept, proposal_id, apply_state, version, label_changes, effects)
end

local function authorize_thinking_true_stall_drop(authorization, args)
  if type(authorization.authorize_true_stall_drop) ~= "function" then
    error("github-devloop: restart-effect-authority-missing: thinking replay owner authorization is unavailable")
  end
  return authorization.authorize_true_stall_drop(args)
end

local function thinking_caps(R)
  local authorization = R.replay_effects.authorization
  local caps = {
    latest_complete_converge_round = function(...) return R.restart_policy.latest_complete_converge_round(...) end,
    context_fetch = function(...) return context_bundle.context_fetch_ref_from_bundle(...) end,
    build_board_loop = function(...) return payloads_builders.build_board_loop_proposal(...) end,
    build_board = function(...) return payloads_builders.build_board_proposal(...) end,
    dispatch_live_run = function(...) return dispatch_live_run.dispatch_live_run_dedup(R.restart_policy, ...) end,
    authorize_true_stall_drop = function(args) return authorize_thinking_true_stall_drop(authorization, args) end,
  }
  caps.replay_true_stall = function(...)
    return replay_thinking_convergence.replay_thinking_true_stall_blocked(caps, ...)
  end
  return caps
end

local function fixing_replay_comment_request(R, issue, pr_number, fix_payload, feedback, source_ref)
  local reason = feedback.reason or fix_payload.gate_failure_excerpt or feedback.review_reason or "fixing-replay"
  local request = requests_review.build_merge_gate_fix_comment_request(R.replay_effects.merge_gate_reason_class, R.replay_effects.output_language, issue.repo,
    issue.number,
    {
      proposal_id = fix_payload.proposal_id,
      pr_number = pr_number,
      version = fix_payload.version,
      review_proposal_id = fix_payload.review_proposal_id,
      review_dedup_key = fix_payload.review_dedup_key,
      reviewed_head_sha = fix_payload.reviewed_head_sha,
    },
    fix_payload.version,
    reason,
    fix_payload.gate_baseline_sha,
    source_ref,
    fix_payload.predecessor_set,
    {
      blocking_gap = fix_payload.blocking_gap,
      gate_failure_excerpt = fix_payload.gate_failure_excerpt,
      ci_failure_key = fix_payload.ci_failure_key,
      preserve_nil_gate_failure_excerpt = fix_payload.gate_failure_excerpt == nil,
    }
  )
  request.handoff.dedup_key = fix_payload.dedup_key
  return request
end

local function terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, current_pr, facts)
  if tools == nil or type(tools.terminal_linked_pr_action) ~= "function" then
    return nil
  end
  return tools.terminal_linked_pr_action(dept, issue, state, proposal_id, link, current_pr, facts)
end

local function log_decline(R, disposition, dept, proposal_id, state, from_state, to_state, outcome, reason, facts)
  local capture = R.replay_capture
  if capture ~= nil then
    capture.disposition = disposition
    capture.outcome = outcome
    capture.reason = reason
    capture.from_state = from_state
    capture.to_state = to_state
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, from_state, to_state, outcome, reason, facts)
  return false
end
local function log_skip(R, ...) return log_decline(R, "stuck", ...) end
local function log_defer(R, ...) return log_decline(R, "deferred", ...) end

local function replay_log_decline(R, disposition, ...)
  if disposition == "deferred" then return log_defer(R, ...) end
  if disposition == "stuck" then return log_skip(R, ...) end
  error("github-devloop: typed-replay-disposition-invalid: invalid typed replay disposition")
end

local function build_thinking_replay_proposal(R, issue, proposal_id, state, current, event_ts)
  return replay_thinking_convergence.build_replay_proposal(thinking_caps(R), issue, proposal_id, state, current, event_ts)
end

local function has_thinking_converge_replay(R, current, proposal_id, state, source_ref)
  return replay_thinking_convergence.has_converge_replay(thinking_caps(R), current, proposal_id, state, source_ref)
end

local function thinking_level_replay_delivery_identity(...)
  return replay_thinking_convergence.level_replay_delivery_identity(...)
end

local function replay_thinking(R, dept, issue, state, row, facts)
  return replay_thinking_convergence.replay(thinking_caps(R), dept, issue, state, row, facts,
    function(...) return log_skip(R, ...) end,
    function(...) return log_defer(R, ...) end,
    raise_effects)
end

local function replay_implementing(R, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local attempt = facts["implement-attempt"]
  if attempt == nil and facts.implementing == nil then
    return log_skip(R, dept, proposal_id, state, "implementing", row.driving_queue, "skip-pending(no-implementing-fact)", "neither implement attempt nor implementing progress marker is visible")
  end
  local current_now = facts.now_seconds or now()
  local receiver_liveness = R.restart_policy.restart_row_receiver_liveness(row, state, facts, current_now)
  if receiver_liveness.action == "defer" then
    return log_skip(R, dept, proposal_id, state, "implementing", row.driving_queue, "skip-pending(codex-run-live)", "matching implement codex run is still running")
  end
  local decision = R.restart_policy.liveness_timeout_decision_with_facts(row, state, facts, current_now)
  local age, budget = tonumber(decision.age_minutes), tonumber(row.budget and row.budget.minutes)
  if attempt == nil and (budget == nil or age == nil or age < budget) then
    return log_skip(R, dept, proposal_id, state, "implementing", row.driving_queue, "skip-pending(liveness-budget)", "implementing progress marker is not over row budget")
  end
  if decision.action ~= "redrive" then
    return log_skip(R, dept, proposal_id, state, "implementing", row.driving_queue, "skip-pending(" .. tostring(decision.action or "liveness") .. ")", "implementing receiver liveness is not redriveable")
  end
  -- Pass the INNER (unwrapped) version: build_devloop_ready_payload re-applies
  -- the "ready/" wrapper, so re-wrapping the already-wrapped state.version would
  -- double-wrap it ("ready/ready/..."). Derive lifecycle retry identity from the
  -- authoritative state version; implement-attempt.attempt is audit-only.
  local payload = payloads_builders.build_devloop_ready_payload({
    proposal_id = proposal_id,
    dedup_key = R.replay_sources.issue_retry_policy.ready_payload_inner_version(state.version),
    source_ref = issue.source_ref,
    impl_retry_attempt = R.replay_sources.issue_retry_policy.implementation_retry_attempt(state.version),
    redrive_delivery = facts.redrive_delivery,
  })
  devloop_logging.log_cas_decision(dept, proposal_id, state, "implementing", "implementing", "applied(codex-run-absent)", "no matching implement codex run is running")
  return raise_effects(dept, proposal_id, "implementing", state.version, { add = {}, remove = {} }, {
    { queue = "devloop_ready", payload = payload },
  })
end

local function replay_impl_failed(R, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local failure = facts.impl_failure
  if failure == nil then
    return log_skip(R, dept, proposal_id, state, "impl-failed", "implementing", "skip-idempotent(retry-limit)", "implementation failure is not a bounded codex retry candidate")
  end
  if not R.replay_sources.issue_retry_policy.impl_failure_retry_allowed(failure) then
    return log_defer(R, dept, proposal_id, state, "impl-failed", "implementing", "skip-pending(operator-reentry)", "implementation failure is waiting for an explicit operator reready or reimplement command")
  end
  local fields = resolve_payload_fields(row, state, {
    issue = issue,
    state = state,
    proposal_id = proposal_id,
    ["impl-failure"] = failure,
  })
  local payload = payloads_builders.build_devloop_ready_payload({
    proposal_id = fields.proposal_id,
    dedup_key = R.replay_sources.issue_retry_policy.ready_payload_inner_version(fields.dedup_key),
    source_ref = fields.source_ref,
    impl_retry_attempt = R.replay_sources.issue_retry_policy.next_implementation_retry_attempt(state.version),
  })
  devloop_logging.log_cas_decision(dept, proposal_id, state, "impl-failed", "implementing", "applied(replay)", "retryable implementation failure is below the retry ceiling")
  return raise_effects(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
    { queue = "devloop_ready", payload = payload },
  })
end

local function replay_fixing_to_reviewing(R, dept, issue, state, proposal_id, link, current_pr, feedback, source_ref)
  local intended_head_sha = git_mechanics.current_branch_head_sha(R.replay_effects.git, link.branch)
  if intended_head_sha == nil then
    devloop_logging.log_cas_decision(dept, proposal_id, state, "fixing", "reviewing", "retry-pending(head-advanced)", "PR head changed and deterministic branch head is not readable")
    error("github-devloop: deterministic-branch-head-read-failed: PR head changed before fix replay and deterministic branch head is not readable")
  end
  if tostring(current_pr.head_sha or "") ~= intended_head_sha then
    return log_skip(R, dept, proposal_id, state, "fixing", "fixing", "skip-stale(head-advanced)", "PR head advanced since rejected review")
  end
  local reviewing_version = restart_metadata.next_fix_version(state.version)
  local comments = (issue._replay_issue_comments ~= nil and issue._replay_issue_comments) or {}
  if devloop_state.has_state_marker(comments, proposal_id, "reviewing", reviewing_version)
    or devloop_state.has_state_marker(current_pr.comments, proposal_id, "reviewing", reviewing_version) then
    return log_skip(R, dept, proposal_id, state, "fixing", "reviewing", "skip-idempotent(reviewing marker already visible)", "reviewing state marker for recovered head is already visible")
  end
  local fix = {
    proposal_id = proposal_id,
    pr_number = link.pr_number,
    version = state.version,
    review_proposal_id = feedback.review_proposal_id,
    review_dedup_key = feedback.review_dedup_key,
    reviewed_head_sha = feedback.reviewed_head_sha,
    source_ref = source_ref,
  }
  requests_review.raise_fix_reviewing(R.replay_effects.output_language, {
    dept = dept,
    repo = issue.repo,
    issue_number = issue.number,
    fix = fix,
    old_head_sha = feedback.reviewed_head_sha,
    new_head_sha = current_pr.head_sha,
    new_version = reviewing_version,
    reason = "push already visible; self-healing missing reviewing marker",
    current_state = state,
  })
  return true
end

local function replay_fixing(R, tools, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local link = facts.link
  if link == nil or not R.restart_policy.fixing_version_matches_link(state.version, link.impl_version) then
    return log_skip(R, dept, proposal_id, state, "fixing", "fixing|reviewing", "skip-foreign(pr-link)", "fixing recovery requires a same-version pr-link marker")
  end
  local current_pr = find_linked_pr(facts.snapshot, link.pr_number)
  if current_pr == nil then
    local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, nil, facts)
    if terminal ~= nil then return terminal end
    return log_skip(R, dept, proposal_id, state, "fixing", "fixing|reviewing", "skip-foreign(pr-link)", "linked PR fact is not visible")
  end
  local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, current_pr, facts)
  if terminal ~= nil then return terminal end
  if tostring(current_pr.state or ""):lower() ~= "open" then
    return log_skip(R, dept, proposal_id, state, "fixing", "fixing|reviewing", "skip-stale(pr-closed)", "linked PR is not open")
  end
  if not forge_validators.is_git_sha(current_pr.head_sha) then
    return log_skip(R, dept, proposal_id, state, "fixing", "fixing|reviewing", "skip-foreign(head)", "linked PR head sha is missing")
  end

  local feedback = facts.feedback or R.restart_policy.fixing_replay_feedback_fact(facts.snapshot.comments, proposal_id, state.version)
  if feedback ~= nil then
    if feedback.review_proposal_id == nil or feedback.reviewed_head_sha == nil then
      return log_skip(R, dept, proposal_id, state, "fixing", "fixing", "skip-foreign(fix-feedback-binding)", "trusted fix feedback marker lacks review binding")
    end
    if tostring(current_pr.head_sha or "") ~= tostring(feedback.reviewed_head_sha or "") then
      return replay_fixing_to_reviewing(R, dept, issue, state, proposal_id, link, current_pr, feedback, facts.source_ref or entity_lib.pr_source_ref(issue.repo, link.pr_number))
    end
    local reviewing_version = restart_metadata.next_fix_version(state.version)
    if devloop_state.has_state_marker(facts.snapshot.comments, proposal_id, "reviewing", reviewing_version)
      or devloop_state.has_state_marker(current_pr.comments, proposal_id, "reviewing", reviewing_version) then
      return log_skip(R, dept, proposal_id, state, "fixing", "reviewing", "skip-idempotent(reviewing marker already visible)", "reviewing state marker for fix is already visible")
    end
    local fields = resolve_payload_fields(row, state, {
      issue = issue,
      state = state,
      link = link,
      feedback = feedback,
      proposal_id = proposal_id,
    })
    local fix_payload = payloads_builders.build_replayed_fixing_payload({
      proposal_id = fields.proposal_id,
      impl_version = fields.version,
    }, fields.pr_number, feedback, fields.source_ref)
    devloop_logging.log_cas_decision(dept, proposal_id, state, "fixing", "fixing", "applied(replay)", "trusted feedback fact is visible")
    if dept == "observe_pr" then
      local comment_request = fixing_replay_comment_request(R, issue, fields.pr_number, fix_payload, feedback, fields.source_ref)
      return raise_effects(dept, proposal_id, "fixing", state.version, { add = {}, remove = {} }, {
        { queue = "github-proxy.github_pr_comment_request", payload = comment_request },
      })
    end
    return raise_effects(dept, proposal_id, "fixing", state.version, { add = {}, remove = {} }, {
      { queue = R.replay_effects.pr_package_queue("devloop_fixing"), payload = fix_payload },
    })
  end

  if dept ~= "observe_pr" then
    local new_version = restart_metadata.next_fix_version(state.version)
    local source_ref = entity_lib.pr_source_ref(issue.repo, link.pr_number)
    local comment_request = requests_review.build_merge_head_reviewing_comment_request(
      R.replay_effects.output_language,
      issue.repo,
      issue.number,
      {
        proposal_id = proposal_id,
        pr_number = link.pr_number,
      },
      current_pr.head_sha,
      current_pr.head_sha,
      new_version,
      source_ref
    )
    local label_request = requests_labels.build_state_label_request(issue.repo, issue.number, "reviewing", proposal_id, new_version, base_ids.dedup_key({
      "observe",
      "fixing",
      "renormalize",
      tostring(proposal_id),
      tostring(new_version),
      tostring(link.pr_number),
    }), issue.source_ref, nil, { kind = "pr", number = link.pr_number })
    devloop_logging.log_cas_decision(dept, proposal_id, state, "fixing", "reviewing", "applied(replay)", "no feedback fact is visible; re-entering review for current PR head")
    return raise_effects(dept, proposal_id, "reviewing", new_version, { add = { "fkst-dev:reviewing" }, remove = { "fkst-dev:fixing" } }, {
      { queue = "github-proxy.github_pr_comment_request", payload = comment_request },
      { queue = "github-proxy.github_issue_label_request", payload = label_request },
    })
  end

  return log_skip(R, dept, proposal_id, state, "fixing", "fixing", "skip-stale(no-trusted-fix-feedback)", "trusted fix feedback marker is not visible")
end

local function replay_review_meta(R, tools, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local link = facts.link
  if link == nil then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(pr-link)", "review-meta recovery requires a pr-link marker")
  end
  local current_pr = find_linked_pr(facts.snapshot, link.pr_number)
  if current_pr == nil then
    local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, nil, facts)
    if terminal ~= nil then return terminal end
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(pr-link)", "linked PR fact is not visible")
  end
  local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, current_pr, facts)
  if terminal ~= nil then return terminal end
  if tostring(current_pr.state or ""):lower() ~= "open" then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-stale(pr-closed)", "linked PR is not open")
  end
  if tostring(current_pr.head_ref_name or "") ~= tostring(link.branch or "") then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(head)", "linked PR head branch does not match pr-link marker")
  end
  if tostring(current_pr.base_ref_name or "") ~= tostring(link.base_branch or "") then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(base)", "linked PR base branch does not match pr-link marker")
  end
  if not forge_validators.is_git_sha(current_pr.head_sha) then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(head)", "linked PR head sha is missing")
  end
  local fact = facts.review_meta
    or R.restart_policy.review_meta_replay_fact(facts.snapshot.comments, proposal_id, state.version, link.pr_number, current_pr.head_sha)
  if fact == nil then
    return log_skip(R, dept, proposal_id, state, "review-meta", "review-meta", "skip-foreign(review-meta)", "review-meta recovery facts are not visible")
  end
  local fields = resolve_payload_fields(row, state, {
    issue = issue,
    state = state,
    link = link,
    review_meta = fact,
    proposal_id = proposal_id,
  })
  local payload = nil
  if fact.mode == "fix-reflection" then
    payload = payloads_builders.build_devloop_fix_reflection_payload(fact, proposal_id, fields.version, fields.pr_number, fact.fix_round or fact.n, fields.source_ref, facts.redrive_delivery)
    payload.blocking_gap = fact.blocking_gap
  else
    payload = payloads_builders.build_devloop_review_meta_payload(fact, proposal_id, fields.version, fields.pr_number, fact.n, fields.source_ref, facts.redrive_delivery)
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "review-meta", "review-meta", "applied(replay)", "trusted review-meta fact is visible")
  return raise_effects(dept, proposal_id, "review-meta", state.version, { add = {}, remove = {} }, {
    { queue = R.replay_effects.pr_package_queue("devloop_review_meta"), payload = payload },
  })
end

local function raise_reviewing_for_current_head(R, dept, issue, state, proposal_id, link, current_pr, outcome, reason)
  if tostring(current_pr.state or ""):lower() ~= "open" then
    return log_skip(R, dept, proposal_id, state, "merge-ready", "reviewing", "skip-stale(pr-closed)", "linked PR is not open")
  end
  if not forge_validators.is_git_sha(current_pr.head_sha) then
    return log_skip(R, dept, proposal_id, state, "merge-ready", "reviewing", "skip-foreign(head)", "linked PR head sha is missing")
  end
  local reviewing_payload = payloads_builders.build_current_head_reviewing_payload({ repo = issue.repo, proposal_id = proposal_id }, link.pr_number, current_pr, state, entity_lib.pr_source_ref(issue.repo, link.pr_number))
  devloop_logging.log_cas_decision(dept, proposal_id, state, "merge-ready", "reviewing", outcome, reason)
  if reviewing_payload == nil then
    return false
  end
  if dept == "observe_pr" then
    local merge_ready = m_facts.merge_ready_fact(current_pr.comments, proposal_id, state.version, link.pr_number)
    local comment_request = requests_review.build_merge_head_reviewing_comment_request(
      R.replay_effects.output_language,
      issue.repo,
      issue.number,
      {
        proposal_id = proposal_id,
        pr_number = link.pr_number,
      },
      merge_ready and merge_ready.head_sha or current_pr.head_sha,
      current_pr.head_sha,
      state.version,
      entity_lib.pr_source_ref(issue.repo, link.pr_number)
    )
    return raise_effects(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
      { queue = "github-proxy.github_pr_comment_request", payload = comment_request },
    })
  end
  return raise_effects(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
    { queue = R.replay_effects.pr_package_queue("devloop_reviewing"), payload = reviewing_payload },
  })
end

local function maybe_replay_review_carry_over(R, dept, issue, state, row, facts, link, current_pr)
  local proposal_id = facts.proposal_id
  if state.state ~= "merge-ready" then
    return false
  end
  if tostring(current_pr.state or ""):lower() ~= "open" or not require("devloop.pr_safety").is_safe_head_sha(current_pr.head_sha) then
    return false
  end
  local carry, carry_reason = R.replay_effects.authorization.approved_lineage_carry_over(
    issue.repo,
    link.pr_number,
    proposal_id,
    state.version,
    facts.snapshot.comments,
    link.base_branch,
    current_pr.head_sha
  )
  if carry_reason == "missing-merge-ready-fact" or carry_reason == "head-unchanged" then
    return false
  end
  if carry_reason == "missing-review-result-approve" then
    return false
  end
  if carry == nil then
    local outcome = "skip-stale(" .. tostring(carry_reason):match("^([^:]+)") .. ")"
    return raise_reviewing_for_current_head(R, dept, issue, state, proposal_id, link, current_pr, outcome, tostring(carry_reason))
  end
  if m_facts.has_any_review_result_marker(current_pr.comments, carry.new_review_proposal_id, proposal_id) then
    return false
  end
  local source_ref = entity_lib.pr_source_ref(issue.repo, link.pr_number)
  local comment_request = requests_review.build_review_carry_over_comment_request(issue.repo, link.pr_number, proposal_id, state.version, carry, source_ref)
  devloop_logging.log_cas_decision(dept, proposal_id, state, "merge-ready", "merge-ready", "applied(review-carry-over)", "resolution delta is empty")
  return raise_effects(dept, proposal_id, "merge-ready", state.version, { add = {}, remove = {} }, {
    { queue = "github-proxy.github_pr_comment_request", payload = comment_request },
  })
end

local function replay_merge_ready_like(R, tools, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local link = facts.link
  if link == nil then
    return log_skip(R, dept, proposal_id, state, row.from_state, "merge-ready", "skip-foreign(pr-link)", "merge-ready recovery requires a pr-link marker")
  end
  local current_pr = find_linked_pr(facts.snapshot, link.pr_number)
  if current_pr == nil then
    local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, nil, facts)
    if terminal ~= nil then return terminal end
    return log_skip(R, dept, proposal_id, state, row.from_state, "merge-ready", "skip-foreign(pr-link)", "linked PR fact is not visible")
  end
  local terminal = terminal_linked_pr_action(tools, dept, issue, state, proposal_id, link, current_pr, facts)
  if terminal ~= nil then return terminal end
  if maybe_replay_review_carry_over(R, dept, issue, state, row, facts, link, current_pr) then
    return true
  end
  local fact = m_facts.merge_ready_fact(facts.snapshot.comments, proposal_id, state.version, link.pr_number, current_pr.head_sha)
  if fact == nil then
    return log_skip(R, dept, proposal_id, state, row.from_state, "merge-ready", "skip-foreign(merge-ready)", "head-bound merge-ready marker is not visible")
  end
  local fields = resolve_payload_fields(row, state, {
    issue = issue,
    state = state,
    link = link,
    merge_ready = fact,
    ["merge-ready"] = fact,
    proposal_id = proposal_id,
  })
  local payload = payloads_builders.build_devloop_merge_ready_payload(fields.proposal_id, fields.pr_number, fields.version, {
    review_proposal_id = fields.review_proposal_id,
    review_dedup_key = fields.review_dedup_key,
    reviewed_head_sha = fields.reviewed_head_sha,
    current_head_sha = current_pr.head_sha,
  }, fields.source_ref)
  devloop_logging.log_cas_decision(dept, proposal_id, state, row.from_state, "merge-ready", "applied(replay)", "trusted head-bound merge-ready fact is visible")
  return raise_effects(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
    { queue = R.replay_effects.pr_package_queue("devloop_merge_ready"), payload = payload },
  })
end

local function replay_blocked(R, dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local link = facts.link
  if link == nil then
    return log_skip(R, dept, proposal_id, state, "blocked", "decomposed", "skip-foreign(pr-link)", "decompose recovery requires a pr-link marker")
  end
  local current_pr = find_linked_pr(facts.snapshot, link.pr_number)
  local decomposed = facts.decomposed
  if decomposed == nil then
    return log_skip(R, dept, proposal_id, state, "blocked", "decomposed", "skip-foreign(decomposed)", "decomposed marker is not visible")
  end
  local complete, completed_count = decompose_lib.decompose_children_complete(
    nil,
    facts.decompose_children or {},
    proposal_id,
    decomposed.version,
    decomposed.pr_number,
    decomposed.count
  )
  if complete then
    return log_skip(R, dept, proposal_id, state, "blocked", "decomposed", "skip-idempotent(decomposed children already visible)", "decompose children are complete")
  end
  local fields = resolve_payload_fields(row, state, {
    issue = issue,
    state = state,
    link = link,
    decomposed = decomposed,
    proposal_id = proposal_id,
  })
  local payload = decompose_lib.build_decompose_replay_payload(R.restart_policy, decomposed, facts.fix_feedback, fields.source_ref, completed_count)
  if payload == nil then
    return log_skip(R, dept, proposal_id, state, "blocked", "decomposed", "skip-foreign(decompose-binding)", "trusted fix feedback for decomposed replay is not visible")
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "blocked", "decomposed", "applied(decomposed-children-missing)", "decomposed marker count exceeds derived child count " .. tostring(completed_count))
  local queue = R.restart_policy.decompose_package_queue()
  return raise_effects(dept, proposal_id, "blocked", state.version, { add = {}, remove = {} }, {
    { queue = queue, payload = payload },
  })
end

local function replayer_tools(R)
  local tools = {
    find_linked_pr = find_linked_pr,
    log_skip = function(...)
      return log_skip(R, ...)
    end,
    log_defer = function(...)
      return log_defer(R, ...)
    end,
    raise_effects = function(...)
      return raise_effects(...)
    end,
    resolve_payload_fields = function(row, state, facts)
      return resolve_payload_fields(row, state, facts)
    end,
  }
  tools.replay_review_meta_receiver = function(...)
    return replay_review_meta(R, tools, ...)
  end
  return tools
end

local function restart_replayers(R)
  local tools = replayer_tools(R)
  local replayers = {
    thinking = function(...)
      return replay_thinking(R, ...)
    end,
    implementing = function(...)
      return replay_implementing(R, ...)
    end,
    ["impl-failed"] = function(...)
      return replay_impl_failed(R, ...)
    end,
    blocked = function(...)
      return replay_blocked(R, ...)
    end,
  }
  local function merge(source)
    if source == nil then return end
    if type(source) ~= "table" then
      error("github-devloop: restart-replayer-registry-invalid: invalid restart replayer registry")
    end
    for state_name, replay in pairs(source) do
      if type(state_name) ~= "string" or state_name == "" or type(replay) ~= "function" then
        error("github-devloop: restart-replayer-registration-invalid: invalid restart replayer registration")
      end
      replayers[state_name] = replay
    end
  end
  merge(R.replay_sources.package_replayers)
  if R.replay_sources.review_replayers == nil then
    return replayers
  end
  merge({
    fixing = function(...)
      return replay_fixing(R, tools, ...)
    end,
    ["review-meta"] = function(...)
      return replay_review_meta(R, tools, ...)
    end,
    ["merge-ready"] = function(...)
      return replay_merge_ready_like(R, tools, ...)
    end,
    merging = function(...)
      return replay_merge_ready_like(R, tools, ...)
    end,
  })
  local review_replayers = R.replay_sources.review_replayers
  if type(review_replayers) == "function" then
    review_replayers = review_replayers(tools)
  end
  merge(review_replayers)
  return replayers
end

local function replay_from_table(R, dept, entity, state, table_row, facts)
  local row = table_row or restart_row(R.restart_policy, state and state.state)
  local proposal_id = facts and facts.proposal_id or nil
  if row == nil then
    return log_skip(R, dept, proposal_id, state, "unknown", "unknown", "skip-foreign(table-row)", "no restart transition table row is declared")
  end
  if type(state) ~= "table" or state.state ~= row.from_state then
    return log_skip(R, dept, proposal_id, state, row.from_state, row.driving_queue, "skip-foreign(state)", "current state does not match restart transition table row")
  end
  local replayers = restart_replayers(R)
  local replay = replayers[row.from_state]
  if replay == nil then return log_skip(R, dept, proposal_id, state, row.from_state, row.driving_queue, "skip-foreign(replayer)", "restart transition table row is not replayable by this department") end
  local replay_facts = gather_required_facts(R.restart_policy, R.replay_sources, row, entity, state, facts or {})
  local ok, issued = pcall(function()
    return replay(dept, entity, state, row, replay_facts)
  end)
  if not ok then error(issued) end
  return issued
end

local function replay_from_table_classified(R, dept, entity, state, table_row, facts)
  local capture = {}
  local previous = R.replay_capture
  R.replay_capture = capture
  local ok, issued = pcall(R.replay_from_table, dept, entity, state, table_row, facts)
  R.replay_capture = previous
  if not ok then error(issued) end
  if issued then
    return { kind = "issued", issued = true }
  end
  return {
    kind = capture.disposition == "deferred" and "deferred" or "stuck",
    issued = false,
    outcome = capture.outcome,
    reason = capture.reason,
  }
end

function C.new(restart_policy, replay_sources, replay_effects)
  local R = {
    restart_policy = restart_policy,
    replay_sources = replay_sources,
    replay_effects = replay_effects,
  }
  R.replay_from_table = function(...) return replay_from_table(R, ...) end
  R.replay_from_table_classified = function(...) return replay_from_table_classified(R, ...) end
  R.replay_log_decline = function(...) return replay_log_decline(R, ...) end
  R.build_thinking_replay_proposal = function(...) return build_thinking_replay_proposal(R, ...) end
  R.has_thinking_converge_replay = function(...) return has_thinking_converge_replay(R, ...) end
  R.thinking_level_replay_delivery_identity = thinking_level_replay_delivery_identity
  R.gather_replay_required_facts = function(...)
    return replay_required_facts.gather_replay_required_facts(restart_policy, replay_sources, ...)
  end
  return R
end

return C
