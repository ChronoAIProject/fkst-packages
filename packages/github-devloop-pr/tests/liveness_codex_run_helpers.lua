local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local requests_review = require("devloop.requests.review")
local convergence_shared = require("devloop.convergence.shared")
local contract_time = require("contract.time")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")
local conv_rounds = require("devloop.convergence.rounds")
local conv_attempts = require("devloop.convergence.attempts")
local m_rae = require("devloop.restart_actionable_epoch")
local dispatch_live_run = require("devloop.dispatch_live_run")
local t = h.t
local core = h.core
local restart_policy = assert(rawget(core, "restart_policy"))
local opts = h.opts
local replay_fields = require("devloop.replay_fields")
local fixing = h.fixing
local run_fix = h.run_fix
local mock_issue_fix_for_event = h.mock_issue_fix_for_event
local mock_pr_fix = h.mock_pr_fix
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local mock_git_push = h.mock_git_push
local mock_existing_fix_worktree = h.mock_existing_fix_worktree
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local count_calls = h.count_calls
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local devloop_logging = require("devloop.logging")
local ci_repair_attempts = require("core.ci_repair_attempts")
local ci_repair_retry = require("core.ci_repair_retry")
local config = require("devloop.config")
local testing = require("testkit_internal.testing")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function live_run_timing()
  local started = now() - 60
  return os.date("!%Y-%m-%dT%H:%M:%SZ", started),
    started * 1000,
    (now() + 3600) * 1000
end

local function seed_role_codex_run(run_opts, role, run_proposal_id, dedup_key, extra)
  local started_at, started_at_ms, lease_expires_at_ms = live_run_timing()
  local record = {
    role = role,
    dept = role,
    proposal_id = run_proposal_id,
    dedup_key = dedup_key,
    status = "running",
    started_at = started_at,
    started_at_ms = started_at_ms,
    lease_expires_at_ms = lease_expires_at_ms,
    timeout_seconds = 3600,
    log_path = "/tmp/fkst-packages-test/codex.log",
    cmd_line = "codex exec -",
  }
  for key, value in pairs(extra or {}) do
    record[key] = value
  end
  return testing.seed_running_codex_status(run_opts, record)
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function recent_comment(body)
  return trusted_comment(body, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 60))
end

