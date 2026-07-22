local entity_lib = require("devloop.entity")
local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local convergence_shared = require("devloop.convergence.shared")
local transition_version = require("contract.transition_version")
local core = require("core")
local review_loop_caps = require("review_loop_department_caps")
local context_bundle = require("devloop.context_bundle")
local config = require("devloop.config")

local saga = require("workflow.saga")

local payloads_builders = require("devloop.payloads.builders")
local conv_rounds = require("devloop.convergence.rounds")
local conv_reconcile = require("devloop.convergence.reconcile")
local v_pr_review_unresolved = require("devloop.validators.pr_review_unresolved")
local v_validate_proposal = require("devloop.validators.validate_proposal")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local spec = {
  consumes = { "consensus.consensus_converge" },
  produces = {
    "consensus.proposal",
    "github-proxy.github_pr_comment_request",
    "devloop_review_reconcile",
  },
  fanout = { "consensus.consensus_converge" },
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

local function reviewing_segment_transition_status(comments, args)
  local state = entity_lib.current_entity_state(comments, args.proposal_id)
  local current_state = state or {}
  local snapshot = review_loop_caps.restart_effects.seal_snapshot({
    owner = review_loop_caps.restart_package_name,
    entity = { kind = "pr", repo = args.repo, number = args.pr_number },
    proposal_id = args.proposal_id,
    current = state,
    snapshot_fingerprint = table.concat({
      "pr-review-loop",
      args.proposal_id,
      current_state.state or "unmanaged",
      current_state.version or "unversioned",
      args.review_version,
      args.reviewed_head_sha,
      args.dedup_key,
    }, "|"),
    lock_epoch = args.lock_key .. "@" .. tostring(current_state.version or args.dedup_key),
    generation = current_state.version or args.dedup_key,
  })
  local transition = review_loop_caps.restart_effects.decide_transition(snapshot, {
    semantic_variant = "review_convergence_round",
    source_boundary = "consensus.consensus_converge",
    target = "reviewing",
    evidence_refs = {
      "devloop.entity.current_entity_state",
      "contract.transition_version.safe_version_segment",
    },
    review_version = args.review_version,
  })
  return state, snapshot, transition
end

return saga.department(spec, { done = function() return false end, act = function(event)
  local unresolved = event.payload or {}
  if not v_pr_review_unresolved.is_supported_pr_review_unresolved(unresolved) then
    devloop_logging.log_entry("review_loop", event, "unknown", devloop_logging.payload_field(unresolved, "dedup_key"))
    devloop_logging.log_cas_decision("review_loop", "unknown", { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-foreign(proposal_id)", "unsupported event payload")
    return
  end

  devloop_logging.log_entry("review_loop", event, unresolved.proposal_id, unresolved.dedup_key)
  local _, pr_number, review_version, reviewed_head_sha = devloop_base.parse_pr_review_proposal_id(unresolved.proposal_id)
  local repo, source_pr_number = devloop_base.parse_pr_source_ref(unresolved.source_ref)
  if repo == nil or tostring(source_pr_number) ~= tostring(pr_number) then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-foreign(source_ref)", "review source_ref does not match PR review proposal")
    return
  end

  devloop_base.assert_trusted_bot_configured()
  local branches = config.branch_config()
  local pr_view = devloop_commands.gh_pr_view_origin(repo, pr_number, 30)
  if pr_view.exit_code ~= 0 then
    error("github-devloop: gh-pr-review-loop-view-failed: gh pr origin view failed for review loop: " .. tostring(pr_view.stderr))
  end
  local current_pr = parsers_pr.parse_pr_view_origin(pr_view.stdout)
  local origin = m_facts.pr_origin_fact(current_pr.comments)
  if origin == nil then
    origin = entity_lib.pr_native_origin(repo, pr_number, current_pr)
  end
  if origin.repo ~= repo or tostring(current_pr.head_ref_name or "") ~= tostring(origin.branch) then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-foreign(pr-origin)", "PR origin mismatch")
    return
  end
  if tostring(current_pr.base_ref_name or "") ~= tostring(origin.base_branch)
    or tostring(origin.base_branch or "") ~= tostring(branches.integration) then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-foreign(base)", "PR base branch mismatch")
    return
  end
  if tostring(current_pr.state or ""):lower() ~= "open" then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-stale(pr-closed)", "re-derived PR is not open")
    return
  end
  if tostring(current_pr.head_sha or "") ~= tostring(reviewed_head_sha) then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-stale(head-advanced)", "PR head advanced since unresolved review")
    return
  end
  if not m_claims.verify_pr_review_issue_claim("review_loop", origin.repo, origin.issue_number, nil, origin.proposal_id) then
    return
  end

  local lock_key = entity_lib.transition_lock_key(origin.proposal_id)
  if lock_key == nil then
    devloop_logging.log_cas_decision("review_loop", unresolved.proposal_id, { state = nil, version = nil }, "reviewing", "reviewing|blocked", "skip-foreign(proposal_id)", "no issue transition lock key")
    return
  end
  local pr_source_ref = entity_lib.pr_source_ref(repo, pr_number)

  with_lock(lock_key, function()
    devloop_logging.log_forged_markers("review_loop", origin.proposal_id, current_pr.comments)
    local state, snapshot, transition = reviewing_segment_transition_status(current_pr.comments, {
      repo = repo,
      pr_number = pr_number,
      proposal_id = origin.proposal_id,
      review_version = review_version,
      reviewed_head_sha = reviewed_head_sha,
      dedup_key = unresolved.dedup_key,
      lock_key = lock_key,
    })
    if transition.status == "illegal" then
      error("github-devloop: restart-effect-decision-illegal: review loop admission rejected: "
        .. tostring(transition.reason_code))
    end
    if transition.status == "pending" then
      devloop_logging.log_cas_decision("review_loop", origin.proposal_id, state, "reviewing", "reviewing|blocked", transition.cas_outcome, "reviewing state marker not yet visible")
      error("github-devloop: review-loop-marker-missing: reviewing marker not yet visible for review loop; retrying")
    end
    if transition.status == "stale" then
      devloop_logging.log_cas_decision("review_loop", origin.proposal_id, state, "reviewing", "reviewing|blocked", transition.cas_outcome, "issue is not currently reviewing at this version")
      return
    end
    if transition.status ~= "apply" then
      error("github-devloop: restart-effect-decision-illegal: unsupported review loop admission status: "
        .. tostring(transition.status))
    end
    local facade = review_loop_caps.restart_effect_facade.make({
      family = "pr-review-loop",
      verify_grant = review_loop_caps.restart_effects.verify_grant,
      sink_inventory = review_loop_caps.sink_inventory,
    })
    local function build_comment_request(round_for_comment, marker_body_for_comment)
      local grant = review_loop_caps.restart_effects.mint_grant(
        snapshot, transition, "comment:pr:review-converge-round"
      )
      if grant == nil then
        error("github-devloop: restart-effect-grant-mint-failed: review loop comment grant was not minted")
      end
      local payload, rejection = facade.emit(
        grant,
        "github-proxy.github_pr_comment_request",
        snapshot,
        {
          core = core,
          repo = origin.repo,
          issue_number = origin.issue_number,
          unresolved = unresolved,
          issue_proposal_id = origin.proposal_id,
          round = round_for_comment,
          marker_body = marker_body_for_comment,
          source_ref = pr_source_ref,
        }
      )
      if payload == nil then
        error("github-devloop: restart-effect-facade-rejected: review loop comment effect rejected: "
          .. tostring(rejection))
      end
      return payload
    end
    local heartbeat_version = state.version
    local sr_digest = convergence_shared.source_ref_digest(unresolved.source_ref)
    local facts = conv_rounds.review_converge_round_facts(core, current_pr.comments, unresolved.proposal_id, origin.proposal_id, heartbeat_version, reviewed_head_sha, sr_digest)
    local round = math.max(tonumber(unresolved.round) or 0, conv_rounds.max_converge_round(facts))
    if conv_rounds.has_review_converge_round_marker(core, current_pr.comments, unresolved.proposal_id, origin.proposal_id, heartbeat_version, reviewed_head_sha, sr_digest, round) then
      devloop_logging.log_cas_decision("review_loop", origin.proposal_id, state, "reviewing", "reviewing", "skip-idempotent(review converge round marker already visible)", "review converge round marker for incoming round is already visible")
      return
    end

    local marker_body = conv_rounds.review_converge_round_marker(core,
      unresolved.proposal_id,
      origin.proposal_id,
      heartbeat_version,
      reviewed_head_sha,
      sr_digest,
      round,
      unresolved.dedup_key,
      unresolved.narrowed_question,
      unresolved.angle_digests,
      unresolved.findings_record,
      unresolved.essence_stall == true
    )
    local facts_with_current = conv_rounds.append_converge_round_fact(facts, round, unresolved.narrowed_question, unresolved.angle_digests, unresolved.dedup_key, unresolved.findings_record, unresolved.essence_stall == true)
    local terminal_cause = conv_rounds.terminal_cause(facts_with_current, round)
    if terminal_cause ~= nil then
      local comment_request = build_comment_request(round, marker_body)
      local review_reconcile = conv_reconcile.build_devloop_review_reconcile_payload(unresolved, round, origin.proposal_id, review_version, reviewed_head_sha, terminal_cause)
      local reason = "PR review convergence terminal cause=" .. terminal_cause .. " at round " .. tostring(round)
      devloop_logging.log_cas_decision("review_loop", origin.proposal_id, state, "reviewing", "reviewing", transition.cas_outcome, reason)
      devloop_logging.log_apply("review_loop", origin.proposal_id, nil, nil, { add = {}, remove = {} }, {
        "github-proxy.github_pr_comment_request",
        "devloop_review_reconcile",
      })
      devloop_logging.log_raise("review_loop", origin.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
      devloop_logging.log_raise("review_loop", origin.proposal_id, "devloop_review_reconcile", review_reconcile)
      return
    end
    local comment_request = build_comment_request(round, marker_body)

    local current_issue = {
      title = "PR #" .. tostring(pr_number),
      body = "(PR-only review context; issue backing is absent)",
      comments = current_pr.comments,
    }
    if origin.issue_number ~= nil then
      local issue_view = devloop_commands.gh_issue_view_review_loop(origin.repo, origin.issue_number, 30)
      if issue_view.exit_code ~= 0 then
        error("github-devloop: gh-issue-review-loop-view-failed: gh issue review loop view failed: " .. tostring(issue_view.stderr))
      end
      current_issue = parsers_issue.parse_issue_view_review_loop(core, issue_view.stdout)
    end
    local next_n = round + 1
    local next_dedup = transition_version.loop_at(conv_rounds.converge_proposal_base_dedup(unresolved.dedup_key), next_n)
    local context_fetch = { context_bundle.context_fetch_ref_from_bundle(core, {
      dept = "review_loop",
      repo = repo,
      issue_number = origin.issue_number,
      pr_number = pr_number,
      proposal_id = unresolved.proposal_id,
      version = next_dedup,
      tick = event.ts,
    }) }
    local content_fetch = context_fetch[1]
    local high_risk = context_fetch[2]
    local proposal = payloads_builders.build_board_pr_review_loop_proposal(core, repo, origin.issue_number, pr_number, state.version, current_pr.head_sha, current_issue, pr_source_ref, next_n, {
      narrowed_question = unresolved.narrowed_question,
      angle_digests = unresolved.angle_digests,
      findings_record = facts_with_current[#facts_with_current] and facts_with_current[#facts_with_current].findings_record,
    }, event.ts, current_pr.comments, content_fetch, high_risk, next_dedup)
    -- The implementation worktree is per-launch runtime scratch that a restart wipes; when it is gone,
    -- fall back to the read-only project checkout (".", a git repo the sandboxed codex accepts) so the
    -- review-consensus angle codex does not land in a non-git scratch dir and refuse to start ("Not inside
    -- a trusted directory"). The codex reads the PR diff from source_ref/content_fetch, not from cwd, so
    -- cwd only has to be a git repo. Makes PR review crash-only-robust across restarts.
    local worktree = devloop_commands.existing_implementation_worktree(repo, origin.issue_number, origin.impl_version)
    proposal.worktree = worktree or "."
    if not v_validate_proposal.validate_proposal(proposal) then
      log.warn("github-devloop dept=review_loop proposal_id=" .. tostring(origin.proposal_id) .. " tag=SKIP reason=cannot-build-valid-review-loop-proposal")
      return
    end
    devloop_logging.log_apply("review_loop", origin.proposal_id, nil, nil, { add = {}, remove = {} }, {
      "consensus.proposal",
      "github-proxy.github_pr_comment_request",
    })
    devloop_logging.log_raise("review_loop", origin.proposal_id, "consensus.proposal", proposal)
    devloop_logging.log_raise("review_loop", origin.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
  end)
end, wrap = devloop_logging.wrap_pipeline_failure, name = "review_loop" })
