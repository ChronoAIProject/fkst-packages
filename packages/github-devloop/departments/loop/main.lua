local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local parsers_issue = require("devloop.parsers.issue")
local convergence_shared = require("devloop.convergence.shared")
local core, saga = require("core"), require("workflow.saga")
local loop_caps = require("loop_department_caps")
local context_bundle = require("devloop.context_bundle")



local payloads_builders = require("devloop.payloads.builders")
local conv_rounds = require("devloop.convergence.rounds")
local valid_round = require("devloop.rounds").valid_round
local v_unresolved = require("devloop.validators.unresolved")
local v_validate_proposal = require("devloop.validators.validate_proposal")
local entity_lib = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local devloop_commands = require("devloop.commands")
local github_factory = require("devloop.github_factory")
local github_author_policy = require("devloop.github_author_policy")
local transition_version = require("contract.transition_version")
local spec = {
  consumes = { "consensus.consensus_converge" },
  produces = {
    "consensus.proposal",
    "github-proxy.github_issue_comment_request",
  },
  fanout = { "consensus.consensus_converge" },
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

local function latest_lineage_fact(lineage)
  local latest = nil
  for _, fact in ipairs(lineage or {}) do
    if type(fact) == "table" and (latest == nil or tonumber(fact.round) > tonumber(latest.round)) then
      latest = fact
    end
  end
  return latest
end

return saga.department(spec, { done = function() return false end, act = function(event)
  local unresolved = event.payload or {}
  if not v_unresolved.is_supported_unresolved(unresolved) then
    devloop_logging.log_entry("loop", event, "unknown", devloop_logging.payload_field(unresolved, "dedup_key"))
    devloop_logging.log_cas_decision("loop", "unknown", { state = nil, version = nil }, "thinking", "thinking", "skip-foreign(proposal_id)", "unsupported event payload")
    return
  end

  devloop_logging.log_entry("loop", event, unresolved.proposal_id, unresolved.dedup_key)
  local repo, issue_number = base_ids.parse_proposal_id(unresolved.proposal_id)
  if repo == nil then
    devloop_logging.log_cas_decision("loop", unresolved.proposal_id, { state = nil, version = nil }, "thinking", "thinking", "skip-foreign(proposal_id)", "proposal_id is outside github-devloop")
    return
  end

  local lock_key = entity_lib.loop_lock_key(unresolved.proposal_id)
  if lock_key == nil then
    devloop_logging.log_cas_decision("loop", unresolved.proposal_id, { state = nil, version = nil }, "thinking", "thinking", "skip-foreign(proposal_id)", "no transition lock key")
    return
  end

  with_lock(lock_key, function()
    devloop_base.assert_trusted_bot_configured()

    local view = devloop_commands.gh_issue_view_loop(repo, issue_number, 30)
    if view.exit_code ~= 0 then
      error("github-devloop: issue-read-failed: gh issue loop view failed: " .. tostring(view.stderr))
    end

    local current = parsers_issue.parse_issue_view_loop(core, view.stdout)
    devloop_logging.log_forged_markers("loop", unresolved.proposal_id, current.comments)
    local state = devloop_state.current_state(current.comments, unresolved.proposal_id)
    local trusted_author_policy = github_author_policy.from_handle_policy(github_factory.production_handle)
    if not github_author_policy.is_authorized(trusted_author_policy, current.author_login) then
      devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", "skip-non-whitelisted-author", "issue author is not authorized for GitHub content")
      return
    end
    local snapshot = loop_caps.restart_effects.seal_snapshot({
      owner = loop_caps.restart_package_name,
      entity = { kind = "issue", repo = repo, number = issue_number },
      proposal_id = unresolved.proposal_id,
      current = state,
      snapshot_fingerprint = table.concat({
        "loop-plain",
        unresolved.proposal_id,
        state.state or "unmanaged",
        state.version or "unversioned",
        unresolved.dedup_key,
      }, "|"),
      lock_epoch = lock_key .. "@" .. tostring(state.version or unresolved.dedup_key),
      generation = state.version or unresolved.dedup_key,
    })
    local transition = loop_caps.restart_effects.decide_transition(snapshot, {
      semantic_variant = "consensus-stalled",
      target = "blocked",
      incoming_version = unresolved.dedup_key,
    })
    loop_caps.restart_effects.assert_decision_admissible(
      transition,
      "github-devloop: restart-effect-decision-illegal: loop admission rejected"
    )
    if devloop_logging.log_typed_guard("idempotent_or_stale_log_return", transition,
      "loop", unresolved.proposal_id, state, "thinking", "thinking",
      "unresolved event cannot advance current marker") == "return" then
      return
    end
    if devloop_logging.log_typed_guard("pending_log_error", transition,
      "loop", unresolved.proposal_id, state, "thinking", "thinking",
      "thinking state marker not yet visible") == "error" then
      error("github-devloop: state-marker-pending: thinking state marker not yet visible for unresolved; retrying")
    end
    if transition.status ~= "apply" then
      error("github-devloop: restart-effect-decision-illegal: unsupported loop admission status: "
        .. tostring(transition.status))
    end

    local base_version = conv_rounds.converge_base_version(unresolved.dedup_key)
    local sr_digest = convergence_shared.source_ref_digest(unresolved.source_ref)
    local facade = loop_caps.restart_effect_facade.make({
      family = "loop-plain",
      verify_grant = loop_caps.restart_effects.verify_grant,
      sink_inventory = loop_caps.sink_inventory,
    })
    local function build_comment_request(unresolved_for_comment, round_for_comment, marker_body_for_comment, handoff_for_comment)
      local grant = loop_caps.restart_effects.mint_grant(snapshot, transition, "comment:issue:converge-round")
      if grant == nil then
        error("github-devloop: restart-effect-grant-mint-failed: loop comment grant was not minted")
      end
      local payload, rejection = facade.emit(
        grant,
        "github-proxy.github_issue_comment_request",
        snapshot,
        {
          core = core,
          issue = { repo = repo, number = issue_number },
          unresolved = unresolved_for_comment,
          round = round_for_comment,
          marker_body = marker_body_for_comment,
          handoff = handoff_for_comment,
        }
      )
      if payload == nil then
        error("github-devloop: restart-effect-facade-rejected: loop comment effect rejected: "
          .. tostring(rejection))
      end
      return payload
    end
    local lineage = conv_rounds.converge_round_facts_for_proposal(current.comments, unresolved.proposal_id)
    local has_lineage = #lineage > 0
    local latest_round = conv_rounds.max_converge_round(lineage)
    local latest_fact = latest_lineage_fact(lineage)
    local lineage_terminal_cause = has_lineage and conv_rounds.terminal_cause(lineage, latest_round) or nil
    if lineage_terminal_cause ~= nil then
      local terminal_base_version = latest_fact and latest_fact.version or base_version
      local terminal_unresolved = {
        proposal_id = unresolved.proposal_id,
        dedup_key = (latest_fact and latest_fact.dedup) or unresolved.dedup_key,
        source_ref = unresolved.source_ref,
        narrowed_question = (latest_fact and latest_fact.narrowed_question) or unresolved.narrowed_question,
        angle_digests = (latest_fact and latest_fact.angle_digests) or unresolved.angle_digests,
      }
      local comment_request = build_comment_request(terminal_unresolved, latest_round, "", {
        kind = "github-devloop.reconcile",
        proposal_id = unresolved.proposal_id,
        round = latest_round,
        base_version = terminal_base_version,
        terminal_cause = lineage_terminal_cause,
        source_ref = base_ids.normalize_source_ref(unresolved.source_ref),
      })
      devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", transition.cas_outcome, "convergence lineage terminal at round " .. tostring(latest_round))
      devloop_logging.log_apply("loop", unresolved.proposal_id, nil, nil, { add = {}, remove = {} }, {
        "github-proxy.github_issue_comment_request",
      })
      devloop_logging.log_raise("loop", unresolved.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
      return
    end

    local incoming_round = valid_round(unresolved.round) or 0
    if has_lineage and incoming_round <= latest_round then
      devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", "skip-stale(converge round lineage already advanced)", "incoming converge round is not newer than the proposal lineage")
      return
    end
    local expected_round = has_lineage and (latest_round + 1) or 0
    if incoming_round ~= expected_round then
      devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", "skip-stale(converge round gap)", "incoming converge round is not the next proposal lineage round")
      return
    end
    local round = incoming_round

    local marker_body = conv_rounds.converge_round_marker(unresolved.proposal_id,
      base_version,
      sr_digest,
      round,
      unresolved.dedup_key,
      unresolved.narrowed_question,
      unresolved.angle_digests,
      unresolved.findings_record,
      unresolved.essence_stall == true
    )
    local lineage_with_current = conv_rounds.append_converge_round_fact(lineage, round, unresolved.narrowed_question, unresolved.angle_digests, unresolved.dedup_key, unresolved.findings_record, unresolved.essence_stall == true)
    local terminal_cause = conv_rounds.terminal_cause(lineage_with_current, round)
    if terminal_cause ~= nil then
      local comment_request = build_comment_request(unresolved, round, marker_body, {
        kind = "github-devloop.reconcile",
        proposal_id = unresolved.proposal_id,
        round = round,
        base_version = base_version,
        terminal_cause = terminal_cause,
        source_ref = base_ids.normalize_source_ref(unresolved.source_ref),
      })
      local reason = "convergence terminal cause=" .. terminal_cause .. " at round " .. tostring(round)
      devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", transition.cas_outcome, reason)
      devloop_logging.log_apply("loop", unresolved.proposal_id, nil, nil, { add = {}, remove = {} }, {
        "github-proxy.github_issue_comment_request",
      })
      devloop_logging.log_raise("loop", unresolved.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
      return
    end

    local next_n = round + 1
    local next_dedup = transition_version.loop_at(conv_rounds.converge_proposal_base_dedup(unresolved.dedup_key), next_n)
    local content_fetch = context_bundle.context_fetch_ref_from_bundle(core, {
      dept = "loop",
      repo = repo,
      issue_number = issue_number,
      proposal_id = unresolved.proposal_id,
      version = next_dedup,
      tick = event.ts,
    })
    local proposal = payloads_builders.build_board_loop_proposal(core, repo, issue_number, current, unresolved.source_ref, next_n, {
      narrowed_question = unresolved.narrowed_question,
      angle_digests = unresolved.angle_digests,
      findings_record = lineage_with_current[#lineage_with_current] and lineage_with_current[#lineage_with_current].findings_record,
    }, event.ts, content_fetch, next_dedup)
    if not v_validate_proposal.validate_proposal(proposal) then
      log.warn("github-devloop dept=loop proposal_id=" .. tostring(unresolved.proposal_id) .. " tag=SKIP reason=cannot-build-valid-loop-proposal")
      return
    end
    local comment_request = build_comment_request(unresolved, round, marker_body)

    devloop_logging.log_cas_decision("loop", unresolved.proposal_id, state, "thinking", "thinking", transition.cas_outcome, "raising loop proposal round " .. tostring(next_n))
    devloop_logging.log_apply("loop", unresolved.proposal_id, nil, nil, { add = {}, remove = {} }, {
      "consensus.proposal",
      "github-proxy.github_issue_comment_request",
    })
    devloop_logging.log_raise("loop", unresolved.proposal_id, "consensus.proposal", proposal)
    devloop_logging.log_raise("loop", unresolved.proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  end)
end, wrap = devloop_logging.wrap_pipeline_failure, name = "loop" })
