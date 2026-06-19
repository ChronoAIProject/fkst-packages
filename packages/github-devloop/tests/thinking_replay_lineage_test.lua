-- Regression: a thinking issue re-observed mid-consensus (slow codex runs)
-- replays a consensus proposal whose version MUST stay on the trusted thinking
-- marker's intake lineage. If the replay version diverges from the marker
-- lineage, consensus_result's thinking->ready CAS compares cross-base, falls to
-- the order-key fallback, and returns skip-stale forever (the live #970 hang).
--
-- This file drives the two halves of that loop end to end:
--   1. observe_issue builds the replay proposal from the trusted thinking marker
--      (build_thinking_replay_proposal).
--   2. consensus_result receives consensus on that replay proposal and must
--      APPLY thinking->ready, not skip-stale.
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local issue = h.issue
local opts = h.opts
local find_raise = h.find_raise
local run_observe = h.run_observe
local run_result = h.run_result
local reached = h.reached
local mock_issue_state = h.mock_issue_state
local mock_issue_result = h.mock_issue_result

local proposal_id = "github-devloop/issue/owner/repo/42"
-- A realistic trusted thinking marker version on the issue's intake lineage,
-- exactly the shape the live hang carried: .../<issue>/intake/<checksum>.
local intake_marker_version = "github-devloop/issue/owner/repo/42/intake/1213362634"

local function fresh_thinking_marker(version)
  -- Fixed created_at (not now()): the consensus-apply assertion must be
  -- deterministic. A wall-clock created_at made the thinking->ready apply
  -- flaky in CI (passed locally, failed on a different second). Pin it just
  -- before the mocked consensus event time (2026-06-03T01:02:03Z).
  return {
    body = core.state_marker(proposal_id, "thinking", version),
    created_at = "2026-06-03T01:00:00Z",
  }
end

return {
  -- Proof of the comparison invariant the fix restores: the replay consensus
  -- result version must compare same-base-equivalent to the intake marker
  -- (order 0), not skip-stale (order < 0). The replay version is taken from the
  -- real observe_issue replay path (mocked context bundle) so the construction
  -- is exercised, not hand-built.
  test_replay_version_compares_same_base_against_intake_marker = function()
    local event = issue()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      fresh_thinking_marker(intake_marker_version),
    })

    local observed = run_observe(event, opts("thinking-replay-lineage-compare"))
    t.eq(observed.exit_code, 0)
    local replay_version = find_raise(observed.raises, "consensus.proposal").payload.dedup_key
    -- The replay version is rooted at the marker lineage, with the distinct
    -- "/replay/<updated_at>" suffix that strips back to the same base.
    t.eq(replay_version, intake_marker_version .. "/replay/2026-06-03T01-02-03Z")
    t.eq(core.strip_transition_version_suffixes(replay_version), intake_marker_version)

    -- The consensus engine wraps the proposal dedup as consensus:<dedup>; that
    -- result version must NOT rank below the trusted intake marker.
    local consensus_version = "consensus:" .. replay_version
    local order = core._compare_transition_versions(consensus_version, intake_marker_version)
    t.eq(order, 0)
  end,

  -- Full loop: observe_issue produces the replay proposal, then consensus_result
  -- on that proposal applies thinking->ready instead of skip-stale.
  test_replayed_consensus_applies_thinking_to_ready_for_intake_lineage = function()
    local event = issue()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      fresh_thinking_marker(intake_marker_version),
    })

    local observed = run_observe(event, opts("thinking-replay-lineage-observe"))
    t.eq(observed.exit_code, 0)
    local replay_proposal = find_raise(observed.raises, "consensus.proposal").payload
    t.is_true(replay_proposal ~= nil)
    local replay_version = replay_proposal.dedup_key
    t.eq(replay_version, intake_marker_version .. "/replay/2026-06-03T01-02-03Z")

    -- Consensus reaches approval on the replayed proposal. The reached version is
    -- the engine-wrapped proposal dedup. The thinking marker is still on the
    -- intake lineage (consensus has not yet advanced it).
    mock_issue_result({ "fkst-dev:enabled", "fkst-dev:thinking" }, {
      fresh_thinking_marker(intake_marker_version),
    })
    local consensus = reached({
      dedup_key = "consensus:" .. replay_version,
    })
    local result = run_result(consensus, opts("thinking-replay-lineage-result"))
    t.eq(result.exit_code, 0)

    -- APPLY, not skip-stale: the thinking->ready transition fires. consensus_result
    -- emits the ready LABEL change + a ready-handoff comment here; the devloop_ready
    -- queue effect is raised downstream by comment_handoff, not in this dept (see
    -- test_consensus_result_approve_raises_ready_label_and_comment, which asserts
    -- devloop_ready == nil at this stage). The deterministic apply signal is the
    -- label flip from thinking to ready.
    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.is_true(label_raise ~= nil)
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:ready")
    local has_thinking_removed = false
    for _, removed in ipairs(label_raise.payload.remove_labels or {}) do
      if removed == "fkst-dev:thinking" then
        has_thinking_removed = true
      end
    end
    t.is_true(has_thinking_removed)
  end,
}
