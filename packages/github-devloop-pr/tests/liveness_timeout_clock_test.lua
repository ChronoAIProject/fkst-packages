local entity_lib = require("devloop.entity")
local devloop_base = require("devloop.base")
local convergence_shared = require("devloop.convergence.shared")
local contract_time = require("contract.time")
local h = require("tests.devloop_helpers")
local conv_rounds = require("devloop.convergence.rounds")
local conv_reconcile = require("devloop.convergence.reconcile")
local conv_attempts = require("devloop.convergence.attempts")
local m_mgw = require("devloop.merge_gate_wait")
local m_builders = require("devloop.markers.builders")
local m_rae = require("devloop.restart_actionable_epoch")
local t = h.t
local core = h.core
local opts = h.opts
local replay_fields = require("devloop.replay_fields")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local devloop_logging = require("devloop.logging")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local head_sha = "def456"
local branch = "devloop-owner-repo-42-01HY"

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local lineages = {
  fix = version .. "/fix/1",
  review_loop = version .. "/review-loop/2",
}

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function state_comment(state_name, state_version, created_at)
  return trusted_comment(core.state_marker(proposal_id, state_name, state_version), created_at)
end


local function merge_gate_wait_comment(state_version, created_at)
  return trusted_comment(m_mgw.merge_gate_wait_marker(proposal_id, 7, state_version, head_sha, "ci-wait", "CI_WAIT"), created_at)
end

local function timeout_attempt_comment(state_name, state_version, round, source_ref)
  return trusted_comment(conv_attempts.timeout_attempt_marker(proposal_id, state_version, state_name, round, source_ref), "2026-06-03T00:00:00Z")
end





local function capture_raises(fn)
  local raised = {}
  local original_log_raise = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original_log_raise
  if not ok then
    error(err)
  end
  return raised
end

local function old_merge_state(state_name, state_version)
  return {
    state = state_name,
    version = state_version,
    proposal_id = proposal_id,
    marker_created_at = "2026-06-03T00:00:00Z",
  }
end

local function recent_merge_state(state_name, state_version)
  return {
    state = state_name,
    version = state_version,
    proposal_id = proposal_id,
    marker_created_at = "2026-06-04T00:00:00Z",
  }
end

local function merge_timeout_facts(state, extra_comments, now_seconds)
  local review_proposal_id = devloop_base.pr_review_proposal_id(repo, 7, state.version, head_sha)
  local review_dedup_key = devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(proposal_id, "42", branch, state.version, "dev"), "2026-06-03T00:00:00Z"),
    state_comment(state.state, state.version, state.marker_created_at),
    trusted_comment(m_builders.review_result_marker(review_proposal_id, proposal_id, "approve", review_dedup_key), "2026-06-03T00:00:00Z"),
    trusted_comment(m_builders.merge_ready_marker(proposal_id, 7, state.version, review_proposal_id, review_dedup_key, head_sha), "2026-06-03T00:00:00Z"),
  }
  if state.state == "merging" then
    table.insert(comments, trusted_comment(m_builders.merging_marker(proposal_id, 7, state.version, head_sha), "2026-06-03T00:00:00Z"))
  end
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  local current_pr = {
    comments = comments,
    head_ref_name = branch,
    head_sha = head_sha,
    base_ref_name = "dev",
    state = "OPEN",
    mergeable = "MERGEABLE",
    merge_state_status = "CLEAN",
    status_check_rollup_present = true,
    status_check_rollup = {
      { name = "test", status = "COMPLETED", conclusion = "SUCCESS", headSha = head_sha },
    },
  }
  return {
    proposal_id = proposal_id,
    source_ref = entity_lib.pr_source_ref(repo, 7),
    current = { comments = comments },
    current_pr = current_pr,
    link = {
      proposal_id = proposal_id,
      pr_number = 7,
      branch = branch,
      impl_version = state.version,
      base_branch = "dev",
    },
    snapshot = {
      comments = comments,
      prs = { { number = 7, current = current_pr } },
      state = state,
    },
    head_sha = head_sha,
    fresh_current_state = state,
    now_seconds = now_seconds,
  }
end

local function add_timeout_attempt_comments(row, state, facts, count)
  local eval = m_rae.actionable_epoch_resolve(core, row, state, facts, facts.now_seconds)
  t.eq(eval.status, "actionable")
  for round = 1, count do
    table.insert(facts.current.comments, trusted_comment(conv_attempts.timeout_attempt_v2_marker(
      proposal_id,
      row.from_state,
      row.liveness_class_id,
      eval.generation_key,
      round,
      facts.source_ref
    ), "2026-06-03T00:00:00Z"))
  end
