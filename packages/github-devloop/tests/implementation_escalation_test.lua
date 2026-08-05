local h = require("tests.devloop_helpers")
local escalation = require("devloop.implementation_escalation")
local replay_fields = require("devloop.replay_fields")
local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/github-devloop/issue/owner/repo/42/intake/123"
local head_a = "1111111111111111111111111111111111111111"
local head_b = "2222222222222222222222222222222222222222"

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-04T01:00:00Z",
  }
end

local function attempt(attempt_number, start_head, finish_head, result)
  return escalation.attempt_result({
    proposal_id = proposal_id,
    version = version,
    attempt = attempt_number,
    start_head_sha = start_head,
    finish_head_sha = finish_head,
    worker_result = result,
  })
end

return {
  test_typed_engine_timeout_is_preserved_as_wall_clock_exhaustion = function()
    local fact = attempt(1, nil, head_a, {
      exit_code = 124,
      error_kind = "timeout",
    })

    t.eq(fact.worker_outcome, "wall-clock-exhausted")
    t.eq(fact.progress, "unmeasured")
  end,

  test_exit_code_alone_does_not_claim_typed_timeout_evidence = function()
    local fact = attempt(1, nil, head_a, {
      exit_code = 124,
    })

    t.eq(fact.worker_outcome, "worker-failed")
  end,

  test_consecutive_timeout_count_without_stationary_progress_does_not_escalate = function()
    local previous = attempt(1, nil, head_a, { exit_code = 124, error_kind = "timeout" })
    local current = attempt(2, head_a, head_b, { exit_code = 124, error_kind = "timeout" })
    local comments = {
      trusted_comment(escalation.attempt_result_marker(previous)),
    }

    t.eq(escalation.escalation_evidence(comments, current), nil)
  end,

  test_adjacent_typed_timeouts_with_continuous_stationary_head_escalate = function()
    local previous = attempt(1, nil, head_a, { exit_code = 124, error_kind = "timeout" })
    local current = attempt(2, head_a, head_a, { exit_code = 124, error_kind = "timeout" })
    local comments = {
      trusted_comment(escalation.attempt_result_marker(previous)),
    }

    local evidence = escalation.escalation_evidence(comments, current)

    t.eq(evidence.policy_id, "adjacent-wall-clock-exhaustion-stationary-head-v1")
    t.eq(evidence.previous_attempt, 1)
    t.eq(evidence.attempt, 2)
    t.eq(evidence.head_sha, head_a)
    local payload = escalation.build_payload({
      proposal_id = proposal_id,
      version = version,
      branch = "devloop-owner-repo-42-123",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    }, evidence)
    t.eq(escalation.is_supported_payload(payload), true)
  end,

  test_escalation_marker_round_trips_only_from_trusted_comments = function()
    local evidence = {
      policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
      previous_attempt = 1,
      attempt = 2,
      head_sha = head_a,
    }
    local marker = escalation.escalation_marker(proposal_id, version, evidence)

    t.eq(escalation.escalation_fact({ { body = marker, author_login = "attacker" } }, proposal_id, version), nil)
    local fact = escalation.escalation_fact({ trusted_comment(marker) }, proposal_id, version)
    t.eq(fact.attempt, 2)
    t.eq(fact.head_sha, head_a)
  end,

  test_pre_pr_decomposition_plan_is_strict_and_bounded = function()
    local plan = escalation.parse_decomposition_plan(
      '{"issues":[{"title":"Extract parser","body":"Scope the parser change."}]}'
    )

    t.eq(#plan, 1)
    t.eq(plan[1].title, "Extract parser")
    t.eq(escalation.parse_decomposition_plan('{"issues":[] }'), nil)
    t.eq(escalation.parse_decomposition_plan('{"issues":"not-an-array"}'), nil)
  end,

  test_pre_pr_child_request_creates_native_and_blocked_by_edges = function()
    local payload = escalation.build_payload({
      proposal_id = proposal_id,
      version = version,
      branch = "devloop-owner-repo-42-123",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    }, {
      policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
      previous_attempt = 1,
      attempt = 2,
      head_sha = head_a,
    })

    local request = escalation.build_child_issue_request("owner/repo", 42, payload, {
      title = "Extract parser",
      body = "Scope the parser change.",
    }, 1)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.parent, 42)
    t.eq(request.parent_comment_target.issue_number, 42)
    t.eq(request.post_create_blocked_by.blocked_issue_number, 42)
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
  end,

  test_parent_waits_until_every_planned_child_is_created_and_linked = function()
    local payload = escalation.build_payload({
      proposal_id = proposal_id,
      version = version,
      branch = "devloop-owner-repo-42-123",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    }, {
      policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
      previous_attempt = 1,
      attempt = 2,
      head_sha = head_a,
    })
    local request = escalation.build_child_issue_request("owner/repo", 42, payload, {
      title = "Extract parser",
      body = "Scope the parser change.",
    }, 1)
    local created = '<!-- fkst:github-proxy:issue-created:v1 dedup="'
      .. request.dedup_key .. '" issue="101" -->'
    local linked = '<!-- fkst:github-proxy:blocked-by:v1 dedup="'
      .. request.post_create_blocked_by.dedup_key .. '" blocked="42" blocking="101" -->'

    t.eq(escalation.child_linkage_fact({ trusted_comment(created) }, "owner/repo", 42, payload, 1), nil)
    local fact = escalation.child_linkage_fact({ trusted_comment(created .. "\n" .. linked) },
      "owner/repo", 42, payload, 1)
    t.eq(fact.count, 1)
    t.eq(fact.issue_numbers[1], 101)
  end,

  test_implementation_escalating_has_one_nonterminal_supervisor_contract = function()
    local row = replay_fields.restart_transition_row(
      h.core.restart_transition_table(), "implementation-escalating")

    t.is_true(row ~= nil)
    t.eq(row.terminal, false)
    t.eq(row.driving_queue, "github-devloop-decompose.devloop_implementation_decompose")
    t.eq(row.responsibility_signature.receiver_kind, "decomposition-supervisor")
    t.eq(row.liveness_contract.real_execution.match.role, "decompose")
    t.eq(table.concat(row.to_states, ","), "dependency_wait,ready")
  end,
}
