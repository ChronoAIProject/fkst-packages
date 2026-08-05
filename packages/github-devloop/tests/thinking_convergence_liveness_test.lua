local base_ids = require("devloop.base_ids")
local codex_status = require("tests.codex_status_helpers")
local contract_time = require("contract.time")
local conv_attempts = require("devloop.convergence.attempts")
local conv_rounds = require("devloop.convergence.rounds")
local convergence_shared = require("devloop.convergence.shared")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local replay_fields = require("devloop.replay_fields")
local transition_version = require("contract.transition_version")

local core = h.core
local t = h.t
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local SOURCE_REF = entity_lib.issue_source_ref(REPO, ISSUE_NUMBER)
local BASE_VERSION = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local CONSENSUS_DEDUP = "consensus:" .. BASE_VERSION
local NEXT_WORK_UNIT = transition_version.loop_at(BASE_VERSION, 1)

local function thinking_row()
  return replay_fields.restart_transition_row(core.restart_transition_table(), "thinking")
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function convergence_comment(created_at)
  return trusted_comment(conv_rounds.converge_round_marker(
    PROPOSAL_ID,
    BASE_VERSION,
    convergence_shared.source_ref_digest(SOURCE_REF),
    0,
    CONSENSUS_DEDUP,
    "Narrow the implementation contract",
    {
      { angle = "fidelity", verdict = "converge", digest = "trusted progress" },
    }
  ), created_at)
end

local function thinking_state(created_at)
  return {
    state = "thinking",
    version = BASE_VERSION,
    proposal_id = PROPOSAL_ID,
    marker_created_at = created_at,
  }
end

