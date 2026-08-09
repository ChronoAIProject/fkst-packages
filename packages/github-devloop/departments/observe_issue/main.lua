local entity_lib = require("devloop.entity")
local entity_highwater = require("devloop.entity_highwater")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local dependency_gate_lib = require("devloop.dependency_gate")
local base_ids = require("devloop.base_ids")
local context_bundle = require("devloop.context_bundle")
local m_claims = require("devloop.claims")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
local parsers_issue = require("devloop.parsers.issue")
local m_facts = require("devloop.markers.facts")
local core, saga, replay_fields = require("core"), require("workflow.saga"), require("devloop.replay_fields")
local contract_time = require("contract.time")
local operator_commands = require("devloop.operator_commands")
local queue = require("devloop.queue")
local transition_version = require("contract.transition_version")
local observe_issue_caps = require("observe_issue_department_caps")
local replayer = require("devloop.replayer")
local awaiting_pr_replay = require("awaiting_pr_replay")
local restart_analysis = require("core.restart_analysis")
local restart_transition_anomaly = require("devloop.restart_transition_anomaly")
local pr_parent_observation = require("departments.observe_issue.pr_parent_observation")
local liveness_scan = require("devloop.liveness_scan")

local payloads_builders = require("devloop.payloads.builders")
local conv_reconcile = require("devloop.convergence.reconcile")
local v_issue = require("devloop.validators.issue")
local v_validate_proposal = require("devloop.validators.validate_proposal")
local m_builders = require("devloop.markers.builders")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local operator_recovery_factory = require("departments.observe_issue.operator_recovery")
local log = log
local M = {}
local restart_transition_table = core.restart_transition_table

local spec = {
  consumes = { "github-proxy.github_entity_changed", "devloop_observe_issue" },
  produces = {
    "devloop_consensus_request",
    "github-proxy.github_issue_label_request",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_create_request",
    "github-proxy.github_issue_blocked_by_request",
    "github-proxy.github_pr_comment_request",
    "devloop_ready",
    "github-devloop-decompose.devloop_decompose",
    "devloop_reconcile",
    "devloop_timeout_reconcile",
    "restart_transition_anomaly",
  },
  fanout = { "github-proxy.github_entity_changed" },
  stall_window = "30s",
}

local operator_recovery = operator_recovery_factory.make({
  contract_time = contract_time,
  conv_reconcile = conv_reconcile,
  core = core,
  dependency_hold_fact = observe_issue_caps.dependency_hold_fact,
  devloop_logging = devloop_logging,
  devloop_state = devloop_state,
  operator_commands = operator_commands,
  replayer = replayer,
  replay_fields = replay_fields,
})
local maybe_apply_issue_rereview_command = operator_recovery.maybe_apply_issue_rereview_command
local maybe_apply_issue_reready_command = operator_recovery.maybe_apply_issue_reready_command
local maybe_apply_issue_dependency_waiver_command = operator_recovery.maybe_apply_issue_dependency_waiver_command

local function emit_restart_transition_anomalies(comments, proposal_id, issue)
  local history = restart_transition_anomaly.marker_history(comments, proposal_id)
  local anomalies = restart_analysis.analyze_observed_transition_history(history, {
    entity = { kind = "issue", repo = issue.repo, number = issue.number },
    transitions = {},
  })
  for _, anomaly in ipairs(anomalies) do
    devloop_logging.log_raise("observe_issue", proposal_id, "restart_transition_anomaly", anomaly)
  end
end

local function issue_label_state(issue_state)
  if issue_state ~= nil
    and (issue_state.state == "blocked" or issue_state.state == "merged") then
    return issue_state
  end
  return issue_state
end

local function linked_open_pr(snapshot, pr_number)
  for _, item in ipairs(snapshot and snapshot.prs or {}) do
    if tostring(item.number or "") == tostring(pr_number or "") then
      local current = item.current or {}
      if tostring(current.state or ""):lower() == "open" then
        return current
      end
    end
  end
  return nil
end

