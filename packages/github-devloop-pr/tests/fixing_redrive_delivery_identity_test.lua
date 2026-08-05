local contract_time = require("contract.time")
local ci_repair_attempts = require("core.ci_repair_attempts")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local replay_fields = require("devloop.replay_fields")
local v_fixing = require("devloop.validators.fixing")
local v_reviewing = require("devloop.validators.reviewing")

local t = h.t
local core = h.core
local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local branch = "devloop-owner-repo-42-01HY"
local reviewed_head = "def456"
local advanced_head = "feedface"

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function feedback(event)
  return {
    review_proposal_id = event.review_proposal_id,
    review_dedup_key = event.review_dedup_key,
    reviewed_head_sha = event.reviewed_head_sha,
    blocking_gap = event.blocking_gap,
  }
end

local function fixing_comment_bodies(event)
  return {
    core.state_marker(event.proposal_id, "fixing", event.version),
    m_builders.review_result_marker(
      event.review_proposal_id,
      event.proposal_id,
      "reject",
      event.review_dedup_key,
      1,
      event.blocking_gap
    ),
    m_builders.merge_gate_marker(
      event.proposal_id,
      event.pr_number,
      event.version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha,
      nil,
      event.blocking_gap,
      nil,
      nil
    ),
  }
end

local function timeout_facts(event, current_head, extra_bodies, now_iso)
  local bodies = fixing_comment_bodies(event)
  for _, body in ipairs(extra_bodies or {}) do
    table.insert(bodies, body)
  end
  local comments = {}
  for _, body in ipairs(bodies) do
    table.insert(comments, trusted_comment(body))
  end
  local state = {
    state = "fixing",
    version = event.version,
    proposal_id = event.proposal_id,
    marker_created_at = "2026-06-03T00:00:00Z",
  }
  local current_pr = {
    comments = comments,
    head_ref_name = branch,
    head_sha = current_head,
    base_ref_name = "dev",
    state = "OPEN",
  }
  return state, {
    proposal_id = event.proposal_id,
    source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
    current = { comments = comments },
    current_pr = current_pr,
    feedback = feedback(event),
    link = {
      proposal_id = event.proposal_id,
      pr_number = event.pr_number,
      branch = branch,
      impl_version = event.version,
      base_branch = "dev",
    },
    snapshot = {
      comments = comments,
      prs = { { number = event.pr_number, current = current_pr } },
      state = state,
    },
    fresh_current_state = state,
    now_seconds = contract_time.iso_timestamp_epoch_seconds(now_iso or "2026-06-03T03:00:00Z"),
  }
end

local function with_no_codex_runs(fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = {}, recent = {} }
  end
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

local function capture_timeout_redrive(event, current_head, extra_bodies, now_iso)
  local state, facts = timeout_facts(event, current_head, extra_bodies, now_iso)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(function()
    with_no_codex_runs(function()
      local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
        repo = repo,
        number = event.pr_number,
        source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
      }, state, restart_transition_row("fixing"), facts)
      t.eq(handled, true)
    end)
  end)
  devloop_logging.log_raise = original
  if not ok then
    error(err)
  end
  return raised, state, facts
end

local function find_raise(raised, queue, predicate)
  for _, item in ipairs(raised or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload)) then
      return item
    end
  end
  return nil
end

