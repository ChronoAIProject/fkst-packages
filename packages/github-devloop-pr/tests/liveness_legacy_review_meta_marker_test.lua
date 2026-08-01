-- Reproduction for #3010.
--
-- A `review-meta:v1` marker carrying `action="fix"` but no `review_proposal` /
-- `review_dedup` / `head_sha` was legitimately writable before 72e3ed21 ("Fail closed
-- on incomplete fix feedback", 2026-08-01T00:53:09Z). Markers of that shape are still
-- on live PRs; PR#2915 carries one written 2026-07-30T08:43:16Z.
--
-- The current builder can no longer emit that shape (builders.lua asserts the feedback
-- before writing), so the legacy marker below is written out literally on purpose. It is
-- copied from the marker observed on PR#2915, with this fixture's ids substituted.
--
-- The admission guard in markers/facts.lua checks proposal, action, version, dedup and
-- gap, but never checks that `review_proposal` is present, so a legacy marker is admitted
-- and then throws inside `parse_fix_feedback_fact`. On the liveness path that throw
-- escapes `restart_row_receiver_liveness` and kills the whole observe_pr pipeline for the
-- PR, every tick, forever.

local contract_time = require("contract.time")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local replay_fields = require("devloop.replay_fields")

local t = h.t
local core = h.core
local fixing = h.fixing

local repo = "owner/repo"

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T00:00:00Z",
  }
end

-- The pre-72e3ed21 shape: action="fix" and gap, with no binding attributes at all.
local function legacy_review_meta_marker(proposal_id, dedup_key, version)
  return '<!-- fkst:github-devloop:review-meta:v1 proposal="' .. tostring(proposal_id)
    .. '" dedup="' .. tostring(dedup_key)
    .. '" action="fix'
    .. '" version="' .. tostring(version)
    .. '" gap="non-enforcing projection guard" -->'
end

local function fixing_state(event)
  return {
    state = "fixing",
    version = event.version,
    proposal_id = event.proposal_id,
    marker_created_at = "2026-06-03T00:00:00Z",
  }
end

-- Deliberately carries no merge-gate and no review-result marker: on PR#2915 those
-- lookups return nil, which is what lets the review-meta lookup be reached at all.
local function comments_with(event, review_meta_marker)
  return {
    trusted_comment(m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")),
    trusted_comment(core.state_marker(event.proposal_id, "fixing", event.version)),
    trusted_comment(review_meta_marker),
  }
end

local function timeout_facts(event, state, comments)
  local pr_view = {
    comments = comments,
    head_ref_name = "devloop-owner-repo-42-01HY",
    head_sha = event.reviewed_head_sha,
    base_ref_name = "dev",
    state = "OPEN",
  }
  return {
    proposal_id = event.proposal_id,
    source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
    current = { comments = {} },
    current_pr = pr_view,
    link = {
      proposal_id = event.proposal_id,
      pr_number = event.pr_number,
      branch = "devloop-owner-repo-42-01HY",
      impl_version = event.version,
      base_branch = "dev",
    },
    snapshot = {
      comments = comments,
      prs = { { number = event.pr_number, current = pr_view } },
      state = state,
    },
    head_sha = event.reviewed_head_sha,
    fresh_current_state = state,
    now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z"),
  }
end

local function receiver_liveness_for(review_meta_marker)
  local event = fixing()
  local row = restart_transition_row("fixing")
  local state = fixing_state(event)
  local comments = comments_with(event, review_meta_marker)
  local facts = timeout_facts(event, state, comments)
  -- The work unit must be unresolved, or fixing_work_unit_from_trusted_facts returns
  -- before it ever consults the review-meta marker. This mirrors PR#2915.
  t.eq(facts.work_unit_key, nil)
  t.eq(state.work_unit_key, nil)
  return event, pcall(core.restart_row_receiver_liveness, row, state, facts, facts.now_seconds)
end

return {
  -- RED until #3010 is fixed.
  test_legacy_review_meta_fix_marker_does_not_crash_the_fixing_liveness_probe = function()
    local event = fixing()
    local marker = legacy_review_meta_marker(event.proposal_id, event.dedup_key, event.version)
    local _, ok, result = receiver_liveness_for(marker)

    -- Positive progress, not merely the absence of a token: the probe must return a
    -- decision for this row.
    t.is_true(ok, "liveness probe threw on a legacy review-meta marker: " .. tostring(result))
    t.eq(type(result), "table")
    t.eq(type(result.action), "string")

    -- And it must be the production error class that is absent, not some other failure.
    t.is_true(
      tostring(result):find("fix-feedback-missing-review-proposal-id", 1, true) == nil,
      "liveness probe surfaced the production error class: " .. tostring(result)
    )
  end,

  -- Non-vacuity control: with a complete binding the same fixture reaches a decision,
  -- proving the harness exercises the real path rather than short-circuiting.
  test_complete_review_meta_fix_marker_reaches_a_liveness_decision = function()
    local event = fixing()
    local marker = m_builders.review_meta_marker(
      event.proposal_id,
      event.dedup_key,
      "fix",
      event.version,
      "non-enforcing projection guard",
      nil,
      {
        review_proposal_id = event.review_proposal_id,
        review_dedup_key = event.review_dedup_key,
        reviewed_head_sha = event.reviewed_head_sha,
      }
    )
    local _, ok, result = receiver_liveness_for(marker)

    t.is_true(ok, "complete binding should not throw: " .. tostring(result))
    t.eq(type(result), "table")
    t.eq(type(result.action), "string")
  end,
}