local function linked_pr(snapshot, pr_number)
  for _, item in ipairs(snapshot and snapshot.prs or {}) do
    if tostring(item.number or "") == tostring(pr_number or "") then
      return item.current
    end
  end
  return nil
end

local function issue_local_pr_bound_state_matches_link(issue_state, link)
  if issue_state == nil or link == nil then
    return false
  end
  if issue_state.state == "pr-open" or issue_state.state == "reviewing" then
    return transition_version.strip_suffixes(issue_state.version) == transition_version.strip_suffixes(link.impl_version)
  end
  if issue_state.state == "fixing" then
    return core.fixing_version_matches_link(issue_state.version, link.impl_version)
  end
  if issue_state.state == "review-meta" or issue_state.state == "merge-ready" or issue_state.state == "merging" then
    return core.fixing_version_matches_link(issue_state.version, link.impl_version)
  end
  return false
end

local function maybe_reconcile_issue_local_orphaned_pr(issue, proposal_id, current, issue_state, link, snapshot)
  if not issue_local_pr_bound_state_matches_link(issue_state, link) then
    return false
  end
  local row = replay_fields.restart_transition_row(restart_transition_table(), issue_state.state)
  if row == nil or row.terminal == true then
    return false
  end
  local facts = {
    proposal_id = proposal_id,
    current = current,
    link = link,
    snapshot = snapshot,
  }
  local current_pr = linked_pr(snapshot, link.pr_number)
  if current_pr == nil then
    if snapshot.absent_prs ~= nil and snapshot.absent_prs[tostring(link.pr_number or "")] == true then
      return core.terminal_linked_pr_action("observe_issue", issue, issue_state, proposal_id, link, nil, facts)
    end
    return false
  end
  if tostring(current_pr.state or ""):lower() == "open" then
    return false
  end
  return core.terminal_linked_pr_action("observe_issue", issue, issue_state, proposal_id, link, current_pr, facts)
end

local function issue_label_projection_state(issue_state, link, snapshot)
  if issue_state ~= nil
    and issue_state.state == "pr-open"
    and link ~= nil
    and tostring(link.impl_version or "") == tostring(issue_state.version or "")
    and linked_open_pr(snapshot, link.pr_number) ~= nil then
    return issue_state
  end
  return issue_label_state(issue_state)
end

local function derive_dependency_gate(issue, proposal_id, state, comments)
  return core.dependency_gate(issue.repo, issue.number, {
    proposal_id = proposal_id,
    version = state.version,
    comments = comments,
  })
end

local function replay_or_timeout(issue, proposal_id, current, link, snapshot, state, event_ts, issue_state,
  dependency_gate)
  local row = replay_fields.restart_transition_row(restart_transition_table(), state.state)
  local facts = {
    proposal_id = proposal_id,
    current = current,
    link = link,
    snapshot = snapshot,
    event_ts = event_ts,
    fresh_current_state = state,
    dependency_gate = dependency_gate,
  }
  local delegation = m_facts.pr_delegation_fact(current.comments, proposal_id, state.version)
  facts.pr_delegation = delegation
  facts["pr-delegation"] = delegation
  local epoch = row and row.actionable_epoch
  if issue.source == "liveness-scan"
    and type(epoch) == "table"
    and epoch.allows_state_entry_if_never_deferred == true
    and facts.dependency_gate == nil then
    facts.dependency_gate = derive_dependency_gate(issue, proposal_id, state, current.comments)
  end
  for _, advancing_fact in ipairs(row and row.advancing_facts or {}) do
    if advancing_fact.fact_family == "dependency-gate" and facts.dependency_gate == nil then
      facts.dependency_gate = derive_dependency_gate(issue, proposal_id, state, current.comments)
    end
  end
  if core.canonicalize_legacy_ready_dependency_wait("observe_issue", issue, state, facts) then
    return true
  end
  local state_is_issue_local = issue_state ~= nil
    and issue_state.state == state.state
    and tostring(issue_state.version or "") == tostring(state.version or "")
  local timeout_surface = issue.source == "liveness-scan" and "issue_liveness_scan" or "issue"
  if state_is_issue_local and core.restart_observe_timeout_due(row, timeout_surface, state, facts, now()) then
    return core.maybe_timeout_redrive_from_table("observe_issue", issue, state, row, facts)
  end
  if issue.source ~= "liveness-scan"
    and state_is_issue_local
    and core.restart_observe_replay_due(row, "issue", state, facts, now()) then
    local delivery = replayer.thinking_level_replay_delivery_identity(proposal_id, state, event_ts)
    if delivery ~= nil then
      facts.redrive_delivery = delivery
    end
    return replayer.replay_from_table(core, "observe_issue", issue, state, row, facts)
  end
  if core.restart_row_observable_on(row, "issue")
    and state_is_issue_local
    and replayer.replay_from_table(core, "observe_issue", issue, state, row, facts) then
    return true
  end
  if core.restart_row_observable_on(row, "issue") then
    return false
  end
  if issue_state == nil
    or issue_state.state ~= state.state
    or tostring(issue_state.version or "") ~= tostring(state.version or "") then
    return false
  end
  return core.maybe_timeout_redrive_from_table("observe_issue", issue, state, row, facts)
