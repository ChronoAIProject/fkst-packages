-- Exercise restart-liveness across repeated observations. Attempts accumulate under a
-- stable actionable generation when no receiver is live, while a positively matching
-- `fkst.codex_runs` row remains the authoritative reason to defer.
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local contract_time = require("contract.time")
local conv_attempts = require("devloop.convergence.attempts")
local m_rae = require("devloop.restart_actionable_epoch")
local t = h.t
local core = h.core
local ready = h.ready
local replay_fields = require("devloop.replay_fields")
local devloop_logging = require("devloop.logging")

local repo = "owner/repo"
-- Matches the #2624 ground-truth generation_key epoch_ms 1784729745000.
local STATE_ENTRY_ISO = "2026-07-22T14:15:45Z"
local ENTRY_SECONDS = contract_time.iso_timestamp_epoch_seconds(STATE_ENTRY_ISO)
local BUDGET_MINUTES = 120

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function state_for(event, version)
  return {
    state = "implementing",
    version = version or event.dedup_key,
    proposal_id = event.proposal_id,
    marker_created_at = STATE_ENTRY_ISO,
  }
end

local function facts_for(event, comments, now_seconds, version)
  return {
    proposal_id = event.proposal_id,
    source_ref = event.source_ref,
    current = {
      comments = comments or {},
      labels = { "fkst-dev:enabled", "fkst-dev:implementing" },
    },
    fresh_current_state = state_for(event, version),
    now_seconds = now_seconds,
  }
end

local function entity_for()
  return {
    repo = repo,
    number = 42,
    source_ref = entity_lib.issue_source_ref(repo, 42),
  }
end

local function with_codex_runs(running, fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = running or {}, recent = {} }
  end
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

local function capture_raises(fn)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original
  if not ok then
    error(err)
  end
  return raised
end

local function captured_raise(raised, queue, predicate)
  for _, item in ipairs(raised or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload, item)) then
      return item
    end
  end
  return nil
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = STATE_ENTRY_ISO,
  }
end

local function run_timeout(row, state, facts)
  return capture_raises(function()
    core.maybe_timeout_redrive_from_table("liveness_scan", entity_for(), state, row, facts)
  end)
end

-- A codex_runs row whose lease is ALWAYS in the future relative to the current
-- observation -- i.e. the orphaned/re-leased implement run that keeps reading
-- live across restart churn even though the state is making no progress.
local function persistently_live_implement_run(event, now_seconds)
  local started_at_ms = (now_seconds - 600) * 1000
  local timeout_seconds = 7200
  return {
    run_id = "implement-orphan-perpetually-live",
    role = "implement",
    proposal_id = event.proposal_id,
    dedup_key = event.dedup_key,
    status = "running",
    started_at_ms = started_at_ms,
    lease_expires_at_ms = started_at_ms + timeout_seconds * 1000,
    timeout_seconds = timeout_seconds,
  }
end

return {
  -- The actionable epoch and timeout attempts remain stable across restarts.
  test_actionable_path_generation_stable_and_force_terminates = function()
    local event = ready()
    local row = restart_transition_row("implementing")
    local state = state_for(event)

    local now1 = ENTRY_SECONDS + (BUDGET_MINUTES + 60) * 60 -- first restart, past budget
    local now2 = ENTRY_SECONDS + (BUDGET_MINUTES + 600) * 60 -- much later restart

    with_codex_runs({}, function()
      local facts1 = facts_for(event, {}, now1)
      local eval1 = m_rae.actionable_epoch_resolve(core, row, state, facts1, now1)
      t.eq(eval1.status, "actionable")
      t.eq(eval1.signal.reason, "codex-run-not-running")
      -- (a) epoch_ms is the STABLE state-entry time, not a restart-derived value.
      t.eq(eval1.epoch_ms, ENTRY_SECONDS * 1000)

      local facts2 = facts_for(event, {}, now2)
      local eval2 = m_rae.actionable_epoch_resolve(core, row, state, facts2, now2)
      -- (b) IDENTICAL generation_key across the two restarts.
      t.eq(eval2.generation_key, eval1.generation_key)

      -- (c) a round-2 marker written under that generation_key is still read as
      -- round 2 after the later "restart" -- the round does not reset to 0/1.
      local comments = {
        trusted_comment(conv_attempts.timeout_attempt_v2_marker(event.proposal_id,
          row.from_state, row.liveness_class_id, eval1.generation_key, 1, event.source_ref)),
        trusted_comment(conv_attempts.timeout_attempt_v2_marker(event.proposal_id,
          row.from_state, row.liveness_class_id, eval1.generation_key, 2, event.source_ref)),
      }
      local facts3 = facts_for(event, comments, now2)
      core.liveness_timeout_due_with_facts(row, state, facts3, now2)
      t.eq(core.liveness_timeout_attempt(row, state, facts3), 2)

      local raised = run_timeout(row, state, facts3)
      local reconcile = captured_raise(raised, "devloop_timeout_reconcile")
      t.is_true(reconcile ~= nil)
      t.eq(reconcile.payload.state, "implementing")
      t.eq(reconcile.payload.round, 3)
      t.eq(captured_raise(raised, "github-proxy.github_issue_comment_request"), nil)
    end)
  end,

  test_persistently_live_codex_run_defers_without_consuming_attempt_budget = function()
    local event = ready()
    local row = restart_transition_row("implementing")
    local state = state_for(event)

    -- 20h past state entry: 10x the 120-min budget, far past any 2h implement run.
    local now_seconds = ENTRY_SECONDS + 20 * 60 * 60
    local facts = facts_for(event, {}, now_seconds)

    with_codex_runs({ persistently_live_implement_run(event, now_seconds) }, function()
      local receiver = core.restart_row_receiver_liveness(row, state, facts, now_seconds)
      t.eq(receiver.action, "defer")
      t.eq(receiver.reason, "actionable-epoch-deferred")
      t.eq(receiver.signal.family, "codex_run:v1")
      local due = core.liveness_timeout_due_with_facts(row, state, facts, now_seconds)
      t.eq(due, false)
      local raised = run_timeout(row, state, facts)
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.eq(captured_raise(raised, "devloop_ready"), nil)
      t.eq(captured_raise(raised, "github-proxy.github_issue_comment_request"), nil)
    end)
  end,
}
