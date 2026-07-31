local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local github_fake = require("forge.github_fake")
local queue_starvation = require("devloop.queue_starvation")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local conv_reconcile = require("devloop.convergence.reconcile")

local repo = "owner/repo"
local source_issue_number = 42
local escalation_issue_number = 900
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "ready/2026-07-27T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local reason_class = "state-output-obligation-timeout"

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
  local model = github_fake.model({
    issues = {
      ["owner/repo#issue/42"] = {
        repo = repo,
        number = source_issue_number,
        state = "CLOSED",
        title = "Resolved source issue",
        comments = { bot_comment(source_timeout_marker()) },
        labels = {},
        author_login = "alice",
      },
      ["owner/repo#issue/900"] = {
        repo = repo,
        number = escalation_issue_number,
        state = "OPEN",
        title = "Escalate blocked output obligation",
        body = "Escalation.\n\n" .. escalation_marker(),
        comments = {},
        labels = { core._hold_label },
        author_login = "fkst-test-bot",
      },
    },
  })
  local github = github_fake.new(model)
  local control = { close_attempts = 0 }
  local reads = {}
  local read_issue = github.read_issue
  github.read_issue = function(source_ref, opts)
    table.insert(reads, {
      source_ref = source_ref,
      force_fresh = opts and opts.force_fresh,
    })
    return read_issue(source_ref, opts)
  end
  if opts and opts.fail_first_close then
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
  return department, model, reads, control
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

    t.eq(#reads, 1)
    t.eq(reads[1].source_ref.ref, "owner/repo#issue/42")
    t.eq(reads[1].force_fresh, true)
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

    t.eq(#reads, 5)
    t.eq(reads[3].source_ref.ref, "owner/repo#issue/900")
    t.eq(reads[3].force_fresh, true)
    t.eq(reads[5].source_ref.ref, "owner/repo#issue/900")
    t.eq(reads[5].force_fresh, true)
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

    local result = run_tick(department)

    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(close_write(model.writes), nil)
  end,
}