end

local function ensure_managed_issue_claim(issue, proposal_id, current, state)
  local admission, detail = m_claims.claim_admission_precheck(current, m_claims.claim_admission_inputs(current, issue.repo))
  if admission == "held" then
    return true
  end
  if admission == "other" then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, state.state, state.state, "skip-claim-lost", "CLAIM lost before managed issue handling")
    return false
  end
  if admission == "denied" then
    m_claims.log_claim_admission_skip("observe_issue", proposal_id, detail)
    return false
  end
  return m_claims.claim_issue_for_management(core, "observe_issue", issue.repo, issue.number, current, proposal_id)
end

local function maybe_canonicalize_implementing_terminal_delegated_pr(issue, proposal_id, current, issue_state, current_pr, current_pr_delegation)
  if issue_state == nil or issue_state.state ~= "implementing" then
    return false
  end
  local delegation = m_facts.pr_delegation_fact(current.comments, proposal_id, issue_state.version)
  if delegation == nil then
    return false
  end
  if not awaiting_pr_replay.delegation_identity_matches(current_pr_delegation, delegation) then
    current_pr = nil
  end
  return awaiting_pr_replay.canonicalize_implementing_terminal_delegated_pr("observe_issue", issue, issue_state, {
    proposal_id = proposal_id,
    current = current,
    current_issue = current,
    current_pr = current_pr,
    fresh_current_state = issue_state,
    ["pr-delegation"] = delegation,
  })
end

local function raise_stale_dependency_label_clear(issue, proposal_id, state, current)
  local has_label = devloop_state.has_label(current.labels, devloop_base._blocked_on_dependency_label)
  if state.state == "dependency_wait" then
    return false, nil
  end
  local ready = state.state == "ready"
  local gate = ready and derive_dependency_gate(issue, proposal_id, state, current.comments) or nil
  if not has_label or (ready and not dependency_gate_lib.dependency_gate_is_satisfied(gate)) then
    return false, gate
  end
  devloop_logging.log_apply("observe_issue", proposal_id, state.state, state.version, {
    add = {},
    remove = { devloop_base._blocked_on_dependency_label },
  }, {
    "github-proxy.github_issue_label_request",
  })
  devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_label_request", requests_labels.build_label_request(issue.repo,
    issue.number,
    {},
    { devloop_base._blocked_on_dependency_label },
    base_ids.dedup_key({ "dependency", "label", "clear", tostring(proposal_id), tostring(state.version or "unversioned") }),
    issue.source_ref
  ))
  return true, gate
end

local function source_ref_matches(left, right)
  return tostring(left and left.kind or "") == tostring(right and right.kind or "")
    and tostring(left and left.ref or "") == tostring(right and right.ref or "")
end