end

local function raised_index(raised, queue, predicate)
  for index, item in ipairs(raised or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload)) then
      return index
    end
  end
  return nil
end

local function assert_redrive_request_before_receipt(raised, state_name)
  local request_index = raised_index(raised, "devloop_merge_ready")
  local reconcile_index = raised_index(raised, "devloop_timeout_reconcile")
  local receipt_index = raised_index(raised, "github-proxy.github_pr_comment_request", function(payload)
    return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
  end)
  t.eq(reconcile_index, nil)
  t.is_true(request_index ~= nil)
  t.is_true(receipt_index ~= nil)
  t.is_true(request_index < receipt_index)
  t.is_true(tostring(raised[receipt_index].payload.body):find('state="' .. state_name .. '"', 1, true) ~= nil)
end

local function assert_fresh_merge_wait_does_not_extend_absolute_cap(state_name, lineage_version)
  local row = restart_transition_row(state_name)
  local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-04T01:02:03Z")
  local wait_lineage = lineage_version or version
  local wait = merge_gate_wait_comment(wait_lineage, "2026-06-04T00:30:00Z")
  local state = old_merge_state(state_name, wait_lineage)
  local facts = merge_timeout_facts(state, { wait }, now_seconds)
  add_timeout_attempt_comments(row, state, facts, 3)
  local due, age = core.liveness_timeout_due_with_facts(
    row,
    state,
    facts,
    now_seconds
  )
  t.eq(due, true)
  t.eq(age, 1502)

  local raised = capture_raises(function()
    local applied = core.maybe_timeout_redrive_from_table("liveness_scan", {
      repo = repo,
      number = 42,
      source_ref = entity_lib.issue_source_ref(repo, 42),
    }, state, row, facts)
    t.eq(applied, true)
  end)
  -- Owner directive (#2725): a merge-gate wait timeout / row-budget cap is a
  -- liveness/resource condition that must NEVER escalate to a terminal reconcile; it
  -- REDRIVES, emitting the next timeout-attempt PR comment instead of the terminal
  -- devloop_timeout_reconcile event. merge-ready/merging are never dropped to blocked.
  assert_redrive_request_before_receipt(raised, state_name)
end

local function assert_fresh_merge_wait_defers_within_absolute_cap(state_name)
  local row = restart_transition_row(state_name)
  local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-04T01:02:03Z")
  local wait = merge_gate_wait_comment(version, "2026-06-04T00:30:00Z")
  local state = recent_merge_state(state_name, version)
  local facts = merge_timeout_facts(state, { wait }, now_seconds)
  local due, age = core.liveness_timeout_due_with_facts(
    row,
    state,
    facts,
    now_seconds
  )
  t.eq(due, false)
  t.eq(age, 62)

  local raised = capture_raises(function()
    local applied = core.maybe_timeout_redrive_from_table("liveness_scan", {
      repo = repo,
      number = 42,
      source_ref = entity_lib.issue_source_ref(repo, 42),
    }, state, row, facts)
    t.eq(applied, true)
  end)
  t.eq(#raised, 0)
end

local function assert_stale_or_missing_merge_wait_escalates(state_name, wait_comment, lineage_version)
  local row = restart_transition_row(state_name)
  local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-04T01:02:03Z")
  local wait_lineage = lineage_version or version
  local state = old_merge_state(state_name, wait_lineage)
  local facts = merge_timeout_facts(state, wait_comment and { wait_comment } or {}, now_seconds)
  add_timeout_attempt_comments(row, state, facts, 3)
  local raised = capture_raises(function()
    local applied = core.maybe_timeout_redrive_from_table("liveness_scan", {
      repo = repo,
      number = 42,
      source_ref = entity_lib.issue_source_ref(repo, 42),
    }, state, row, facts)
    t.eq(applied, true)
  end)
  -- Owner directive (#2725): a merge-gate wait timeout / row-budget cap is a
  -- liveness/resource condition that must NEVER escalate to a terminal reconcile; it
  -- REDRIVES, emitting the next timeout-attempt PR comment instead of the terminal
  -- devloop_timeout_reconcile event. merge-ready/merging are never dropped to blocked.
  assert_redrive_request_before_receipt(raised, state_name)
end

local function assert_stale_merge_wait_falls_back_to_under_budget_state_age(state_name)
  local row = restart_transition_row(state_name)
  local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-04T01:02:03Z")
  local stale_wait = merge_gate_wait_comment(version, "2026-06-03T00:00:00Z")
  local state = recent_merge_state(state_name, version)
  local facts = merge_timeout_facts(state, { stale_wait }, now_seconds)
  local due, age = core.liveness_timeout_due_with_facts(
    row,
    state,
    facts,
    now_seconds
  )
  t.eq(due, false)
  t.eq(age, 62)

  local raised = capture_raises(function()
    local applied = core.maybe_timeout_redrive_from_table("liveness_scan", {
      repo = repo,
      number = 42,
      source_ref = entity_lib.issue_source_ref(repo, 42),
    }, state, row, facts)
    t.eq(applied, false)
  end)
  t.eq(#raised, 0)
end

local function run_timeout_reconcile(payload, comments, name, now_seconds)
  local source_repo, source_pr = devloop_base.parse_pr_source_ref(payload and payload.source_ref)
  local common_issue = {
    repo = repo,
    number = 42,
    title = "Issue 42",
    body = "",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    labels = { "fkst-dev:thinking" },
    comments = comments,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    register_all_views = true,
    times = 1,
  }
  entity_read_mocks.mock_issue_read_forms(t, common_issue)
  if source_pr ~= nil then
    entity_read_mocks.mock_pr_read_forms(t, {
      repo = source_repo or repo,
      number = source_pr,
      head_sha = head_sha,
      comments = comments,
      state = "OPEN",
      register_all_views = true,
      times = 1,
    })
  end
  if now_seconds == nil then
    return t.run_department("departments/reconcile/main.lua", {
      queue = "devloop_timeout_reconcile",
      payload = payload,
    }, opts(name or "liveness-timeout-clock"))
  end

  local raised = {}
  local original_raise = raise
  local original_now = now
  raise = function(queue, raised_payload)
    table.insert(raised, { queue = queue, payload = raised_payload })
  end
  now = function()
    return now_seconds
  end
  local ok, err = pcall(function()
    local department = require("departments.reconcile.main")
    department.pipeline({
      queue = "devloop_timeout_reconcile",
      payload = payload,
    })
  end)
  now = original_now
  raise = original_raise
  if not ok then
    return {
      exit_code = 1,
      error = tostring(err),
      raises = raised,
    }
  end
  return {
    exit_code = 0,
    raises = raised,
  }
end

local function timestamp_minutes_before(now_seconds, age_minutes)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now_seconds - age_minutes * 60)
end

local function timeout_reconcile_age_clock()
  return contract_time.iso_timestamp_epoch_seconds("2026-06-03T06:31:00Z")
end

return {
  test_contract_time_elapsed_whole_minutes_supports_pr_liveness = function()
    local timestamp = "2026-06-04T01:02:03Z"
    t.eq(contract_time.iso_timestamp_age_minutes(timestamp, contract_time.iso_timestamp_epoch_seconds(timestamp)), 0)
  end,

  test_merge_ready_fresh_merge_gate_wait_past_absolute_cap_escalates = function()
    assert_fresh_merge_wait_does_not_extend_absolute_cap("merge-ready")
  end,

  test_merging_fresh_merge_gate_wait_past_absolute_cap_escalates = function()
    assert_fresh_merge_wait_does_not_extend_absolute_cap("merging")
  end,

  test_merge_ready_fresh_merge_gate_wait_past_absolute_cap_escalates_fix_lineage = function()
    assert_fresh_merge_wait_does_not_extend_absolute_cap("merge-ready", lineages.fix)
  end,

  test_merge_ready_fresh_merge_gate_wait_past_absolute_cap_escalates_review_loop_lineage = function()
    assert_fresh_merge_wait_does_not_extend_absolute_cap("merge-ready", lineages.review_loop)
  end,

  test_merge_ready_fresh_merge_gate_wait_within_absolute_cap_defers = function()
    assert_fresh_merge_wait_defers_within_absolute_cap("merge-ready")
  end,

  test_merging_fresh_merge_gate_wait_within_absolute_cap_defers = function()
    assert_fresh_merge_wait_defers_within_absolute_cap("merging")
  end,

  test_merge_ready_stale_merge_gate_wait_under_budget_falls_back_to_state_age = function()
    assert_stale_merge_wait_falls_back_to_under_budget_state_age("merge-ready")
  end,

  test_merging_stale_merge_gate_wait_under_budget_falls_back_to_state_age = function()
    assert_stale_merge_wait_falls_back_to_under_budget_state_age("merging")
  end,

  test_merge_ready_stale_or_missing_merge_gate_wait_escalates_row_budget = function()
    assert_stale_or_missing_merge_wait_escalates("merge-ready", merge_gate_wait_comment(version, "2026-06-03T00:00:00Z"))
    assert_stale_or_missing_merge_wait_escalates("merge-ready", nil)
  end,

  test_merging_stale_or_missing_merge_gate_wait_escalates_row_budget = function()
    assert_stale_or_missing_merge_wait_escalates("merging", merge_gate_wait_comment(version, "2026-06-03T00:00:00Z"))
    assert_stale_or_missing_merge_wait_escalates("merging", nil)
  end,

  test_timeout_reconcile_why_reports_merge_gate_wait_age = function()
    local row = restart_transition_row("merge-ready")
    local timeout_version = version .. "/timeout/merge-ready/3"
    local source_ref = entity_lib.pr_source_ref(repo, 7)
    local wait_age_minutes = 391
    local now_seconds = timeout_reconcile_age_clock()
    local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(row, {
      state = "merge-ready",
      version = timeout_version,
    }, proposal_id, source_ref, 3)
    local result = run_timeout_reconcile(payload, {
      state_comment("merge-ready", timeout_version, "2026-06-03T00:00:00Z"),
      timeout_attempt_comment("merge-ready", version, 1, source_ref),
      timeout_attempt_comment("merge-ready", version, 2, source_ref),
      merge_gate_wait_comment(version, timestamp_minutes_before(now_seconds, wait_age_minutes)),
    }, "timeout-reconcile-merge-gate-wait-age", now_seconds)
    -- Owner directive (#2725): the timeout-reconcile department path is neutralized -- the
    -- re-derived timeout decision is redrive (never escalate), so a timeout-reconcile event
    -- is a no-op skip (no-longer-over-budget); no terminal "why" PR comment is emitted.
    t.eq(result.exit_code, 0)
    t.eq(h.find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_timeout_reconcile_why_reports_fix_lineage_merge_gate_wait_age = function()
    local row = restart_transition_row("merge-ready")
    local timeout_version = lineages.fix .. "/timeout/merge-ready/3"
    local source_ref = entity_lib.pr_source_ref(repo, 7)
    local wait_age_minutes = 391
    local now_seconds = timeout_reconcile_age_clock()
    local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(row, {
      state = "merge-ready",
      version = timeout_version,
    }, proposal_id, source_ref, 3)
    local result = run_timeout_reconcile(payload, {
      state_comment("merge-ready", timeout_version, "2026-06-03T00:00:00Z"),
      timeout_attempt_comment("merge-ready", lineages.fix, 1, source_ref),
      timeout_attempt_comment("merge-ready", lineages.fix, 2, source_ref),
      merge_gate_wait_comment(lineages.fix, timestamp_minutes_before(now_seconds, wait_age_minutes)),
    }, "timeout-reconcile-fix-lineage-merge-gate-wait-age", now_seconds)
    -- Owner directive (#2725): the timeout-reconcile department path to terminal blocked
    -- is neutralized -- the re-derived timeout decision is redrive (never escalate), so a
    -- timeout-reconcile event is a no-op skip (no-longer-over-budget); it emits no terminal
    -- "why" PR comment and never drops merge-ready to blocked.
    t.eq(result.exit_code, 0)
    t.eq(h.find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_timeout_reconcile_why_reports_review_loop_lineage_merge_gate_wait_age = function()
    local row = restart_transition_row("merge-ready")
    local timeout_version = lineages.review_loop .. "/timeout/merge-ready/3"
    local source_ref = entity_lib.pr_source_ref(repo, 7)
    local wait_age_minutes = 391
    local now_seconds = timeout_reconcile_age_clock()
    local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(row, {
      state = "merge-ready",
      version = timeout_version,
    }, proposal_id, source_ref, 3)
    local result = run_timeout_reconcile(payload, {
      state_comment("merge-ready", timeout_version, "2026-06-03T00:00:00Z"),
      timeout_attempt_comment("merge-ready", lineages.review_loop, 1, source_ref),
      timeout_attempt_comment("merge-ready", lineages.review_loop, 2, source_ref),
      merge_gate_wait_comment(lineages.review_loop, timestamp_minutes_before(now_seconds, wait_age_minutes)),
    }, "timeout-reconcile-review-loop-lineage-merge-gate-wait-age", now_seconds)
    -- Owner directive (#2725): the timeout-reconcile department path to terminal blocked
    -- is neutralized -- the re-derived timeout decision is redrive (never escalate), so a
    -- timeout-reconcile event is a no-op skip (no-longer-over-budget); it emits no terminal
    -- "why" PR comment and never drops merge-ready to blocked.
    t.eq(result.exit_code, 0)
    t.eq(h.find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
  end,
}
