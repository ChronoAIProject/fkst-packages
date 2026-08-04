local fixture = require("tests.dependency_cascade_helpers")
local devloop_base = fixture.devloop_base
local base_ids = fixture.base_ids
local h = fixture.h
local t = fixture.t
local core = fixture.core
local entity_read_mocks = fixture.entity_read_mocks
local gh_argv = fixture.gh_argv
local m_builders = fixture.m_builders
local repo = fixture.repo
local proposal_id = fixture.proposal_id
local version = fixture.version
local source_ref = fixture.source_ref
local encode_json_string = fixture.encode_json_string
local render_comment = fixture.render_comment
local issue_comments_json = fixture.issue_comments_json
local issue_view_json = fixture.issue_view_json
local observe_issue_state_json = fixture.observe_issue_state_json
local blocked_by_json = fixture.blocked_by_json
local mock_blocked_by = fixture.mock_blocked_by
local mock_blocked_by_failure = fixture.mock_blocked_by_failure
local mock_blocked_by_malformed = fixture.mock_blocked_by_malformed
local mock_blocked_by_truncated = fixture.mock_blocked_by_truncated
local mock_blocker_issue = fixture.mock_blocker_issue
local dependency_waiver_comment = fixture.dependency_waiver_comment
local mock_blocker_issue_failure = fixture.mock_blocker_issue_failure
local mock_blocker_issue_with_pr_link = fixture.mock_blocker_issue_with_pr_link
local mock_blocker_pr = fixture.mock_blocker_pr
local mock_blocker_pr_failure = fixture.mock_blocker_pr_failure
local mock_result_issue = fixture.mock_result_issue
local mock_observe_issue = fixture.mock_observe_issue
local mock_implement_issue = fixture.mock_implement_issue
local mock_repo = fixture.mock_repo
local mock_liveness_issue_list = fixture.mock_liveness_issue_list
local mock_liveness_pr_list = fixture.mock_liveness_pr_list
local reached = fixture.reached
local run_result = fixture.run_result
local run_observe = fixture.run_observe
local run_liveness_scan = fixture.run_liveness_scan
local run_implement = fixture.run_implement
local find_raise = fixture.find_raise
local has_queue = fixture.has_queue
local count_queue = fixture.count_queue
local has_marker = fixture.has_marker
local count_calls = fixture.count_calls
local marker_body = fixture.marker_body
local ready_handoff_raise = fixture.ready_handoff_raise