local function implementing_timeout_reimplement_fact(current, proposal_id, state, source_ref, link)
  if state.state ~= "blocked" or link ~= nil then
    return nil
  end
  local fact = conv_reconcile.timeout_reconcile_fact_for_terminal_version_from_states(current.comments, proposal_id, state.version, {
    implementing = true,
  })
  if fact == nil
    or fact.from_state ~= "implementing"
    or fact.reason_class ~= "state-output-obligation-timeout"
    or not source_ref_matches(fact.source_ref, source_ref) then
    return nil
  end
  return fact
end

local function maybe_apply_issue_reimplement_command(issue, proposal_id, current, state, snapshot)
  local command = operator_commands.operator_command_fact(current.comments, "reimplement")
  if command == nil then
    return false
  end
  if operator_commands.has_operator_command_response(current.comments, command) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "impl-failed", "implementing", "skip-idempotent(command-response-visible)", "operator command response marker is already visible")
    return false
  end
  local link = m_facts.pr_link_fact(current.comments, proposal_id)
  local blocked_open_pr_reentry = state.state == "blocked" and linked_open_pr(snapshot, link and link.pr_number) ~= nil
  local timeout_reentry = implementing_timeout_reimplement_fact(current, proposal_id, state, issue.source_ref, link)
  local refusal_reentry = core.implementation_refusal_fact(current.comments, proposal_id, state.version)
  local blocked_reentry = blocked_open_pr_reentry or timeout_reentry ~= nil or refusal_reentry ~= nil
  if state.state ~= "impl-failed" and not blocked_reentry then
    local refusal_reason = "reimplement requires impl-failed, blocked state with an open linked PR, or blocked state from implementing timeout without a PR; file a new issue for blocked thinking convergence drops. A blocked implementation refusal is eligible only when its trusted current fact has one of these exact reasons: "
      .. core.implementation_refusal_reasons_text()
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "impl-failed|blocked(open-pr)|blocked(implementing-timeout)|blocked(implementation-refusal)", "implementing", "refused(invalid-state)", refusal_reason)
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      refusal_reason,
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end

  local attempt = 1
  local failure = core.impl_failure_fact(current.comments, proposal_id, state.version)
  if failure ~= nil then
    attempt = tonumber(failure.attempt or 1) + 1
  elseif refusal_reentry ~= nil then
    attempt = tonumber(refusal_reentry.attempt or 1) + 1
  elseif blocked_open_pr_reentry or timeout_reentry ~= nil then
    -- Both reentry paths derive the retry attempt from a prior implementation
    -- version; select that version once so the retry-attempt read stays single.
    local prior_impl_version
    if blocked_open_pr_reentry then
      prior_impl_version = link.impl_version
    else
      prior_impl_version = timeout_reentry.from_version
    end
    attempt = (core.implementation_retry_attempt(prior_impl_version) or 1) + 1
  end
  local retry_version = blocked_open_pr_reentry and link.impl_version
    or (timeout_reentry ~= nil and timeout_reentry.from_version
      or (refusal_reentry ~= nil and refusal_reentry.implementation_version or state.version))
  local payload_source = {
    proposal_id = proposal_id,
    dedup_key = core.ready_payload_inner_version(retry_version),
    source_ref = issue.source_ref,
    impl_retry_attempt = attempt,
    operator_reimplement_delivery = {
      command_key = command.key,
    },
  }
  if blocked_open_pr_reentry then
    payload_source.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      pr_number = link.pr_number,
      state_version = state.version,
      impl_version = link.impl_version,
    }
  elseif timeout_reentry ~= nil then
    payload_source.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      terminal_reason = "implementing-timeout-without-pr",
      state_version = state.version,
      impl_version = timeout_reentry.from_version,
      timeout_round = timeout_reentry.round,
    }
  elseif refusal_reentry ~= nil then
    payload_source.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      terminal_reason = "implementation-refusal",
      state_version = state.version,
      impl_version = refusal_reentry.implementation_version,
    }
  end
  local payload = payloads_builders.build_devloop_ready_payload(core, payload_source)
  local comment_request = operator_commands.build_operator_issue_reimplement_comment_request(issue.repo,
    issue.number,
    command,
    attempt,
    issue.source_ref
  )
  devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "impl-failed|blocked(open-pr)|blocked(implementing-timeout)|blocked(implementation-refusal)", "implementing", "applied(operator-reimplement)", "trusted operator command requested implementation retry")
  devloop_logging.log_apply("observe_issue", proposal_id, nil, nil, { add = {}, remove = {} }, {
    "github-proxy.github_issue_comment_request",
    "devloop_ready",
  })
  devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise("observe_issue", proposal_id, "devloop_ready", payload)
  return true