local function liveness_facts(comments, now_seconds)
  return {
    proposal_id = PROPOSAL_ID,
    source_ref = SOURCE_REF,
    current = { comments = comments or {} },
    snapshot = { comments = comments or {} },
    now_seconds = now_seconds,
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

local function find_raise(raises, queue, predicate)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue and (predicate == nil or predicate(raised.payload or {})) then
      return raised
    end
  end
  return nil
end

return {
  test_thinking_contract_matches_the_current_convergence_work_unit = function()
    t.eq(thinking_row().liveness_contract.real_execution.match.dedup_key, "state.work_unit_key")
  end,

  test_complete_convergence_progress_rebases_age_and_timeout_attempt_generation = function()
    local row = thinking_row()
    local state = thinking_state("2026-06-03T00:00:00Z")
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local old_facts = liveness_facts({}, now_seconds)

    with_codex_runs({}, function()
      core.liveness_timeout_due_with_facts(row, state, old_facts, now_seconds)
    end)
    local old_generation = old_facts.actionable_epoch_eval.generation_key
    local comments = {
      trusted_comment(conv_attempts.timeout_attempt_v2_marker(
        PROPOSAL_ID,
        row.from_state,
        row.liveness_class_id,
        old_generation,
        7,
        SOURCE_REF
      ), "2026-06-03T02:00:00Z"),
      trusted_comment(conv_attempts.timeout_attempt_marker(
        PROPOSAL_ID,
        BASE_VERSION,
        "thinking",
        8,
        SOURCE_REF
      ), "2026-06-03T02:01:00Z"),
      convergence_comment("2026-06-03T02:55:00Z"),
    }
    local facts = liveness_facts(comments, now_seconds)

    with_codex_runs({}, function()
      local due, age = core.liveness_timeout_due_with_facts(row, state, facts, now_seconds)
      t.eq(due, false)
      t.eq(age, 5)
      t.eq(facts.actionable_epoch_eval.epoch_ms, now_seconds * 1000 - (5 * 60 * 1000))
      t.is_true(facts.actionable_epoch_eval.generation_key ~= old_generation)
      t.eq(core.liveness_timeout_attempt(row, state, facts), 0)
    end)
  end,

  test_live_next_convergence_work_unit_defers_restart_liveness = function()
    local row = thinking_row()
    local state = thinking_state("2026-06-03T00:00:00Z")
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local facts = liveness_facts({ convergence_comment("2026-06-03T02:55:00Z") }, now_seconds)

    with_codex_runs({
      {
        status = "running",
        role = "consensus",
        proposal_id = PROPOSAL_ID,
        dedup_key = NEXT_WORK_UNIT,
        started_at = "2026-06-03T02:56:00Z",
        timeout_seconds = 7200,
      },
    }, function()
      local receiver = core.restart_row_receiver_liveness(row, state, facts, now_seconds)
      t.eq(receiver.action, "defer")
      t.eq(receiver.signal.dedup_key, NEXT_WORK_UNIT)
    end)
  end,

  test_delayed_other_lineage_rounds_do_not_rebase_the_current_work_unit = function()
    local row = thinking_row()
    local state = thinking_state("2026-06-03T02:00:00Z")
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local other_source = entity_lib.issue_source_ref(REPO, ISSUE_NUMBER + 1)
    local comments = {
      convergence_comment("2026-06-03T02:55:00Z"),
      trusted_comment(conv_rounds.converge_round_marker(
        PROPOSAL_ID,
        BASE_VERSION .. "/reimplement/1",
        convergence_shared.source_ref_digest(SOURCE_REF),
        7,
        "consensus:previous-version/loop/7",
        "Previous version",
        { { angle = "fidelity", verdict = "converge", digest = "stale version" } }
      ), "2026-06-03T02:59:00Z"),
      trusted_comment(conv_rounds.converge_round_marker(
        PROPOSAL_ID,
        BASE_VERSION,
        convergence_shared.source_ref_digest(other_source),
        6,
        "consensus:other-source/loop/6",
        "Other source",
        { { angle = "fidelity", verdict = "converge", digest = "stale source" } }
      ), "2026-06-03T02:58:00Z"),
    }
    local facts = liveness_facts(comments, now_seconds)

    with_codex_runs({
      {
        status = "running",
        role = "consensus",
        proposal_id = PROPOSAL_ID,
        dedup_key = NEXT_WORK_UNIT,
        started_at = "2026-06-03T02:56:00Z",
        timeout_seconds = 7200,
      },
    }, function()
      local receiver = core.restart_row_receiver_liveness(row, state, facts, now_seconds)
      t.eq(receiver.action, "defer")
      t.eq(receiver.signal.dedup_key, NEXT_WORK_UNIT)
    end)
  end,

  test_unparseable_convergence_timestamp_does_not_rebase_liveness = function()
    local row = thinking_row()
    local state = thinking_state("2026-06-03T00:00:00Z")
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local facts = liveness_facts({ convergence_comment("not-a-timestamp") }, now_seconds)

    with_codex_runs({}, function()
      local signal = core.restart_row_liveness_signal(row, state, facts, now_seconds)
      t.eq(signal.expected_dedup_key, BASE_VERSION)
      local _, age = core.liveness_timeout_due_with_facts(row, state, facts, now_seconds)
      t.eq(age, 180)
    end)
  end,

  test_liveness_scan_recognizes_live_convergence_generation_after_restart = function()
    local run_opts = h.opts("thinking-convergence-generation-liveness-scan")
    local state_created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60))
    local progress_created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (5 * 60))
    local comments = {
      trusted_comment(core.state_marker(PROPOSAL_ID, "thinking", BASE_VERSION), state_created_at),
      convergence_comment(progress_created_at),
    }
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = REPO,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(core.gh_issue_list_observe_cmd(REPO), {
      stdout = '[{"number":42,"state":"open","updated_at":"2026-06-03T03:00:00Z"}]\n',
      stderr = "",
      exit_code = 0,
    })
    entity_read_mocks.mock_issue_read_forms(t, {
      repo = REPO,
      number = ISSUE_NUMBER,
      title = "Thinking convergence remains actionable",
      body = "",
      state = "OPEN",
      updated_at = "2026-06-03T03:00:00Z",
      labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
      comments = comments,
      assignees = { "fkst-test-bot" },
      times = 1,
    })
    codex_status.seed_role_codex_run(run_opts, "consensus", PROPOSAL_ID, NEXT_WORK_UNIT)

    local result = h.run_department("departments/liveness_scan/main.lua", {
      queue = "devloop_liveness_tick",
      payload = { schema = "github-devloop.tick.v1" },
      ts = "2026-06-03T03:00:00Z",
    }, run_opts)

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
    end), nil)
    t.is_true(find_raise(result.raises, "devloop_observe_issue") ~= nil)
  end,
}
