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
  test_dependency_graphql_contract_is_named = function()
    local operations = core.github_graphql_queries

    t.eq(type(operations), "table")
    t.eq(type(operations.dependency_blocked_by), "string")
    t.eq(operations.dependency_blocked_by:find("blockedBy(first:50)", 1, true) ~= nil, true)
    t.eq(operations.dependency_blocked_by:find("nodes{number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}}}", 1, true) ~= nil, true)
    t.eq(
      core.render_github_graphql_query("dependency_blocked_by", {
        owner = "owner",
        name = "repo",
        issue_number = 42,
      }),
      '{repository(owner:"owner",name:"repo"){issue(number:42){number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}} blockedBy(first:50){totalCount pageInfo{hasNextPage} nodes{number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}}}}}}}'
    )
  end,

  test_dependency_gate_satisfied_without_blockers = function()
    mock_blocked_by(42, {})
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, true)
    t.eq(gate.kind, "satisfied")
  end,

  test_dependency_gate_holds_until_expected_blocked_by_edge_is_source_visible = function()
    mock_blocked_by(42, {})
    local gate = core.dependency_gate(repo, 42, {
      proposal_id = proposal_id,
      version = version,
      comments = {
        core.state_marker(proposal_id, "dependency_wait", version),
        core.dependency_wait_marker(
          proposal_id, version, { 99 }, "expected-edge", "precursor-edge-not-visible"),
      },
    })

    t.eq(gate.ok, false)
    t.eq(gate.kind, "waiting")
    t.eq(gate.reason, "dependency-edge-not-visible")
    t.eq(gate.unmet[1], 99)
  end,

  test_dependency_markers_are_versioned_and_bounded = function()
    t.eq(
      core.dependency_wait_marker(proposal_id, "v1", { 1, 2, 3 }),
      '<!-- fkst:github-devloop:dependency-wait:v1 proposal="github-devloop/issue/owner/repo/42" version="v1" hold_kind="waiting" reason="waiting-on-dependency" unmet="1,2,3" -->'
    )
    t.eq(
      core.dependency_cycle_marker(proposal_id, "v1"),
      '<!-- fkst:github-devloop:dependency-cycle:v1 proposal="github-devloop/issue/owner/repo/42" version="v1" -->'
    )
    t.eq(
      core.dependency_unresolvable_marker(proposal_id, "v1", { 1, 2, 3 }),
      '<!-- fkst:github-devloop:dependency-unresolvable:v1 proposal="github-devloop/issue/owner/repo/42" version="v1" hold_kind="unresolvable" reason="gh-failed" unmet="1,2,3" -->'
    )
    t.eq(
      core.dependency_release_marker(proposal_id, "v1"),
      '<!-- fkst:github-devloop:dependency-release:v1 proposal="github-devloop/issue/owner/repo/42" version="v1" -->'
    )
  end,

  test_dependency_gate_waiting_for_open_blocker = function()
    mock_blocked_by(42, { { number = 11 } })
    mock_blocked_by(11, {})
    mock_blocker_issue(11, "ready")
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "waiting")
    t.eq(gate.unmet[1], 11)
  end,

  test_dependency_gate_satisfied_for_merged_blocker = function()
    mock_blocked_by(42, { { number = 12 } })
    mock_blocked_by(12, {})
    mock_blocker_issue(12, "merged")
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, true)
    t.eq(gate.kind, "satisfied")
  end,

  test_dependency_gate_caches_terminal_merged_blocker = function()
    mock_blocked_by(42, { { number = 17, state = "CLOSED" } })
    mock_blocked_by_failure(17)
    mock_blocker_issue(17, "merged")
    local first = core.dependency_gate(repo, 42)
    t.eq(first.ok, true)
    t.eq(first.kind, "satisfied")
    local graphql_calls_after_first = count_calls("gh api graphql")
    t.eq(graphql_calls_after_first, 1)

    mock_blocked_by(42, { { number = 17, state = "CLOSED" } })
    mock_blocked_by_failure(17)
    local second = core.dependency_gate(repo, 42)
    t.eq(second.ok, true)
    t.eq(second.kind, "satisfied")
    t.eq(count_calls("gh api graphql"), graphql_calls_after_first + 1)

    mock_blocked_by(42, { { number = 17, state = "CLOSED" }, { number = 18 } })
    mock_blocked_by(18, {})
    mock_blocker_issue(18, "ready")
    local changed_root_edges = core.dependency_gate(repo, 42)
    t.eq(changed_root_edges.ok, false)
    t.eq(changed_root_edges.kind, "waiting")
    t.eq(changed_root_edges.unmet[1], 18)

    mock_blocked_by(42, { { number = 17, state = "CLOSED" } })
    mock_blocked_by(17, {})
    mock_blocker_issue_failure(17)
    local third = core.dependency_gate(repo, 42)
    t.eq(third.ok, true)
    t.eq(third.kind, "satisfied")

    t.eq(core.merged_blocker_cache_key(repo, 17), "github-devloop/dependency/merged/owner/repo/issue/17")
  end,

  test_dependency_gate_does_not_cache_waiting_blocker = function()
    local graphql_calls_before = count_calls("gh api graphql")
    mock_blocked_by(42, { { number = 27 } })
    mock_blocked_by(27, {})
    mock_blocker_issue(27, "ready")
    local first = core.dependency_gate(repo, 42)
    t.eq(first.ok, false)
    t.eq(first.kind, "waiting")
    t.eq(first.unmet[1], 27)

    mock_blocked_by(42, { { number = 27 } })
    mock_blocked_by(27, {})
    mock_blocker_issue(27, "ready")
    local second = core.dependency_gate(repo, 42)
    t.eq(second.ok, false)
    t.eq(second.kind, "waiting")
    t.eq(second.unmet[1], 27)
    t.eq(count_calls("gh api graphql"), graphql_calls_before + 4)
  end,

  test_dependency_gate_satisfied_for_pr_stream_merged_blocker = function()
    mock_blocked_by(42, { { number = 31, state = "CLOSED" } })
    mock_blocked_by_failure(31)
    local link = mock_blocker_issue_with_pr_link(31, 32, "pr-open")
    mock_blocker_pr(31, 32, link, {
      m_builders.pr_origin_marker(link.proposal_id, 31, link.branch, link.impl_version, link.base_branch),
      core.state_marker(link.proposal_id, "merged", "merge-version-7"),
      m_builders.merged_marker(core, link.proposal_id, 32, "merge-version-7", "def456"),
    })
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, true)
    t.eq(gate.kind, "satisfied")
  end,

  test_dependency_gate_waits_when_linked_pr_has_no_merged_fact = function()
    mock_blocked_by(42, { { number = 33 } })
    mock_blocked_by(33, {})
    local link = mock_blocker_issue_with_pr_link(33, 34, "pr-open")
    mock_blocker_pr(33, 34, link, {
      m_builders.pr_origin_marker(link.proposal_id, 33, link.branch, link.impl_version, link.base_branch),
      core.state_marker(link.proposal_id, "merge-ready", "merge-version-7"),
    })
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "waiting")
    t.eq(gate.unmet[1], 33)
  end,

  test_dependency_gate_closed_completed_without_merge_requires_waiver = function()
    mock_blocked_by(42, { { number = 28, state = "CLOSED", state_reason = "COMPLETED" } })
    mock_blocker_issue(28, "ready")
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "waiting")
    t.eq(gate.reason, "dependency-waiver-required")
    t.eq(gate.unmet[1], 28)
  end,

  test_dependency_gate_closed_completed_with_waiver_is_satisfied = function()
    mock_blocked_by(42, { { number = 29, state = "CLOSED", state_reason = "COMPLETED" } })
    mock_blocker_issue(29, "ready")
    local gate = core.dependency_gate(repo, 42, {
      proposal_id = proposal_id,
      version = version,
      comments = {
        dependency_waiver_comment(29),
      },
    })
    t.eq(gate.ok, true)
    t.eq(gate.kind, "satisfied")
    t.eq(gate.reason, "dependency-waiver")
  end,

  test_dependency_gate_closed_not_planned_voids_edge = function()
    mock_blocked_by(42, { { number = 30, state = "CLOSED", state_reason = "NOT_PLANNED" } })
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, true)
    t.eq(gate.kind, "satisfied")
    t.eq(gate.reason, "dependency-void")
    t.eq(gate.notes[1].kind, "dependency-void")
    t.eq(gate.notes[1].blocker_number, 30)
  end,

  test_dependency_gate_pr_stream_fetch_failure_fails_closed = function()
    mock_blocked_by(42, { { number = 35 } })
    mock_blocked_by(35, {})
    mock_blocker_issue_with_pr_link(35, 36, "pr-open")
    mock_blocker_pr_failure(36)
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "unresolvable")
    t.eq(gate.unmet[1], 35)
  end,

  test_dependency_gate_cycle = function()
    mock_blocked_by(42, { { number = 37 } })
    mock_blocked_by(37, { { number = 42 } })
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "cycle")
  end,

  test_dependency_gate_cross_repo_and_failures_unresolvable = function()
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_MANAGED_SIBLING_REPOS"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_blocked_by(42, { { number = 41, repo = "other/repo" } })
    local cross_repo = core.dependency_gate(repo, 42)
    t.eq(cross_repo.ok, false)
    t.eq(cross_repo.kind, "unresolvable")

    mock_blocked_by_failure(42)
    local failed = core.dependency_gate(repo, 42)
    t.eq(failed.ok, false)
    t.eq(failed.kind, "unresolvable")

    mock_blocked_by_malformed(42)
    local malformed = core.dependency_gate(repo, 42)
    t.eq(malformed.ok, false)
    t.eq(malformed.kind, "unresolvable")
  end,

  test_dependency_gate_truncated_blockedby_fails_closed = function()
    -- 51 blockers exist but the page returns 1 (merged); the unseen 50 must not
    -- be read as absent. The gate must fail-closed, NOT return ok=true.
    mock_blocked_by_truncated(42)
    local gate = core.dependency_gate(repo, 42)
    t.eq(gate.ok, false)
    t.eq(gate.kind, "unresolvable")
  end,
}