return {
  test_consensus_result_holds_for_unmet_dependency = function()
    mock_result_issue()
    mock_blocked_by(42, { { number = 51 } })
    mock_blocked_by(51, {})
    mock_blocker_issue(51, "ready")
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-wait:v1"))
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      return h.has_value(payload.add_labels, "fkst-dev:blocked-on-dependency")
    end)
    t.is_true(label ~= nil)
  end,

  test_consensus_result_raises_ready_for_satisfied_dependency = function()
    mock_result_issue()
    mock_blocked_by(42, { { number = 52 } })
    mock_blocked_by(52, {})
    mock_blocker_issue(52, "merged")
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(result.raises) ~= nil)
  end,

  test_observe_issue_ready_holds_then_cascades_when_satisfied = function()
    mock_observe_issue()
    mock_blocked_by(42, { { number = 53 } })
    mock_blocked_by(53, {})
    mock_blocker_issue(53, "ready")
    local held = run_observe()
    t.eq(held.exit_code, 0)
    t.eq(has_queue(held.raises, "devloop_ready"), false)
    t.is_true(has_marker(held.raises, "fkst:github-devloop:dependency-wait:v1"))

    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 53 }),
      }
    )
    mock_blocked_by(42, { { number = 53 } })
    mock_blocked_by(53, {})
    mock_blocker_issue(53, "merged")
    local cascaded = run_observe()
    t.eq(cascaded.exit_code, 0)
    t.eq(has_queue(cascaded.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(cascaded.raises) ~= nil)
    t.is_true(has_marker(cascaded.raises, "fkst:github-devloop:dependency-release:v1"))
    local clear = ready_handoff_raise(cascaded.raises).payload.handoff.label_request
    t.is_true(clear ~= nil)
    t.is_true(h.has_value(clear.remove_labels, "fkst-dev:blocked-on-dependency"))
  end,

  test_legacy_ready_cycle_hold_canonicalizes_to_dependency_wait = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "ready", version),
        "github-devloop dependency hold: cycle\n\nReason: dependency-cycle\n\n"
          .. core.dependency_cycle_marker(proposal_id, version),
      }
    )
    mock_blocked_by(42, { { number = 54 } })
    mock_blocked_by(54, { { number = 42 } })
    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    local split_version = core.ready_split_version(version)
    local body = marker_body(result.raises, "ready-split-canonicalized:v1")
    t.is_true(body ~= nil)
    t.is_true(body:find('derived_state="dependency_wait"', 1, true) ~= nil)
    t.is_true(body:find('state="dependency_wait"', 1, true) ~= nil)
    t.is_true(body:find('version="' .. split_version .. '"', 1, true) ~= nil)
    t.is_true(body:find("fkst:github-devloop:dependency-wait:v1", 1, true) ~= nil)
  end,

  test_legacy_ready_satisfied_split_raises_ready_at_split_version_once = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "ready", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 53 }),
      }
    )
    mock_blocked_by(42, { { number = 53 } })
    mock_blocked_by(53, {})
    mock_blocker_issue(53, "merged")
    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(count_queue(result.raises, "devloop_ready"), 0)
    local split_version = core.ready_split_version(version)
    local ready_comment = ready_handoff_raise(result.raises)
    t.is_true(ready_comment ~= nil)
    t.eq(ready_comment.payload.handoff.marker_version, split_version)
    local body = marker_body(result.raises, "ready-split-canonicalized:v1")
    t.is_true(body ~= nil)
    t.is_true(body:find('state="ready"', 1, true) ~= nil)
    t.is_true(body:find('version="' .. split_version .. '"', 1, true) ~= nil)
  end,

  test_liveness_scan_reinjected_dependency_hold_uses_observe_gate = function()
    mock_repo()
    mock_liveness_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_liveness_pr_list({})
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 53 }),
      }
    )
    local scanned = run_liveness_scan()
    t.eq(scanned.exit_code, 0)
    local changed = find_raise(scanned.raises, "devloop_observe_issue")
    t.is_true(changed ~= nil)

    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 53 }),
      }
    )
    mock_blocked_by(42, { { number = 53 } })
    mock_blocked_by(53, {})
    mock_blocker_issue(53, "merged")
    local observed = h.run_department("departments/observe_issue/main.lua", {
      queue = "devloop_observe_issue",
      payload = h.issue({
        dedup_key = changed.payload.dedup_key,
        source_ref = changed.payload.source_ref,
      }),
    }, h.opts("dependency-liveness-observe"))
    t.eq(observed.exit_code, 0)
    t.eq(has_queue(observed.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(observed.raises) ~= nil)
    t.is_true(has_marker(observed.raises, "fkst:github-devloop:dependency-release:v1"))
  end,

  test_consensus_result_releases_not_planned_blocker_with_void_audit = function()
    mock_result_issue()
    mock_blocked_by(42, { { number = 56, state = "CLOSED", state_reason = "NOT_PLANNED" } })
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(result.raises) ~= nil)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-release:v1"))
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-void:v1"))
    t.is_true(has_marker(result.raises, 'blocker="56"'))
  end,

  test_observe_issue_hold_releases_not_planned_blocker_with_void_audit = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 57 }),
      }
    )
    mock_blocked_by(42, { { number = 57, state = "CLOSED", state_reason = "NOT_PLANNED" } })
    local released = run_observe()
    t.eq(released.exit_code, 0)
    t.eq(has_queue(released.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(released.raises) ~= nil)
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-release:v1"))
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-void:v1"))
    local clear = ready_handoff_raise(released.raises).payload.handoff.label_request
    t.is_true(clear ~= nil)
    t.is_true(h.has_value(clear.remove_labels, "fkst-dev:blocked-on-dependency"))
  end,

  test_consensus_result_holds_completed_blocker_without_waiver = function()
    mock_result_issue()
    mock_blocked_by(42, { { number = 58, state = "CLOSED", state_reason = "COMPLETED" } })
    mock_blocker_issue(58, "ready")
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-wait:v1"))
    t.is_true(has_marker(result.raises, 'reason="dependency-waiver-required"'))
  end,

  test_trusted_dependency_waiver_command_creates_waiver_and_requeues_ready = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "fkst: dependency-waiver 60",
        "github-devloop dependency hold: waiting\n\nReason: dependency-waiver-required\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 60 }, "waiting", "dependency-waiver-required"),
      }
    )
    mock_blocked_by(42, { { number = 60, state = "CLOSED", state_reason = "COMPLETED" } })
    mock_blocker_issue(60, "ready")
    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    local split_version = core.ready_split_version(version)
    local ready_comment = ready_handoff_raise(result.raises)
    t.is_true(ready_comment ~= nil)
    t.eq(ready_comment.payload.handoff.marker_version, split_version)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-waiver:v1"))
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-release:v1"))
    t.is_true(has_marker(result.raises, "fkst:github-devloop:ready-split-canonicalized:v1"))
    t.is_true(has_marker(result.raises, 'state="ready"'))
    t.is_true(has_marker(result.raises, 'version="' .. split_version .. '"'))
    t.is_true(has_marker(result.raises, "fkst:github-devloop:operator-command:v1"))
    t.is_true(has_marker(result.raises, 'command="dependency-waiver"'))
    t.is_true(has_marker(result.raises, 'blocker="60"'))
    t.is_true(has_marker(result.raises, 'reason="operator-waiver"'))
  end,

  test_observe_issue_releases_completed_blocker_with_waiver = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        dependency_waiver_comment(59),
        "github-devloop dependency hold: waiting\n\nReason: dependency-waiver-required\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 59 }, "waiting", "dependency-waiver-required"),
      }
    )
    mock_blocked_by(42, { { number = 59, state = "CLOSED", state_reason = "COMPLETED" } })
    mock_blocker_issue(59, "ready")
    local released = run_observe()
    t.eq(released.exit_code, 0)
    t.eq(has_queue(released.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(released.raises) ~= nil)
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-release:v1"))
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-waiver:v1"))
    t.is_true(has_marker(released.raises, 'blocker="59"'))
    t.is_true(has_marker(released.raises, 'reason="completed_without_merged_marker"'))
  end,

  test_observe_issue_existing_hold_still_waiting_does_not_refresh = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 7 }),
      }
    )
    mock_blocked_by(42, { { number = 7 } })
    mock_blocked_by(7, {})
    mock_blocker_issue(7, "ready")
    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(count_queue(result.raises, "github-proxy.github_issue_comment_request"), 0)
    t.eq(count_queue(result.raises, "github-proxy.github_issue_label_request"), 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
  end,

  test_cycle_holds_with_cycle_marker = function()
    mock_result_issue()
    mock_blocked_by(42, { { number = 54 } })
    mock_blocked_by(54, { { number = 42 } })
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-cycle:v1"))
  end,

  test_unresolvable_holds_fail_closed = function()
    mock_result_issue()
    mock_blocked_by_malformed(42)
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(has_marker(result.raises, "fkst:github-devloop:dependency-unresolvable:v1"))
  end,

  test_dependency_hold_fact_reads_marker_semantics_not_prose = function()
    local gh_failed = core.dependency_hold_fact({
      core.state_marker(proposal_id, "ready", version),
      "localized prose and arbitrary reason noise\n\n"
        .. core.dependency_unresolvable_marker(proposal_id, version, { 42 }, "unresolvable", "gh-failed"),
    }, proposal_id)
    t.eq(gh_failed.marker_kind, "dependency-unresolvable")
    t.eq(gh_failed.hold_kind, "unresolvable")
    t.eq(gh_failed.reason, "gh-failed")

    local old_gh_failed = core.dependency_hold_fact({
      core.state_marker(proposal_id, "dependency_wait", version),
      "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
        .. core.dependency_wait_marker(proposal_id, version, { 42 }),
    }, proposal_id)
    t.eq(old_gh_failed.marker_kind, "dependency-wait")
    t.eq(old_gh_failed.hold_kind, "waiting")
    t.eq(old_gh_failed.reason, "waiting-on-dependency")

    local attr_gh_failed = core.dependency_hold_fact({
      core.state_marker(proposal_id, "ready", version),
      "localized prose and arbitrary reason noise\n\n"
        .. core.dependency_wait_marker(proposal_id, version, { 42 }, "unresolvable", "gh-failed"),
    }, proposal_id)
    t.eq(attr_gh_failed.marker_kind, "dependency-wait")
    t.eq(attr_gh_failed.hold_kind, "unresolvable")
    t.eq(attr_gh_failed.reason, "gh-failed")

    local cycle = core.dependency_hold_fact({
      core.state_marker(proposal_id, "ready", version),
      "localized prose and arbitrary reason noise\n\n"
        .. core.dependency_cycle_marker(proposal_id, version),
    }, proposal_id)
    t.eq(cycle.marker_kind, "dependency-cycle")
    t.eq(cycle.reason, "dependency-cycle")
  end,

  test_gh_failed_hold_rechecks_and_releases_on_next_poll = function()
    mock_observe_issue()
    mock_blocked_by_failure(42)
    local held = run_observe()
    t.eq(held.exit_code, 0)
    t.eq(has_queue(held.raises, "devloop_ready"), false)
    t.is_true(has_marker(held.raises, 'hold_kind="unresolvable"'))
    t.is_true(has_marker(held.raises, 'reason="gh-failed"'))

    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
          .. core.dependency_unresolvable_marker(proposal_id, version, { 42 }),
      }
    )
    mock_blocked_by(42, {})
    local released = run_observe()
    t.eq(released.exit_code, 0)
    t.eq(has_queue(released.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(released.raises) ~= nil)
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-release:v1"))
    local clear = ready_handoff_raise(released.raises).payload.handoff.label_request
    t.is_true(clear ~= nil)
    t.is_true(h.has_value(clear.remove_labels, "fkst-dev:blocked-on-dependency"))
  end,

  test_old_gh_failed_wait_hold_rechecks_and_releases_on_next_poll = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 42 }),
      }
    )
    mock_blocked_by(42, {})
    local released = run_observe()
    t.eq(released.exit_code, 0)
    t.eq(has_queue(released.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(released.raises) ~= nil)
    t.is_true(has_marker(released.raises, "fkst:github-devloop:dependency-release:v1"))
  end,

  test_non_hold_state_clears_stale_dependency_label = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:implementing", "fkst-dev:blocked-on-dependency" },
      {
        core.state_marker(proposal_id, "implementing", "ready-consensus-github-devloop-issue-owner-repo-42-2026-06-03T01-02-03Z"),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 7 }),
      }
    )
    local result = run_observe()
    t.eq(result.exit_code, 0)
    local clear = find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      return h.has_value(payload.remove_labels, "fkst-dev:blocked-on-dependency")
    end)
    t.is_true(clear ~= nil)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
  end,

  test_implement_backstop_moves_ready_to_dependency_wait = function()
    mock_blocked_by(42, { { number = 55 } })
    mock_blocked_by(55, {})
    mock_blocker_issue(55, "ready")
    mock_implement_issue()
    local result = run_implement()
    t.eq(result.exit_code, 0)
    t.is_true(has_marker(result.raises, 'state="dependency_wait"'))
  end,

  test_no_blockers_unaffected = function()
    mock_result_issue()
    mock_blocked_by(42, {})
    local result = run_result()
    t.eq(result.exit_code, 0)
    t.eq(has_queue(result.raises, "devloop_ready"), false)
    t.is_true(ready_handoff_raise(result.raises) ~= nil)
  end,
}