local function assert_reviewing_receiver(event, raised, state, comment_id, test_name)
  local request = find_raise(raised, "github-proxy.github_pr_comment_request", function(payload)
    return payload.handoff ~= nil and payload.handoff.kind == "github-devloop.reviewing"
  end)
  t.is_true(request ~= nil)
  local delivery_key = request.payload.handoff.review_delivery_dedup_key
  t.eq(request.payload.dedup_key, delivery_key)
  t.is_true(#delivery_key <= devloop_base._max_key_len)
  local review_version = core.next_fix_version(state.version)
  local review_id = devloop_base.pr_review_proposal_id(repo, event.pr_number, review_version, advanced_head)
  t.eq(devloop_base.pr_review_proposal_id_from_redrive_delivery_dedup_key(delivery_key), review_id)

  local handed_off = h.run_comment_handoff_from_request(request.payload, comment_id, test_name)
  t.eq(handed_off.exit_code, 0)
  local reviewing = h.find_raise(handed_off.raises, "devloop_reviewing")
  t.is_true(reviewing ~= nil)
  t.eq(reviewing.payload.dedup_key, delivery_key)
  t.eq(reviewing.payload.review_delivery_dedup_key, delivery_key)
  t.eq(v_reviewing.is_supported_reviewing(core, reviewing.payload), true)
end

return {
  test_replayed_fixing_payload_uses_generation_scoped_delivery_identity = function()
    local event = h.fixing()
    local generation = "restart-liveness-v2/" .. event.proposal_id
      .. "/fixing/fixing.actionable/codex_run_with_durable_hold-v1/state-entry-v1-"
      .. event.version .. "/1783828800000"
    local first = payloads_builders.build_replayed_fixing_payload({
      proposal_id = event.proposal_id,
      impl_version = event.version,
      redrive_delivery = { generation_key = generation, attempt = 1 },
    }, event.pr_number, feedback(event), event.source_ref)
    local second = payloads_builders.build_replayed_fixing_payload({
      proposal_id = event.proposal_id,
      impl_version = event.version,
      redrive_delivery = { generation_key = generation, attempt = 2 },
    }, event.pr_number, feedback(event), event.source_ref)

    t.eq(first.redrive_delivery.generation_key, generation)
    t.eq(first.redrive_delivery.attempt, 1)
    t.eq(second.redrive_delivery.generation_key, generation)
    t.eq(second.redrive_delivery.attempt, 2)
    t.is_true(first.dedup_key ~= second.dedup_key)
    t.eq(first.work_unit_key, second.work_unit_key)
    t.eq(v_fixing.is_supported_fixing(first), true)
    t.eq(v_fixing.is_supported_fixing(second), true)
    first.dedup_key = second.dedup_key
    t.eq(v_fixing.is_supported_fixing(first), false)
  end,

  test_fixing_timeout_unchanged_head_reaches_fixing_receiver = function()
    local event = h.fixing()
    local raised = capture_timeout_redrive(event, reviewed_head)
    local fixing = find_raise(raised, "devloop_fixing")
    t.is_true(fixing ~= nil)
    t.eq(fixing.payload.redrive_delivery.attempt, 1)
    t.eq(v_fixing.is_supported_fixing(fixing.payload), true)

    h.mock_bot_env()
    h.mock_write_env("")
    local bodies = fixing_comment_bodies(event)
    h.mock_issue_fix_for_event(fixing.payload, { "fkst-dev:fixing" }, bodies, branch, event.version)
    h.mock_pr_fix(bodies, branch, reviewed_head)
    local received = h.run_fix(fixing.payload, h.opts("fixing-redrive-delivery-receiver"))
    t.eq(received.exit_code, 0)
  end,

  test_fixing_timeout_advanced_head_reaches_reviewing_receiver = function()
    local event = h.fixing()
    t.mock_command("git fetch origin " .. branch, {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git rev-parse --verify 'FETCH_HEAD^{commit}'", {
      stdout = advanced_head .. "\n",
      stderr = "",
      exit_code = 0,
    })

    local raised, state = capture_timeout_redrive(event, advanced_head)
    assert_reviewing_receiver(
      event, raised, state,
      "IC_fixing_redrive_reviewing_1",
      "fixing-redrive-reviewing-handoff"
    )
  end,

  test_fixing_timeout_durable_hold_generation_reaches_reviewing_receiver = function()
    local event = h.fixing({
      repair_input = "ci-failure",
      ci_failure_key = "head:def456/checks:digest-0000000101",
    })
    local attempt_body = ci_repair_attempts.comment_request(
      repo, event, "no-fix", "No repaired revision was published."
    ).body
    t.mock_command("git fetch origin " .. branch, {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git rev-parse --verify 'FETCH_HEAD^{commit}'", {
      stdout = advanced_head .. "\n",
      stderr = "",
      exit_code = 0,
    })

    local raised, state, facts = capture_timeout_redrive(
      event, advanced_head, { attempt_body }, "2026-06-03T04:00:00Z"
    )
    t.eq(facts.actionable_epoch_eval.status, "actionable")
    t.is_true(facts.actionable_epoch_eval.generation_key:find("-due/", 1, true) ~= nil)
    assert_reviewing_receiver(
      event, raised, state,
      "IC_fixing_durable_hold_redrive_reviewing_1",
      "fixing-durable-hold-redrive-reviewing-handoff"
    )
  end,
}