local function fixing_state(event, version, created_at)
  return {
    state = "fixing",
    version = version or event.version,
    proposal_id = event.proposal_id,
    marker_created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function fixing_comments(event, version)
  return {
    trusted_comment(m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")),
    trusted_comment(core.state_marker(event.proposal_id, "fixing", version or event.version)),
    trusted_comment(m_builders.review_result_marker(event.review_proposal_id, event.proposal_id, "reject", event.review_dedup_key, 1, "missing regression guard")),
    trusted_comment(m_builders.merge_gate_marker(event.proposal_id,
      event.pr_number,
      event.version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha,
      nil,
      "missing regression guard",
      nil,
      event.ci_failure_key
    )),
  }
end

local function review_meta_comments(event, version)
  return {
    trusted_comment(m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")),
    trusted_comment(core.state_marker(event.proposal_id, "review-meta", version or event.version)),
    trusted_comment(m_builders.review_meta_marker(event.proposal_id, event.dedup_key)),
    trusted_comment(m_builders.review_result_marker(event.review_proposal_id, event.proposal_id, "reject", event.review_dedup_key, 1, "missing regression guard")),
    trusted_comment(conv_rounds.review_converge_round_marker(restart_policy,
      event.review_proposal_id,
      event.proposal_id,
      event.version,
      "def456",
      convergence_shared.source_ref_digest(entity_lib.pr_source_ref(repo, event.pr_number)),
      event.n,
      event.review_dedup_key,
      "Need a meta decision.",
      { { angle = "minimal", verdict = "no", digest = "gap" } }
    )),
  }
end

local function timeout_attempt_v2_comment(row, state, comments, round)
  local facts = {
    proposal_id = state.proposal_id,
    current = { comments = comments or {} },
    current_pr = { comments = comments or {}, head_sha = "def456" },
    source_ref = entity_lib.pr_source_ref(repo, 7),
  }
  local eval = m_rae.actionable_epoch_resolve(core, row, state, facts, contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z"))
  return trusted_comment(conv_attempts.timeout_attempt_v2_marker(proposal_id,
    row.from_state,
    row.liveness_class_id,
    eval.generation_key,
    round,
    entity_lib.pr_source_ref(repo, 7)
  ))
end

local function timeout_facts(event, state, comments)
  local current_head_sha = event.reviewed_head_sha
  if current_head_sha == nil then
    local _, _, _, review_head_sha = devloop_base.parse_pr_review_proposal_id(event.review_proposal_id)
    current_head_sha = review_head_sha
  end
  if current_head_sha == nil then
    error("github-devloop-pr test: current PR head is required for timeout facts")
  end
  return {
    proposal_id = event.proposal_id,
    source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
    current = { comments = comments },
    current_pr = {
      comments = comments,
      head_ref_name = "devloop-owner-repo-42-01HY",
      head_sha = current_head_sha,
      base_ref_name = "dev",
      state = "OPEN",
    },
    link = {
      proposal_id = event.proposal_id,
      pr_number = event.pr_number,
      branch = "devloop-owner-repo-42-01HY",
      impl_version = event.version,
      base_branch = "dev",
    },
    snapshot = {
      comments = comments,
      prs = { { number = event.pr_number, current = {
        comments = comments,
        head_ref_name = "devloop-owner-repo-42-01HY",
        head_sha = current_head_sha,
        base_ref_name = "dev",
        state = "OPEN",
      } } },
      state = state,
    },
    head_sha = current_head_sha,
    fresh_current_state = state,
    now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z"),
  }
end

local function ci_repair_hold_fixture(created_at)
  local event = fixing({
    repair_input = "ci-failure",
    ci_failure_key = "head:def456/checks:digest-0000000101",
  })
  local comments = fixing_comments(event)
  table.insert(comments, trusted_comment(
    ci_repair_attempts.comment_request(repo, event, "no-fix", "No repaired revision was published.").body,
    created_at
  ))
  local state = fixing_state(event, nil, "2026-06-03T01:00:00Z")
  local row = restart_transition_row("fixing")
  local facts = timeout_facts(event, state, comments)
  local delay_seconds = core.version_fix_round(state.version)
    * config.liveness_poll_cadence_seconds()
  local due_seconds = math.max(
    contract_time.iso_timestamp_epoch_seconds(state.marker_created_at),
    contract_time.iso_timestamp_epoch_seconds(transition_version.updated_at(state.version))
  )
    + delay_seconds
  return event, comments, state, row, facts, due_seconds, delay_seconds
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

local function captured_raise_index(raised, queue, predicate)
  for index, item in ipairs(raised or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload, item)) then
      return index
    end
  end
  return nil
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

local function with_codex_runs_unavailable(fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    error("forced codex liveness lookup failure")
  end
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

local function dispatch_liveness()
  return {
    restart_transition_table = function()
      return core.restart_transition_table()
    end,
    restart_row_receiver_liveness = function(...)
      return core.restart_row_receiver_liveness(...)
    end,
  }
end

local function mock_repo_and_empty_issue_list()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = '[{"number":7,"state":"open","updated_at":"2026-06-04T01:02:03Z"}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_claim()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 42,
    labels = { "fkst-dev:enabled", "fkst-dev:fixing" },
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    register_all_views = true,
    times = 1,
  })
end

local function mock_pr_state(comments, extra)
  local selected = extra or {}
  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = 7,
    head = "devloop-owner-repo-42-01HY",
    head_sha = "def456",
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    comments = comments,
    labels = {},
    mergeable = selected.mergeable,
    merge_state = selected.merge_state,
    status_check_rollup_json = selected.status_check_rollup_json,
    register_all_views = true,
    times = 3,
  })
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = 7,
    head = "devloop-owner-repo-42-01HY",
    head_sha = "def456",
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    comments = comments,
    labels = {},
    mergeable = selected.mergeable,
    merge_state = selected.merge_state,
    status_check_rollup_json = selected.status_check_rollup_json,
  }, entity_read_mocks.pr_origin_selector)
end

