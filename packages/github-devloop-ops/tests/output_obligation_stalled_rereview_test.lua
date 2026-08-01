local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local conv_reconcile = require("devloop.convergence.reconcile")
local conv_rounds = require("devloop.convergence.rounds")
local convergence_shared = require("devloop.convergence.shared")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local marker_builders = require("devloop.markers.builders")
local transition_version = require("contract.transition_version")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "ready/2026-07-27T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local reviewing_version = "implement/2026-07-27T12-00-00Z/review-loop/3"
local pr_number = 77
local pr_branch = "devloop-owner-repo-42-live-recovery"
local pr_head_sha = "abcdef1234567890abcdef1234567890abcdef12"

local marker_core = {
  liveness_heartbeat_version = function(version)
    return transition_version.safe_version_segment(version)
  end,
  liveness_signal_producer_contract = function(family)
    t.eq(family, "review-converge-round")
    return { version_form = "safe_version_segment" }
  end,
}

local function bot_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-07-27T12:10:00Z",
  }
end

local function source_timeout_marker()
  return conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
    terminal_version = terminal_version,
    from_state = "ready",
    from_version = ready_version,
    attempt = 3,
    attempt_limit = 3,
    driving_queue = "github-devloop.devloop_ready",
    reason_class = "state-output-obligation-timeout",
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  })
end

local function stalled_review_markers()
  local review_proposal = devloop_base.pr_review_proposal_id(
    repo,
    pr_number,
    reviewing_version,
    pr_head_sha
  )
  local review_version = transition_version.safe_version_segment(reviewing_version)
  local source_digest = convergence_shared.source_ref_digest(entity_lib.pr_source_ref(repo, pr_number))
  local angles = {
    { angle = "fidelity", verdict = "abstain", digest = "same-review-digest" },
  }
  local markers = {}
  for round = 1, 3 do
    table.insert(markers, bot_comment(conv_rounds.review_converge_round_marker(
      marker_core,
      review_proposal,
      proposal_id,
      review_version,
      pr_head_sha,
      source_digest,
      round,
      "review-loop/" .. tostring(round),
      "Same review question",
      angles
    )))
  end
  return markers
end

local function source_issue()
  return {
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    state = "OPEN",
    labels = { core._blocked_label },
    comments = {
      bot_comment(marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        "intake/github-devloop/issue/owner/repo/42/original",
        "standard"
      )),
      bot_comment(source_timeout_marker()),
      bot_comment(core.state_marker(proposal_id, "blocked", terminal_version)),
      bot_comment(marker_builders.pr_delegation_marker(
        proposal_id,
        entity_lib.pr_proposal_id(repo, pr_number),
        pr_number,
        ready_version,
        "g1"
      )),
    },
  }
end

local function stalled_snapshot()
  local comments = {
    bot_comment(marker_builders.pr_origin_marker(
      proposal_id,
      "42",
      pr_branch,
      ready_version,
      "dev"
    )),
    bot_comment(core.state_marker(proposal_id, "reviewing", reviewing_version)),
  }
  for _, marker in ipairs(stalled_review_markers()) do
    table.insert(comments, marker)
  end
  return {
    comments = {},
    prs = {
      {
        number = pr_number,
        link = {
          kind = "delegation",
          pr_number = pr_number,
          pr_proposal_id = entity_lib.pr_proposal_id(repo, pr_number),
          version = ready_version,
          delegation = "g1",
        },
        current = {
          state = "OPEN",
          head_ref_name = pr_branch,
          head_sha = pr_head_sha,
          base_ref_name = "dev",
          head_repository = repo,
          is_cross_repository = false,
          comments = comments,
        },
      },
    },
    absent_prs = {},
  }
end

return {
  test_stalled_reviewing_pr_is_a_rereview_target = function()
    local fact = {
      proposal_id = proposal_id,
      terminal_version = terminal_version,
      dedup_key = "output-obligation/stalled-rereview",
      reason_class = "state-output-obligation-timeout",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
      source_repo = repo,
      source_issue_number = 42,
      escalation_repo = repo,
      escalation_issue_number = 900,
      escalation_source_ref = { kind = "external", ref = "owner/repo#issue/900" },
    }

    local decision = core.output_obligation_resolution_decision(
      fact,
      { comments = {} },
      source_issue(),
      stalled_snapshot()
    )

    t.eq(decision.decision, "rereview")
    t.eq(decision.action, "command")
    t.eq(decision.request.pr_number, pr_number)
    t.is_true(decision.request.body:find("fkst: rereview", 1, true) == 1)
  end,
}
