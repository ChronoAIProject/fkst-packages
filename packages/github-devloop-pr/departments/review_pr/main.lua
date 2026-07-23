local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local m_claims = require("devloop.claims")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local core, saga, context_bundle = require("core"), require("workflow.saga"), require("devloop.context_bundle")

local payloads_builders = require("devloop.payloads.builders")
local payloads_predicates = require("devloop.payloads.predicates")
local m_facts = require("devloop.markers.facts")
local v_reviewing = require("devloop.validators.reviewing")
local v_validate_proposal = require("devloop.validators.validate_proposal")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local no_legitimate_diff = require("core.no_legitimate_diff")
local review_pr_caps = require("review_pr_department_caps")
-- Preserve existing body line coordinates for the coverage ratchet.

local spec = {
  consumes = { "devloop_reviewing" },
  produces = {
    "consensus.proposal",
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

return saga.department(spec, { done = function() return false end, act = function(event)
  local reviewing = event.payload or {}
  if not v_reviewing.is_supported_reviewing(core, reviewing) then
    devloop_logging.log_entry("review_pr", event, "unknown", devloop_logging.payload_field(reviewing, "dedup_key"))
    devloop_logging.log_cas_decision("review_pr", "unknown", { state = nil, version = nil }, "reviewing", "review-proposal", "skip-foreign(payload)", "unsupported event payload")
    return
  end

  devloop_logging.log_entry("review_pr", event, reviewing.proposal_id, reviewing.dedup_key)
  local entity = entity_lib.parse_entity_proposal_id(reviewing.proposal_id)
  if entity == nil then
    devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, { state = nil, version = nil }, "reviewing", "review-proposal", "skip-foreign(proposal_id)", "proposal_id is outside github-devloop")
    return
  end
  local repo = entity.repo
  local issue_number = entity.issue_number

  local lock_key = entity_lib.review_lock_key(reviewing.proposal_id)
  if lock_key == nil then
    devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, { state = nil, version = nil }, "reviewing", "review-proposal", "skip-foreign(proposal_id)", "no transition lock key")
    return
  end

  with_lock(lock_key, function()
    devloop_base.assert_trusted_bot_configured()

    local pr_view = devloop_commands.gh_pr_view_origin(repo, reviewing.pr_number, 30)
    if pr_view.exit_code ~= 0 then
      error("github-devloop: gh-pr-review-head-view-failed: gh pr review head view failed: " .. tostring(pr_view.stderr))
    end
    local current_pr = parsers_pr.parse_pr_view_origin(pr_view.stdout)
    local origin = m_facts.pr_origin_fact(current_pr.comments)
    devloop_logging.log_forged_markers("review_pr", reviewing.proposal_id, current_pr.comments)
    local state = require("devloop.entity").current_entity_state(current_pr.comments, reviewing.proposal_id)
    local current_state = state or {}
    local snapshot = review_pr_caps.restart_effects.seal_snapshot({
      owner = review_pr_caps.restart_package_name,
      entity = { kind = "pr", repo = repo, number = reviewing.pr_number },
      proposal_id = reviewing.proposal_id,
      current = state,
      snapshot_fingerprint = table.concat({
        "pr-review-activation",
        reviewing.proposal_id,
        current_state.state or "missing",
        current_state.version or "missing",
        reviewing.version,
      }, "|"),
      lock_epoch = lock_key .. "@" .. tostring(current_state.version or reviewing.version),
      generation = current_state.version or reviewing.version,
    })
    local function decide(handoff)
      return review_pr_caps.restart_effects.decide_transition(snapshot, {
        semantic_variant = "review_receiver",
        source_boundary = "github-devloop-pr.devloop_reviewing",
        target = "reviewing",
        evidence_refs = handoff == nil
          and { "devloop.entity.current_entity_state" }
          or { "devloop.entity.current_entity_state", "payloads_predicates.verified_hand_off_state" },
        reviewing_version = reviewing.version,
        handoff = handoff,
      })
    end
    local transition = decide(nil)
    review_pr_caps.restart_effects.assert_decision_admissible(
      transition,
      "github-devloop: restart-effect-decision-illegal: review activation admission rejected"
    )
    if transition.status == "pending" or transition.reason_code == "version-mismatch" then
      local verified_state = nil
      local hand_off_reason = "missing"
      local handoff = nil
      if reviewing.reviewing_hand_off ~= nil then
        verified_state, hand_off_reason = payloads_predicates.verified_hand_off_state(core, repo, reviewing.reviewing_hand_off, {
          proposal_id = reviewing.proposal_id,
          state = "reviewing",
          marker_version = reviewing.version,
          event_version = reviewing.version,
        })
        handoff = { status = verified_state ~= nil and "valid" or "invalid" }
        transition = decide(handoff)
        review_pr_caps.restart_effects.assert_decision_admissible(
          transition,
          "github-devloop: restart-effect-decision-illegal: review activation handoff admission rejected"
        )
      end
      if verified_state ~= nil then
        state = verified_state
        devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", transition.cas_outcome, "reviewing marker comment verified by direct id lookup")
      else
        if reviewing.reviewing_hand_off ~= nil then
          devloop_logging.log_line("info", "review_pr", reviewing.proposal_id, "HANDOFF", {
            "state=reviewing",
            "outcome=verify-failed",
            "reason=" .. tostring(hand_off_reason),
          })
        end
        if transition.reason_code == "version-mismatch" then
          devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", transition.cas_outcome, "reviewing event version does not match canonical issue marker")
          return
        end
        devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", transition.cas_outcome, "reviewing state marker not yet visible")
        error("github-devloop: pr-review-marker-missing: reviewing state marker not yet visible for PR review; retrying")
      end
    end
    if transition.status == "stale" then
      devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", transition.cas_outcome, "issue is not currently reviewing")
      return
    end

    if transition.status ~= "apply" then
      error("github-devloop: restart-effect-decision-illegal: unsupported review activation admission status: "
        .. tostring(transition.status))
    end

    if not require("devloop.pr_safety").is_safe_head_sha(current_pr.head_sha) then
      error("github-devloop: pr-review-head-unsafe: gh pr review head view returned unsafe head sha")
    end
    if tostring(current_pr.state or ""):lower() ~= "open" then
      devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", "skip-stale(pr-closed)", "re-derived PR is not open")
      return
    end
    local pr_source_ref = entity_lib.pr_source_ref(repo, reviewing.pr_number)

    local current_issue = {
      title = "PR #" .. tostring(reviewing.pr_number),
      body = "(PR-only review context; issue backing is absent)",
      comments = current_pr.comments,
    }
    if issue_number ~= nil then
      local issue_view = devloop_commands.gh_issue_view_review(repo, issue_number, 30)
      if issue_view.exit_code ~= 0 then
        error("github-devloop: gh-issue-review-view-failed: gh issue review view failed: " .. tostring(issue_view.stderr))
      end
      current_issue = parsers_issue.parse_issue_view_review(core, issue_view.stdout)
    end
    if not m_claims.verify_pr_review_issue_claim("review_pr", repo, issue_number, current_issue, reviewing.proposal_id) then
      return
    end
    local review_id = devloop_base.pr_review_proposal_id(repo, reviewing.pr_number, reviewing.version, current_pr.head_sha)
    local review_dedup_key = base_ids.dedup_key({ review_id, "review" })
    local context_fetch = { context_bundle.context_fetch_ref_from_bundle(core, {
      dept = "review_pr",
      repo = repo,
      issue_number = issue_number,
      pr_number = reviewing.pr_number,
      proposal_id = review_id,
      version = review_dedup_key,
      tick = event.ts,
    }) }
    local content_fetch = context_fetch[1]
    local high_risk = context_fetch[2]
    local risk = context_fetch[3]
    if no_legitimate_diff.risk_is_empty_diff(risk) then
      no_legitimate_diff.raise_closed_unmerged("review_pr", core, repo, reviewing.pr_number, reviewing.proposal_id, state, pr_source_ref)
      return
    end
    local proposal = payloads_builders.build_board_pr_review_proposal(core, repo, issue_number, reviewing.pr_number, reviewing.version, current_pr.head_sha, current_issue, pr_source_ref, event.ts, current_pr.comments, content_fetch, high_risk)
    if reviewing.review_delivery_dedup_key ~= nil then
      if devloop_base.pr_review_proposal_id_from_redrive_delivery_dedup_key(
        reviewing.review_delivery_dedup_key
      ) ~= review_id then
        error("github-devloop: pr-review-redrive-dedup-mismatch: review redrive delivery identity does not match the current PR review")
      end
      proposal.dedup_key = reviewing.review_delivery_dedup_key
    end
    -- Fall back to the read-only project checkout (".") if the ephemeral impl worktree is gone (restart);
    -- see review_loop -- the review codex reads the PR diff from context, so cwd just needs to be a git repo.
    local worktree = devloop_commands.existing_implementation_worktree(repo, issue_number, origin and origin.impl_version or reviewing.version)
    proposal.worktree = worktree or "."
    if not v_validate_proposal.validate_proposal(proposal) then
      log.warn("github-devloop dept=review_pr proposal_id=" .. tostring(reviewing.proposal_id) .. " tag=SKIP reason=cannot-build-valid-review-proposal")
      return
    end

    devloop_logging.log_cas_decision("review_pr", reviewing.proposal_id, state, "reviewing", "review-proposal", "applied", "raising PR diff review proposal")
    local raised = { "consensus.proposal" }
    devloop_logging.log_apply("review_pr", reviewing.proposal_id, nil, nil, { add = {}, remove = {} }, raised)
    devloop_logging.log_raise("review_pr", reviewing.proposal_id, "consensus.proposal", proposal)
  end)
end, wrap = devloop_logging.wrap_pipeline_failure, name = "review_pr" })