local function reject_comment(event)
  return requests_review.build_review_result_comment_request(core.output_language,     repo,
    "42",
    event.proposal_id,
    event.version,
    {
      proposal_id = event.review_proposal_id,
      decision = "reject",
      body = "Reject because parser must fail closed.",
      blocking_gap = "missing regression guard",
      dedup_key = event.review_dedup_key,
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    },
    event.source_ref
  ).body
end

local function mock_fix_dispatch_context(event, branch, rejection, times)
  mock_bot_env()
  mock_write_env("1")
  mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    rejection,
  }, branch, event.version)
  mock_pr_fix(
    { m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev") },
    branch,
    event.reviewed_head_sha,
    nil,
    nil,
    nil,
    times
  )
end

local function run_liveness_scan(name, run_opts, now_seconds)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = { schema = "github-devloop.tick.v1" },
    ts = "2026-06-04T01:32:03Z",
    now_seconds = now_seconds,
  }, run_opts or opts(name or "fixing-codex-run-liveness"))
end


local function assert_live_run_over_row_budget_caps(event, row, state, facts, role, dedup_key)
  with_codex_runs({
    {
      run_id = role .. "-live-over-row-budget",
      role = role,
      proposal_id = event.proposal_id,
      dedup_key = dedup_key,
      status = "running",
      lease_expires_at_ms = (facts.now_seconds + 3600) * 1000,
    },
  }, function()
    local receiver = core.restart_row_receiver_liveness(row, state, facts, facts.now_seconds)
    t.eq(receiver.action, "stuck")
    t.eq(receiver.reason, "row-budget-absolute-cap")
    local due, age = core.liveness_timeout_due_with_facts(row, state, facts, facts.now_seconds)
    t.eq(due, true)
    t.eq(age, 180)
  end)
end


return {
  devloop_base = devloop_base,
  entity_lib = entity_lib,
  requests_review = requests_review,
  convergence_shared = convergence_shared,
  contract_time = contract_time,
  transition_version = transition_version,
  h = h,
  conv_rounds = conv_rounds,
  conv_attempts = conv_attempts,
  m_rae = m_rae,
  dispatch_live_run = dispatch_live_run,
  t = t,
  core = core,
  opts = opts,
  replay_fields = replay_fields,
  fixing = fixing,
  run_fix = run_fix,
  mock_issue_fix_for_event = mock_issue_fix_for_event,
  mock_pr_fix = mock_pr_fix,
  mock_implement_codex = mock_implement_codex,
  mock_git_status = mock_git_status,
  mock_git_commit = mock_git_commit,
  mock_git_push = mock_git_push,
  mock_existing_fix_worktree = mock_existing_fix_worktree,
  mock_write_env = mock_write_env,
  mock_bot_env = mock_bot_env,
  count_calls = count_calls,
  entity_read_mocks = entity_read_mocks,
  m_builders = m_builders,
  devloop_logging = devloop_logging,
  ci_repair_attempts = ci_repair_attempts,
  ci_repair_retry = ci_repair_retry,
  config = config,
  repo = repo,
  proposal_id = proposal_id,
  restart_transition_row = restart_transition_row,
  seed_role_codex_run = seed_role_codex_run,
  trusted_comment = trusted_comment,
  recent_comment = recent_comment,
  fixing_state = fixing_state,
  fixing_comments = fixing_comments,
  review_meta_comments = review_meta_comments,
  timeout_attempt_v2_comment = timeout_attempt_v2_comment,
  timeout_facts = timeout_facts,
  ci_repair_hold_fixture = ci_repair_hold_fixture,
  capture_raises = capture_raises,
  captured_raise = captured_raise,
  captured_raise_index = captured_raise_index,
  with_codex_runs = with_codex_runs,
  with_codex_runs_unavailable = with_codex_runs_unavailable,
  dispatch_liveness = dispatch_liveness,
  mock_repo_and_empty_issue_list = mock_repo_and_empty_issue_list,
  mock_pr_list = mock_pr_list,
  mock_issue_claim = mock_issue_claim,
  mock_pr_state = mock_pr_state,
  reject_comment = reject_comment,
  mock_fix_dispatch_context = mock_fix_dispatch_context,
  run_liveness_scan = run_liveness_scan,
  assert_live_run_over_row_budget_caps = assert_live_run_over_row_budget_caps,
}