end

local function reconcile_issue_event(event, opts)
  local issue = event.payload or {}
  if not v_issue.is_supported_issue(issue) then
    devloop_logging.log_entry("observe_issue", event, "unknown", devloop_logging.payload_field(issue, "dedup_key"))
    devloop_logging.log_cas_decision("observe_issue", "unknown", { state = nil, version = nil }, "unmanaged", "thinking", "skip-foreign(proposal_id)", "unsupported event payload")
    return
  end

  local proposal_id = base_ids.proposal_id(issue.repo, issue.number)
  devloop_logging.log_entry("observe_issue", event, proposal_id, issue.dedup_key)
  local lock_key = entity_lib.observe_lock_key(issue.repo, issue.number)
  local options = opts or {}
  local function process_issue_event(_, record_authoritative_version)
    parsers_misc.assert_trusted_bot_configured()

    local state_view = devloop_entity_view.fetch_issue_view_state(issue.repo, issue.number, issue.updated_at, {
      force_fresh = true,
      allow_cached_validator = issue.source == "liveness-scan",
    })
    if state_view.exit_code ~= 0 then
      error("github-devloop: issue-read-failed: gh issue state view failed: " .. tostring(state_view.stderr))
    end

    local current = parsers_issue.parse_issue_view_state(core, state_view.stdout)
    local authoritative_updated_at = current.updated_at
    current.updated_at = current.updated_at or issue.updated_at
    record_authoritative_version(authoritative_updated_at)
    if current.state ~= "OPEN" then
      devloop_logging.log_cas_decision("observe_issue", proposal_id, { state = nil, version = nil }, "unmanaged", "thinking", "skip-advanced-or-diverged", "issue is not open")
      return
    end
    if not devloop_base.is_opted_in(current.labels) then
      devloop_logging.log_cas_decision("observe_issue", proposal_id, { state = nil, version = nil }, "unmanaged", "thinking", "skip-not-opted-in", "fkst-dev:enabled label is absent")
      return
    end
    devloop_logging.log_forged_markers("observe_issue", proposal_id, current.comments)
    local link = m_facts.pr_link_fact(current.comments, proposal_id)
    local issue_state = devloop_state.current_state(current.comments, proposal_id)
    emit_restart_transition_anomalies(current.comments, proposal_id, issue)
    if devloop_base.is_intake_held(current.labels) then
      devloop_logging.log_cas_decision("observe_issue", proposal_id, { state = nil, version = nil }, "unmanaged", "thinking", "skip-held", "fkst-dev:hold label is present")
      return
    end
    if issue.source == "pr-entity-change" then
      if issue_state.state ~= "awaiting-pr" then
        local current_delegation = m_facts.pr_delegation_fact(current.comments, proposal_id)
        local claim_verified = false
        if current_delegation ~= nil then
          if not ensure_managed_issue_claim(issue, proposal_id, current, issue_state) then
            return
          end
          claim_verified = true
          if awaiting_pr_replay.close_canonically_merged_delegated_issue("observe_issue", issue, issue_state, {
            proposal_id = proposal_id,
            current_pr = issue.child_pr,
            ["pr-delegation"] = current_delegation,
          }) then
            return
          end
        end
        local handoff_transition = awaiting_pr_replay.implementing_to_awaiting_pr_transition_status(issue, proposal_id, issue_state)
        if handoff_transition == "apply" or handoff_transition == "idempotent" then
          if not claim_verified and not ensure_managed_issue_claim(issue, proposal_id, current, issue_state) then
            return
          end
          local delegation = m_facts.pr_delegation_fact(current.comments, proposal_id, issue_state.version)
          if awaiting_pr_replay.canonicalize_implementing_terminal_delegated_pr("observe_issue", issue, issue_state, {
            proposal_id = proposal_id,
            current = current,
            current_issue = current,
            current_pr = issue.child_pr,
            fresh_current_state = issue_state,
            ["pr-delegation"] = delegation,
          }) then
            return
          end
        end
        devloop_logging.log_cas_decision("observe_issue", proposal_id, issue_state, "awaiting-pr", "awaiting-pr", "skip-foreign(parent-not-awaiting-pr)", "PR entity change only replays parent awaiting-pr")
        return
      end
      if not ensure_managed_issue_claim(issue, proposal_id, current, issue_state) then
        return
      end
      local row = replay_fields.restart_transition_row(restart_transition_table(), "awaiting-pr")
      replayer.replay_from_table(core, "observe_issue", issue, issue_state, row, {
        proposal_id = proposal_id,
        current = current,
        current_issue = current,
        current_pr = issue.child_pr,
        fresh_current_state = issue_state,
      })
      return
    end
    local claim_checked = false
    if issue_state.state ~= nil then
      if not ensure_managed_issue_claim(issue, proposal_id, current, issue_state) then
        return
      end
      claim_checked = true
      if maybe_apply_issue_reready_command(issue, proposal_id, current, issue_state, link) then
        return
      end
    end
    local snapshot = core.linked_pr_surface_snapshot(issue.repo, proposal_id, current.comments)
    snapshot.fresh = true
    local state = issue_state
    local function maybe_canonicalize_legacy_pr_open_issue()
      if issue_state == nil or issue_state.state ~= "pr-open" then
        return false
      end
      if link == nil
        or tonumber(link.pr_number) == nil
        or tostring(link.impl_version or "") ~= tostring(issue_state.version or "") then
        devloop_logging.log_cas_decision("observe_issue", proposal_id, issue_state, "pr-open", "awaiting-pr", "skip-stale(pr-link-missing)", "legacy pr-open canonicalization requires a matching visible PR link")
        return false
      end
      if linked_open_pr(snapshot, link.pr_number) == nil then
        devloop_logging.log_cas_decision("observe_issue", proposal_id, issue_state, "pr-open", "awaiting-pr", "skip-pending(open-pr-missing)", "legacy pr-open canonicalization requires an open linked PR")
        return false
      end
      local pr_proposal_id = entity_lib.pr_proposal_id(issue.repo, link.pr_number)
      local retry_attempt = core.implementation_retry_attempt(issue_state.version)
      local delegation = "g" .. tostring(core.implementation_delegation_generation(
        issue_state.version,
        retry_attempt
      ))
      local comment_body = "github-devloop canonicalized legacy issue PR state to delegated PR child"
        .. "\n\n" .. devloop_state.state_marker(proposal_id, "awaiting-pr", issue_state.version)
        .. "\n" .. m_builders.pr_delegation_marker(proposal_id, pr_proposal_id, link.pr_number, issue_state.version, delegation)
      local comment_request = entity_lib.build_entity_comment_request({
        kind = "issue",
        repo = issue.repo,
        number = issue.number,
      }, comment_body, base_ids.dedup_key({
        "canonicalize",
        "pr-open",
        tostring(proposal_id),
        tostring(issue_state.version),
        tostring(link.pr_number),
      }), issue.source_ref)
      local label_request = requests_labels.build_state_label_request(issue.repo, issue.number, "awaiting-pr", proposal_id, issue_state.version, base_ids.dedup_key({
        "canonicalize",
        "pr-open",
        "label",
        tostring(proposal_id),
        tostring(issue_state.version),
        tostring(link.pr_number),
      }), issue.source_ref)
      local add_labels, remove_labels = devloop_state.state_label_changes("awaiting-pr")
      devloop_logging.log_cas_decision("observe_issue", proposal_id, issue_state, "pr-open", "awaiting-pr", "applied(legacy-pr-open-canonicalized)", "open linked PR preserved as delegated child")
      devloop_logging.log_apply("observe_issue", proposal_id, "awaiting-pr", issue_state.version, { add = add_labels, remove = remove_labels }, {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
      })
      devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", comment_request)
      devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_label_request", label_request)
      return true
    end
    if state.state ~= nil then
      local close_current_pr = nil
      local close_delegation = nil
      if not claim_checked and not ensure_managed_issue_claim(issue, proposal_id, current, state) then
        return
      end
      if state.state ~= "awaiting-pr" then
        close_delegation = m_facts.pr_delegation_fact(current.comments, proposal_id)
        local closed
        closed, close_current_pr = awaiting_pr_replay.close_canonically_merged_delegated_issue("observe_issue", issue, state, {
          proposal_id = proposal_id,
          ["pr-delegation"] = close_delegation,
        })
        if closed then
          return
        end
      end
      if maybe_apply_issue_rereview_command(issue, proposal_id, current, state, event.ts) then
        return
      end
      if maybe_apply_issue_dependency_waiver_command(issue, proposal_id, current, state) then
        return
      end
      if maybe_apply_issue_reimplement_command(issue, proposal_id, current, state, snapshot) then
        return
      end
      if maybe_canonicalize_implementing_terminal_delegated_pr(issue, proposal_id, current, state, close_current_pr, close_delegation) then
        return
      end
      if maybe_canonicalize_legacy_pr_open_issue() then
        return
      end
      local label_state = issue_label_projection_state(issue_state, link, snapshot)
      local add_labels, remove_labels = devloop_state.state_label_reconcile_changes(current.labels, label_state.state)
      if #add_labels > 0 or #remove_labels > 0 then
        local label_request = requests_labels.build_state_label_request(issue.repo,
          issue.number,
          label_state.state,
          proposal_id,
          label_state.version,
          base_ids.dedup_key({
            "reconcile",
            "label",
            proposal_id,
            label_state.state,
            tostring(label_state.version or "unversioned"),
          }),
          issue.source_ref,
          current.labels
        )
        devloop_logging.log_apply("observe_issue", proposal_id, label_state.state, label_state.version, { add = add_labels, remove = remove_labels }, {
          "github-proxy.github_issue_label_request",
        })
        devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_label_request", label_request)
      end
      local _, dependency_gate = raise_stale_dependency_label_clear(issue, proposal_id, state, current)
      if maybe_reconcile_issue_local_orphaned_pr(issue, proposal_id, current, issue_state, link, snapshot) then
        return
      end
      if replay_or_timeout(issue, proposal_id, current, link, snapshot, state, event.ts, issue_state,
        dependency_gate) then
        return
      end
    end
    local grant_version = state.version or issue.dedup_key
    local snapshot = observe_issue_caps.restart_effects.seal_snapshot({
      owner = observe_issue_caps.restart_package_name,
      entity = { kind = "issue", repo = issue.repo, number = issue.number },
      proposal_id = proposal_id,
      current = { state = state.state, version = grant_version },
      snapshot_fingerprint = table.concat({
        "observe-issue-entry", proposal_id, state.state or "unmanaged", grant_version,
      }, "|"),
      lock_epoch = lock_key .. "@" .. grant_version,
      generation = grant_version,
    })
    local decision = observe_issue_caps.restart_effects.decide_transition(snapshot, {
      semantic_variant = "unmanaged_issue",
      source_boundary = "github-proxy.github_entity_changed",
      target = "thinking",
      incoming_version = issue.dedup_key,
    })
    if decision.status == "stale" then
      devloop_logging.log_cas_decision("observe_issue", proposal_id, state,
        "unmanaged", "thinking", decision.cas_outcome,
        "current marker is not an unmanaged start")
      return
    end
    if devloop_logging.log_typed_guard("pending_log_error", decision,
      "observe_issue", proposal_id, state, "unmanaged", "thinking",
      "unmanaged state marker pending for observe") == "error" then
      error("github-devloop: state-marker-pending: unmanaged state marker pending for observe; retrying")
    end
    if decision.status ~= "apply" and decision.status ~= "idempotent" then
      error("github-devloop: restart-effect-decision-illegal: observe issue entry decision rejected: "
        .. tostring(decision.reason_code))
    end
    if not m_claims.claim_issue_for_management(core, "observe_issue", issue.repo,
      issue.number, current, proposal_id) then
      return
    end
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state,
      "unmanaged", "thinking", decision.cas_outcome,
      "starting consensus for opted-in issue")

    issue.content_fetch = context_bundle.context_fetch_ref_from_bundle(core, {
      dept = "observe_issue",
      repo = issue.repo,
      issue_number = issue.number,
      proposal_id = proposal_id,
      version = issue.dedup_key,
      tick = event.ts,
    })
    local proposal = payloads_builders.build_board_proposal(core, issue, event.ts)
    if not v_validate_proposal.validate_proposal(proposal) then
      log.warn("github-devloop dept=observe_issue proposal_id=" .. tostring(proposal_id)
        .. " tag=SKIP reason=cannot-build-valid-proposal")
      return
    end
    local grant = observe_issue_caps.restart_effects.mint_grant(
      snapshot, decision, "comment:issue:thinking-state")
    if grant == nil then
      error("github-devloop: restart-effect-grant-mint-failed: observe issue entry grant was not minted")
    end
    local facade = observe_issue_caps.restart_effect_facade.make({
      family = "observe-issue-entry",
      verify_grant = observe_issue_caps.restart_effects.verify_grant,
      sink_inventory = observe_issue_caps.sink_inventory,
    })
    if type(facade.emit) ~= "function" then
      error("github-devloop: restart-effect-facade-invalid: observe issue entry facade emit is unavailable")
    end

    local effects = {}
    local serializer_args = { core = core, issue = issue, proposal = proposal }
    for _, effect_id in ipairs(decision.granted_effect_ids) do
      local payload, rejection = facade.emit(grant, effect_id, snapshot, serializer_args)
      if payload == nil then
        error("github-devloop: restart-effect-facade-rejected: observe issue entry effect "
          .. tostring(effect_id) .. " rejected: " .. tostring(rejection))
      end
      table.insert(effects, { queue = effect_id, payload = payload })
    end
    local add_labels, remove_labels = devloop_state.state_label_changes("thinking")
    devloop_logging.log_apply("observe_issue", proposal_id, "thinking", proposal.dedup_key, {
      add = add_labels,
      remove = remove_labels,
    }, decision.granted_effect_ids)
    for _, effect in ipairs(effects) do
      devloop_logging.log_raise("observe_issue", proposal_id, effect.queue, effect.payload)
    end


  end
  return entity_highwater.reconcile({
    consumer = "github-devloop/observe_issue",
    enabled = options.highwater_enabled,
    event = event,
    lock_held = options.lock_held,
    lock_key = lock_key,
    work = process_issue_event,
  })
end

local process_pr_event = pr_parent_observation.make(reconcile_issue_event)

local function reconcile_liveness_issue_event(event)
  liveness_scan.liveness_scan_fail_observe_payload(event and event.payload)
  return reconcile_issue_event(event)
end

return saga.department(spec, { done = function() return false end, act = function(event)
  queue.dispatch_consumed_queue("observe_issue", spec, event, {
    ["github-proxy.github_entity_changed"] = function(e)
      if devloop_logging.payload_field(e and e.payload, "type") == "pr" then
        return process_pr_event(e)
      end
      return reconcile_issue_event(e)
    end,
    devloop_observe_issue = reconcile_liveness_issue_event,
  })
end, wrap = devloop_logging.wrap_pipeline_failure, name = "observe_issue" })
