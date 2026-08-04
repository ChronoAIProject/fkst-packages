local h = require("tests.devloop_helpers")
local escalation = require("devloop.implementation_escalation")
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
}
