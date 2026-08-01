local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local github_fake = require("forge.github_fake")
local queue_starvation = require("devloop.queue_starvation")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local conv_reconcile = require("devloop.convergence.reconcile")
local conv_rounds = require("devloop.convergence.rounds")
local convergence_shared = require("devloop.convergence.shared")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local marker_builders = require("devloop.markers.builders")
local operator_commands = require("devloop.operator_commands")
local transition_version = require("contract.transition_version")

local repo = "owner/repo"
local source_issue_number = 42
local escalation_issue_number = 900
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "ready/2026-07-27T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local reason_class = "state-output-obligation-timeout"
local pr_number = 77
local pr_branch = "devloop-owner-repo-42-live-recovery"
local pr_head_sha = "abcdef1234567890abcdef1234567890abcdef12"
local pr_blocked_version = "implement/2026-07-27T12-00-00Z/review-loop/3"
local prior_intake_dedup = "intake/github-devloop/issue/owner/repo/42/original"

local marker_core = {
  liveness_heartbeat_version = function(version)
    return transition_version.safe_version_segment(version)
  end,
  liveness_signal_producer_contract = function(family)
    t.eq(family, "review-converge-round")
    return { version_form = "safe_version_segment" }
  end,
}

local function escalation_fact()
  return {
    proposal_id = proposal_id,
    terminal_version = terminal_version,
    dedup_key = core.output_obligation_failure_dedup_key(
      repo,
      proposal_id,
      terminal_version,
      reason_class
    ),
    reason_class = reason_class,
    source_repo = repo,
    issue_number = source_issue_number,
  }
end

local function escalation_marker()
  return core.output_obligation_escalation_marker(escalation_fact())
end

local function source_timeout_marker()
  return conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
    terminal_version = terminal_version,
    from_state = "ready",
    from_version = ready_version,
    attempt = 3,
    attempt_limit = 3,
    driving_queue = "github-devloop.devloop_ready",
    reason_class = reason_class,
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    },
  })
end

local function bot_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-07-27T12:10:00Z",
  }
end

local function identified_bot_comment(id, body, created_at)
  return {
    id = id,
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-07-27T12:20:00Z",
  }
end

local function append_comment(comments, comment)
  local copied = {}
  for _, existing in ipairs(comments or {}) do
    table.insert(copied, existing)
  end
  table.insert(copied, comment)
  return copied
end

local function live_source_fixture(with_pr)
  local comments = {
    bot_comment(marker_builders.intake_decision_marker(
      proposal_id,
      "enable",
      prior_intake_dedup,
      "standard"
    )),
    bot_comment(source_timeout_marker()),
    bot_comment(core.state_marker(proposal_id, "blocked", terminal_version)),
  }
  if with_pr then
    table.insert(comments, bot_comment(marker_builders.pr_delegation_marker(
      proposal_id,
      entity_lib.pr_proposal_id(repo, pr_number),
      pr_number,
      ready_version,
      "g1"
    )))
  end
  return {
    repo = repo,
    number = source_issue_number,
    state = "OPEN",
    title = "Recover this output obligation",
    body = "Original issue body",
    updated_at = "2026-07-27T12:12:00Z",
    comments = comments,
    labels = { core._blocked_label },
    author_login = "alice",
  }
end

local function pr_fixture(state, version)
  return {
    repo = repo,
    number = pr_number,
    state = "OPEN",
    head = pr_branch,
    head_sha = pr_head_sha,
    base_branch = "dev",
    head_repo = repo,
    cross_repo = false,
    comments = {
      bot_comment(marker_builders.pr_origin_marker(
        proposal_id,
        tostring(source_issue_number),
        pr_branch,
        ready_version,
        "dev"
      )),
      bot_comment(core.state_marker(proposal_id, state, version)),
    },
  }
end

local function add_stalled_review_markers(pr)
  local review_proposal = devloop_base.pr_review_proposal_id(
    repo,
    pr_number,
    pr_blocked_version,
    pr_head_sha
  )
  local review_version = transition_version.safe_version_segment(pr_blocked_version)
  local source_digest = convergence_shared.source_ref_digest(entity_lib.pr_source_ref(repo, pr_number))
  local angles = {
    { angle = "fidelity", verdict = "abstain", digest = "same-review-digest" },
  }
  for round = 1, 3 do
    pr.comments = append_comment(pr.comments, bot_comment(conv_rounds.review_converge_round_marker(
      marker_core,
      review_proposal,
      proposal_id,
      review_version,
      pr_head_sha,
      source_digest,
      round,
      "review-loop/" .. tostring(round),
      "Same review question",
      angles
    )))
  end
