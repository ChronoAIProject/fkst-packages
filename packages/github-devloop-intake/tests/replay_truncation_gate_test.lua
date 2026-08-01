-- Intake replay must not be refused merely because an UNRELATED part of the observe
-- snapshot is truncated. The snapshot is used for two independent keyed lookups:
--   * matching_live_delivery  reads snapshot.deliveries
--   * latest_terminal_tombstone reads snapshot.dead_letters
-- Truncation can only invalidate an ABSENCE conclusion, and only for the family that
-- was actually truncated. Duplicate replay raises are suppressed by the durable
-- dedup_key (successor_key, derived from the terminal tombstone), not by the
-- live-delivery scan, so a truncated deliveries list must not block replay.

local replay_authorization = require("core.replay_authorization")
local entity_lib = require("devloop.entity")
local m_claims = require("devloop.claims")
local h = require("tests.devloop_helpers")
local t = h.t

local TARGET_QUEUE = "github-devloop-intake.devloop_intake_candidate"
local TARGET_DEPT = "github-devloop-intake-default.intake_judge"

local function with_self_claim(fn)
  local prev_mode = m_claims.claim_mode_active
  local prev_state = m_claims.issue_claim_state
  m_claims.claim_mode_active = function()
    return "assignee"
  end
  m_claims.issue_claim_state = function()
    return "self"
  end
  local ok, result = pcall(fn)
  m_claims.claim_mode_active = prev_mode
  m_claims.issue_claim_state = prev_state
  if not ok then
    error(result, 0)
  end
  return result
end

local function source_ref()
  return entity_lib.issue_source_ref("owner/repo", 42)
end

local function open_issue()
  return {
    number = 42,
    title = "Replay candidate",
    body = "",
    updated_at = "2026-08-02T01:02:03Z",
    state = "OPEN",
    labels = {},
    assignees = { "fkst-test-bot" },
    comments = {},
  }
end

local function tombstone()
  return {
    queue = TARGET_QUEUE,
    dept = TARGET_DEPT,
    source = source_ref(),
    delivery_id = "delivery/v3/raised/queue/" .. TARGET_QUEUE .. "/dedup/probe",
    attempts = 3,
    permanent = true,
    replayable = false,
    dead_at_ms = 1785600000000,
  }
end

local function live_delivery()
  return {
    queue = TARGET_QUEUE,
    dept = TARGET_DEPT,
    source = source_ref(),
    status = "pending",
  }
end

local function snapshot(opts)
  return {
    deliveries = opts.deliveries or {},
    dead_letters = opts.dead_letters or {},
    truncated = {
      deliveries = opts.deliveries_truncated == true,
      dead_letters = opts.dead_letters_truncated == true,
    },
  }
end

local function authorize(snap)
  return with_self_claim(function()
    local ok, reason = replay_authorization.authorize(
      open_issue(),
      "proposal/owner/repo/42",
      source_ref(),
      { observe_snapshot = snap }
    )
    return { ok = ok, reason = reason }
  end)
end

return {
  -- THE DEFECT: deliveries truncated, dead_letters COMPLETE and holding a matching
  -- tombstone. The tombstone is positive evidence that truncation cannot undermine,
  -- and duplicate raises are already suppressed by the durable dedup_key.
  test_replay_authorized_when_only_deliveries_are_truncated = function()
    local result = authorize(snapshot({
      deliveries = {},
      deliveries_truncated = true,
      dead_letters = { tombstone() },
      dead_letters_truncated = false,
    }))

    t.eq(result.reason, nil)
    t.eq(type(result.ok), "table")
    t.eq(tostring(result.ok.issue_number), "42")
  end,

  -- SAFETY BOUNDARY 1: a tombstone ABSENCE conclusion drawn from a truncated
  -- dead_letters list is unsound, so it must still fail closed.
  test_replay_refused_when_dead_letters_truncated_and_tombstone_absent = function()
    local result = authorize(snapshot({
      deliveries = {},
      deliveries_truncated = false,
      dead_letters = {},
      dead_letters_truncated = true,
    }))

    t.eq(result.ok, nil)
    t.eq(result.reason, "observe-truncated-dead-letters")
  end,

  -- SAFETY BOUNDARY 2: a live delivery found in the visible window is positive
  -- evidence and must still suppress replay, truncation notwithstanding.
  test_replay_refused_when_live_delivery_visible_despite_truncation = function()
    local result = authorize(snapshot({
      deliveries = { live_delivery() },
      deliveries_truncated = true,
      dead_letters = { tombstone() },
      dead_letters_truncated = false,
    }))

    t.eq(result.ok, nil)
    t.eq(result.reason, "live-delivery-present")
  end,

  -- Unchanged: a complete snapshot with no tombstone is a sound absence.
  test_replay_refused_when_complete_snapshot_has_no_tombstone = function()
    local result = authorize(snapshot({
      deliveries = {},
      deliveries_truncated = false,
      dead_letters = {},
      dead_letters_truncated = false,
    }))

    t.eq(result.ok, nil)
    t.eq(result.reason, "terminal-dlq-absent")
  end,
}