end

local function mock_env(write_mode)
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
  end
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    t.mock_command('if [ -n "${' .. name .. ':-}" ]; then printf present; fi', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_census(comments, opts)
  local empty = { stdout = "[]\n", stderr = "", exit_code = 0 }
  if opts and opts.over_cap then
    entity_read_mocks.mock_issue_list_command(
      t,
      core.gh_issue_list_observe_cmd(repo, core._enabled_label, 1, true),
      {
        {
          number = 1,
          state = "OPEN",
          labels = { core._enabled_label },
          author_login = "alice",
        },
      }
    )
  else
    t.mock_command(core.gh_issue_list_observe_cmd(repo, core._enabled_label, 1, true), empty)
  end
  for _, state in ipairs(core.issue_state_order()) do
    t.mock_command(core.gh_issue_list_observe_cmd(repo, core.state_label(state), 1, true), empty)
  end
  entity_read_mocks.mock_issue_list_command(
    t,
    core.gh_issue_list_observe_cmd(repo, core._hold_label, 1, true),
    {
      {
        number = escalation_issue_number,
        state = "OPEN",
        labels = { core._hold_label },
        author_login = "fkst-test-bot",
      },
    }
  )
  t.mock_command(core.gh_pr_list_observe_cmd(repo, 1, true), empty)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = escalation_issue_number,
    title = "Escalate blocked output obligation",
    body = "Escalation.\n\n" .. escalation_marker(),
    state = "OPEN",
    labels = { core._hold_label },
    comments = comments or {},
    author_login = "fkst-test-bot",
    assignees = {},
  }, "title,body,comments,labels,state,stateReason,assignees,author")
end

local function with_unrelated_controls_stubbed(fn)
  local originals = {
    collect_recent_merged_prs = core.collect_recent_merged_prs,
    collect_recent_merged_issues = core.collect_recent_merged_issues,
    reap_orphan_prs = core.reap_orphan_prs,
    observe_conflict_hotspots = core.observe_conflict_hotspots,
    render_observability_dashboard = core.render_observability_dashboard,
    publish_observability_dashboard = core.publish_observability_dashboard,
    observability_topology_mermaid = core.observability_topology_mermaid,
    observe_queue_starvation = queue_starvation.observe_queue_starvation,
  }
  core.collect_recent_merged_prs = function() return {} end
  core.collect_recent_merged_issues = function() return {} end
  core.reap_orphan_prs = function() end
  core.observe_conflict_hotspots = function()
    return { facts = 0, hotspots = 0, raised = 0 }
  end
  core.render_observability_dashboard = function()
    return { hash = "resolution-test", body = "resolution test" }
  end
  core.publish_observability_dashboard = function() return "dry-run" end
  core.observability_topology_mermaid = function() return nil end
  queue_starvation.observe_queue_starvation = function()
    return { action = "observed" }
  end

  local ok, result = pcall(fn)
  core.collect_recent_merged_prs = originals.collect_recent_merged_prs
  core.collect_recent_merged_issues = originals.collect_recent_merged_issues
  core.reap_orphan_prs = originals.reap_orphan_prs
  core.observe_conflict_hotspots = originals.observe_conflict_hotspots
  core.render_observability_dashboard = originals.render_observability_dashboard
  core.publish_observability_dashboard = originals.publish_observability_dashboard
  core.observability_topology_mermaid = originals.observability_topology_mermaid
  queue_starvation.observe_queue_starvation = originals.observe_queue_starvation
  if not ok then error(result, 0) end
  return result
end

local function fake_department(opts)
  local options = opts or {}
  local source_fixture = options.source_issue or {
    repo = repo,
    number = source_issue_number,
    state = "CLOSED",
    title = "Resolved source issue",
    comments = { bot_comment(source_timeout_marker()) },
    labels = {},
    author_login = "alice",
  }
  local escalation_fixture = options.escalation_issue or {
    repo = repo,
    number = escalation_issue_number,
    state = "OPEN",
    title = "Escalate blocked output obligation",
    body = "Escalation.\n\n" .. escalation_marker(),
    comments = {},
    labels = { core._hold_label },
    author_login = "fkst-test-bot",
  }
  local model = github_fake.model({
    issues = {
      ["owner/repo#issue/42"] = source_fixture,
      ["owner/repo#issue/900"] = escalation_fixture,
    },
  })
  model.prs = options.prs or {}
  local github = github_fake.new(model)
  local control = { close_attempts = 0 }
  local reads = {}
  local pr_reads = {}
  local read_issue = github.read_issue
  github.read_issue = function(source_ref, opts)
    table.insert(reads, {
      source_ref = source_ref,
      force_fresh = opts and opts.force_fresh,
    })
    return read_issue(source_ref, opts)
  end
  github.pr_cli_view = function(read_repo, read_pr_number, fields, timeout)
    table.insert(pr_reads, {
      repo = read_repo,
      number = read_pr_number,
      fields = fields,
      timeout = timeout,
    })
    if options.fail_pr_read then
      return { stdout = "", stderr = "forced PR read failure", exit_code = 1 }
    end
    local fixture = model.prs[tostring(read_repo) .. "#pr/" .. tostring(read_pr_number)]
    if fixture == nil then
      return { stdout = "", stderr = "HTTP 404: pull request not found", exit_code = 1 }
    end
    return {
      stdout = entity_read_mocks.pr_view_stdout(fixture),
      stderr = "",
      exit_code = 0,
    }
  end
  if options.fail_first_close then
    local issue_close = github.issue_close
    github.issue_close = function(...)
      control.close_attempts = control.close_attempts + 1
      if control.close_attempts == 1 then
        return { stdout = "", stderr = "forced close failure", exit_code = 1 }
      end
      return issue_close(...)
    end
  end
  local installed = require("departments.observability.main")
  local department = installed.make_department({ github = github })
  return department, model, reads, control, pr_reads
end

local function tick_event(fields)
  local payload = { schema = "github-devloop.observe-tick.v1" }
  for key, value in pairs(fields or {}) do
    payload[key] = value
  end
  return {
    queue = "devloop_observe_tick",
    payload = payload,
  }
end

local function run_tick(department, fields)
  return with_unrelated_controls_stubbed(function()
    return testing.run_fake(department, tick_event(fields))
  end)
end

local function run_tick_expecting_failure(department, fields)
  return with_unrelated_controls_stubbed(function()
    return testing.run_fake_expecting_failure(department, tick_event(fields))
  end)
end

local function with_entity_cap(cap, fn)
  local original = core.observability_limits
  core.observability_limits = function()
    local limits = original()
    limits.entity_cap = cap
    return limits
  end
  local ok, result = pcall(fn)
  core.observability_limits = original
  if not ok then
    error(result, 0)
  end
  return result
end

local function find_raise(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

local function find_target_raise(raises, queue, field, value)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue and tostring(raised.payload and raised.payload[field]) == tostring(value) then
      return raised
    end
  end
  return nil
end

local function close_write(writes)
  for _, write in ipairs(writes or {}) do
    local argv = write.argv or {}
    if argv[1] == "gh" and argv[2] == "issue" and argv[3] == "close" then
      return write
    end
  end
  return nil
end

return {
  test_observe_tick_discovers_hold_and_emits_receipt_for_closed_source = function()
    mock_env("1")
    mock_census({})
    local department, model, reads = fake_department()

    local result = run_tick(department)

    t.eq(#reads, 2)
    t.eq(reads[1].source_ref.ref, "owner/repo#issue/42")
    t.eq(reads[1].force_fresh, true)
    t.eq(reads[2].source_ref.ref, "owner/repo#issue/900")
    t.eq(reads[2].force_fresh, true)
    local receipt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(receipt ~= nil)
    t.eq(receipt.payload.issue_number, escalation_issue_number)
    t.eq(receipt.payload.source_ref.ref, "owner/repo#issue/900")
    t.is_true(receipt.payload.body:find("output-obligation-resolution-receipt:v1", 1, true) ~= nil)
    t.eq(close_write(model.writes), nil)
  end,

  test_observe_tick_dry_run_emits_receipt_intent_without_direct_write = function()
    mock_env("")
    mock_census({})
    local department, model = fake_department()

    local result = run_tick(department)

    local receipt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(receipt ~= nil)
    t.eq(receipt.payload.issue_number, escalation_issue_number)
    t.eq(#model.writes, 0)
    t.eq(close_write(model.writes), nil)
  end,

  test_partial_rotating_census_still_resolves_selected_hold_issue = function()
    mock_env("1")
    mock_census({}, { over_cap = true })
    local department = fake_department()

    local result = with_entity_cap(1, function()
      return run_tick(department, { tick = "1" })
    end)

    t.is_true(find_raise(result.raises, "github-proxy.github_issue_comment_request") ~= nil)
  end,

  test_receipt_only_partial_success_retries_close_without_duplicate_receipt = function()
    mock_env("1")
    mock_census({})
    local department, model, reads, control = fake_department({ fail_first_close = true })

    local first = run_tick(department)
    local receipt = find_raise(first.raises, "github-proxy.github_issue_comment_request")
    t.is_true(receipt ~= nil)
    local rendered_receipt = receipt.payload.body
      .. "\n\n<!-- fkst:github-proxy:comment:" .. receipt.payload.dedup_key .. " -->\n"
    model.issues["owner/repo#issue/900"].comments = { bot_comment(rendered_receipt) }

    mock_census({ bot_comment(rendered_receipt) })
    local failed = run_tick_expecting_failure(department)
    t.is_true(tostring(failed.failure.error):find("output-obligation-close-failed", 1, true) ~= nil)
    t.eq(control.close_attempts, 1)

    mock_census({ bot_comment(rendered_receipt) })
    local replay = run_tick(department)

    t.eq(#reads, 10)
    t.eq(reads[6].source_ref.ref, "owner/repo#issue/900")
    t.eq(reads[6].force_fresh, true)
    t.eq(reads[10].source_ref.ref, "owner/repo#issue/900")
    t.eq(reads[10].force_fresh, true)
    t.eq(find_raise(replay.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(control.close_attempts, 2)
    local closed = close_write(model.writes)
    t.is_true(closed ~= nil)
    t.eq(closed.argv[4], tostring(escalation_issue_number))
    t.eq(closed.argv[6], repo)
    t.eq(closed.argv[7], "--reason")
    t.eq(closed.argv[8], "completed")
  end,

  test_observe_tick_dry_run_does_not_close_after_visible_receipt = function()
    mock_env("")
    local fact = escalation_fact()
    mock_census({ bot_comment(core.output_obligation_resolution_receipt_marker(fact)) })
    local department, model = fake_department()
    model.issues["owner/repo#issue/900"].comments = {
      bot_comment(core.output_obligation_resolution_receipt_marker(fact)),
    }

    local result = run_tick(department)

    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(close_write(model.writes), nil)
  end,

  test_rereview_multitick_recovers_command_applied_receipt_and_close = function()
    mock_env("1")
    local source = live_source_fixture(true)
    local pr = pr_fixture("blocked", pr_blocked_version)
    local department, model, _, _, pr_reads = fake_department({
      source_issue = source,
      prs = { ["owner/repo#pr/77"] = pr },
    })

    mock_census({})
    local command_tick = run_tick(department)
    local command_raise = find_target_raise(
      command_tick.raises,
      "github-proxy.github_pr_comment_request",
      "pr_number",
      pr_number
    )
    t.is_true(command_raise ~= nil)
    t.is_true(command_raise.payload.body:find("fkst: rereview", 1, true) == 1)
    t.eq(#pr_reads, 1)

    local command_comment = identified_bot_comment(
      "IC_rereview_recovery",
      command_raise.payload.body
    )
    pr.comments = append_comment(pr.comments, command_comment)
    mock_census({})
    local command_only = run_tick(department)
    t.eq(find_target_raise(command_only.raises, "github-proxy.github_pr_comment_request", "pr_number", pr_number), nil)
    t.eq(find_target_raise(command_only.raises, "github-proxy.github_issue_comment_request", "issue_number", escalation_issue_number), nil)

    local command_fact = operator_commands.operator_command_fact(pr.comments, "rereview")
    pr.comments = append_comment(pr.comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "rereview")
    ))
    mock_census({})
    local applied_only = run_tick(department)
    t.eq(find_target_raise(applied_only.raises, "github-proxy.github_issue_comment_request", "issue_number", escalation_issue_number), nil)

    local target_version = operator_commands.operator_rereview_version(pr_blocked_version, pr_head_sha)
    pr.comments = append_comment(pr.comments, bot_comment(
      core.state_marker(proposal_id, "reviewing", target_version)
    ))
    mock_census({})
    local receipt_tick = run_tick(department)
    local receipt = find_target_raise(
      receipt_tick.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      escalation_issue_number
    )
    t.is_true(receipt ~= nil)
    t.is_true(receipt.payload.body:find('decision="rereview"', 1, true) ~= nil)

    model.issues["owner/repo#issue/900"].comments = { bot_comment(receipt.payload.body) }
    mock_census(model.issues["owner/repo#issue/900"].comments)
    local close_tick = run_tick(department)
    t.eq(find_target_raise(close_tick.raises, "github-proxy.github_issue_comment_request", "issue_number", escalation_issue_number), nil)
    t.is_true(close_write(model.writes) ~= nil)
  end,

  test_refused_rereview_falls_through_to_fresh_reintake_without_reemitting = function()
    mock_env("1")
    local source = live_source_fixture(true)
    local pr = pr_fixture("blocked", pr_blocked_version)
    local department = fake_department({
      source_issue = source,
      prs = { ["owner/repo#pr/77"] = pr },
    })

    mock_census({})
    local command_tick = run_tick(department)
    local rereview = find_target_raise(
      command_tick.raises,
      "github-proxy.github_pr_comment_request",
      "pr_number",
      pr_number
    )
    t.is_true(rereview ~= nil)

    local refusal_body = operator_commands.build_output_obligation_command_write_refusal_body(
      rereview.payload.body,
      "command-authority-changed"
    )
    local command_comment = identified_bot_comment(
      "IC_rereview_refused",
      refusal_body
    )
    pr.comments = append_comment(pr.comments, command_comment)
    local command_fact = operator_commands.operator_command_fact(pr.comments, "rereview")
    local response = operator_commands.operator_command_response_fact(pr.comments, command_fact)
    t.is_true(response ~= nil)
    t.eq(response.outcome, "refused")
    t.eq(response.reason, "command-authority-changed")
    pr.comments = append_comment(pr.comments, bot_comment(
      core.state_marker(proposal_id, "merged", pr_blocked_version)
    ))
    pr.state = "MERGED"

    mock_census({})
    local recovery_tick = run_tick(department)
    t.eq(find_target_raise(
      recovery_tick.raises,
      "github-proxy.github_pr_comment_request",
      "pr_number",
      pr_number
    ), nil)
    local reintake = find_target_raise(
      recovery_tick.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      source_issue_number
    )
    t.is_true(reintake ~= nil)
    t.is_true(reintake.payload.body:find("fkst: reintake", 1, true) == 1)
  end,

  test_reintake_multitick_recovers_command_applied_generation_receipt_and_close = function()
    mock_env("1")
    local source = live_source_fixture(false)
    local department, model = fake_department({ source_issue = source })

    mock_census({})
    local command_tick = run_tick(department)
    local command_raise = find_target_raise(
      command_tick.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      source_issue_number
    )
    t.is_true(command_raise ~= nil)
    t.is_true(command_raise.payload.body:find("fkst: reintake", 1, true) == 1)

    local command_comment = identified_bot_comment(
      "IC_reintake_recovery",
      command_raise.payload.body,
      "2026-07-27T12:30:00Z"
    )
    source.comments = append_comment(source.comments, command_comment)
    mock_census({})
    local command_only = run_tick(department)
    t.eq(find_target_raise(command_only.raises, "github-proxy.github_issue_comment_request", "issue_number", source_issue_number), nil)

    local command_fact = operator_commands.operator_command_fact(source.comments, "reintake")
    source.comments = append_comment(source.comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "reintake")
    ))
    mock_census({})
    local applied_only = run_tick(department)
    t.eq(find_target_raise(applied_only.raises, "github-proxy.github_issue_comment_request", "issue_number", escalation_issue_number), nil)

    local effective_updated_at = operator_commands.reintake_effect_updated_at(
      source,
      command_fact,
      source.comments,
      proposal_id
    )
    local expected_intake_dedup = devloop_base.intake_decision_dedup_key(
      proposal_id,
      source,
      command_fact,
      effective_updated_at
    )
    source.comments = append_comment(source.comments, bot_comment(
      marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        expected_intake_dedup,
        "standard"
      )
    ))
    mock_census({})
    local decision_only = run_tick(department)
    t.eq(find_target_raise(
      decision_only.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      escalation_issue_number
    ), nil)

    source.comments = append_comment(source.comments, bot_comment(
      core.state_marker(proposal_id, "thinking", expected_intake_dedup)
    ))
    mock_census({})
    local receipt_tick = run_tick(department)
    local receipt = find_target_raise(
      receipt_tick.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      escalation_issue_number
    )
    t.is_true(receipt ~= nil)
    t.is_true(receipt.payload.body:find('decision="abandon-recreate"', 1, true) ~= nil)

    model.issues["owner/repo#issue/900"].comments = { bot_comment(receipt.payload.body) }
    mock_census(model.issues["owner/repo#issue/900"].comments)
    run_tick(department)
    t.is_true(close_write(model.writes) ~= nil)
  end,

  test_active_linked_pr_states_wait_without_effect_across_ticks = function()
    for _, state in ipairs({ "reviewing", "fixing" }) do
      mock_env("1")
      local source = live_source_fixture(true)
      local pr = pr_fixture(state, pr_blocked_version)
      local department, model = fake_department({
        source_issue = source,
        prs = { ["owner/repo#pr/77"] = pr },
      })
      for _ = 1, 2 do
        mock_census({})
        local result = run_tick(department)
        t.eq(find_target_raise(result.raises, "github-proxy.github_pr_comment_request", "pr_number", pr_number), nil)
        t.eq(find_target_raise(result.raises, "github-proxy.github_issue_comment_request", "issue_number", source_issue_number), nil)
        t.eq(find_target_raise(result.raises, "github-proxy.github_issue_comment_request", "issue_number", escalation_issue_number), nil)
        t.eq(close_write(model.writes), nil)
      end
    end
  end,

  test_stalled_reviewing_pr_emits_rereview_command_on_observe_tick = function()
    mock_env("1")
    local source = live_source_fixture(true)
    local pr = pr_fixture("reviewing", pr_blocked_version)
    add_stalled_review_markers(pr)
    local department = fake_department({
      source_issue = source,
      prs = { ["owner/repo#pr/77"] = pr },
    })
    mock_census({})

    local result = run_tick(department)

    local command = find_target_raise(
      result.raises,
      "github-proxy.github_pr_comment_request",
      "pr_number",
      pr_number
    )
    t.is_true(command ~= nil)
    t.is_true(command.payload.body:find("fkst: rereview", 1, true) == 1)
  end,

  test_live_recovery_dry_run_emits_intent_without_direct_write = function()
    mock_env("")
    local source = live_source_fixture(false)
    local department, model = fake_department({ source_issue = source })
    mock_census({})

    local result = run_tick(department)

    local command = find_target_raise(
      result.raises,
      "github-proxy.github_issue_comment_request",
      "issue_number",
      source_issue_number
    )
    t.is_true(command ~= nil)
    t.is_true(command.payload.body:find("fkst: reintake", 1, true) == 1)
    t.eq(#model.writes, 0)
  end,

  test_fresh_escalation_drift_blocks_live_command = function()
    mock_env("1")
    local source = live_source_fixture(false)
    local department, model = fake_department({
      source_issue = source,
      escalation_issue = {
        repo = repo,
        number = escalation_issue_number,
        state = "OPEN",
        title = "Escalate blocked output obligation",
        body = "Escalation.\n\n" .. escalation_marker(),
        comments = {},
        labels = {},
        author_login = "fkst-test-bot",
      },
    })
    mock_census({})

    local result = run_tick(department)

    t.eq(find_target_raise(result.raises, "github-proxy.github_issue_comment_request", "issue_number", source_issue_number), nil)
    t.eq(close_write(model.writes), nil)
  end,

  test_pr_adapter_failure_is_visible_and_cannot_resolve = function()
    mock_env("1")
    local source = live_source_fixture(true)
    local department, model = fake_department({
      source_issue = source,
      prs = { ["owner/repo#pr/77"] = pr_fixture("blocked", pr_blocked_version) },
      fail_pr_read = true,
    })
    mock_census({})

    local failed = run_tick_expecting_failure(department)

    t.is_true(tostring(failed.failure.error):find("linked PR state view failed", 1, true) ~= nil)
    t.eq(close_write(model.writes), nil)
  end,
}
