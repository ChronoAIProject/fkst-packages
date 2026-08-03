local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local github_fake = require("forge.github_fake")
local queue_starvation = require("devloop.queue_starvation")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
require("departments.observability.terminal_retirement")

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local terminal_version = "github-devloop/issue/owner/repo/42/intake/retirement-test"
local result_dedup = "consensus:github-devloop/issue/owner/repo/42/intake/retirement-test"
local source_ref = { kind = "external", ref = "owner/repo#issue/42" }

local function bot_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2000-01-01T00:00:00Z",
  }
end

local function declined_comments()
  return {
    bot_comment(
      "github-devloop decision: decline: premise-refuted\n\n"
        .. core.state_marker(proposal_id, "declined", terminal_version, "result-marker,declined-label,premise-refuted")
        .. "\n"
        .. m_builders.result_marker(
          proposal_id,
          "reject",
          result_dedup,
          "premise-refuted",
          terminal_version
        )
    ),
  }
end

local function mock_env(write_mode)
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
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

local function mock_census(comments, state)
  local empty = { stdout = "[]\n", stderr = "", exit_code = 0 }
  t.mock_command(core.gh_issue_list_observe_cmd(repo, core._enabled_label, 1, true), empty)
  t.mock_command(core.gh_issue_list_observe_cmd(repo, core._hold_label, 1, true), empty)
  for _, state_name in ipairs(core.issue_state_order()) do
    if state_name == "declined" then
      entity_read_mocks.mock_issue_list_command(
        t,
        core.gh_issue_list_observe_cmd(repo, core.state_label(state_name), 1, true),
        {
          {
            number = issue_number,
            state = state or "OPEN",
            labels = { core.state_label("declined") },
            author_login = "alice",
          },
        }
      )
    else
      t.mock_command(core.gh_issue_list_observe_cmd(repo, core.state_label(state_name), 1, true), empty)
    end
  end
  t.mock_command(core.gh_pr_list_observe_cmd(repo, 1, true), empty)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    title = "Declined proposal",
    body = "Proposal body",
    state = state or "OPEN",
    labels = { core.state_label("declined") },
    comments = comments,
    author_login = "alice",
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
    return { hash = "retirement-test", body = "retirement test" }
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

local function fake_department(comments, state)
  local model = github_fake.model({
    issues = {
      [source_ref.ref] = {
        repo = repo,
        number = issue_number,
        state = state or "OPEN",
        title = "Declined proposal",
        body = "Proposal body",
        comments = comments,
        labels = { core.state_label("declined") },
        author_login = "alice",
        assignees = {},
      },
    },
  })
  local github = github_fake.new(model)
  local reads = {}
  local read_issue = github.read_issue
  github.read_issue = function(ref, opts)
    table.insert(reads, {
      ref = ref.ref,
      force_fresh = opts and opts.force_fresh,
    })
    return read_issue(ref, opts)
  end
  local installed = require("departments.observability.main")
  return installed.make_department({ github = github }), model, reads
end

local function run_tick(department)
  return with_unrelated_controls_stubbed(function()
    return testing.run_fake(department, {
      queue = "devloop_observe_tick",
      payload = { schema = "github-devloop.observe-tick.v1" },
    })
  end)
end

local function receipt_raise(result)
  local found = nil
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request"
      and tostring(raised.payload and raised.payload.body or ""):find(
        "terminal-retirement-receipt:v1",
        1,
        true
      ) ~= nil then
      t.eq(found, nil)
      found = raised
    end
  end
  return found
end

local function close_writes(model)
  local found = {}
  for _, write in ipairs(model.writes or {}) do
    local argv = write.argv or {}
    if argv[1] == "gh" and argv[2] == "issue" and argv[3] == "close" then
      table.insert(found, write)
    end
  end
  return found
end

local function capture_info_logs(fn)
  local original = log.info
  local lines = {}
  log.info = function(message)
    table.insert(lines, tostring(message))
  end
  local ok, result = pcall(fn)
  log.info = original
  if not ok then error(result, 0) end
  return result, lines
end

return {
  test_old_declined_issue_emits_one_receipt_then_closes_not_planned_once = function()
    mock_env("1")
    local comments = declined_comments()
    local department, model, reads = fake_department(comments)

    mock_census(comments, "OPEN")
    local first = run_tick(department)
    local receipt = receipt_raise(first)

    t.is_true(receipt ~= nil)
    t.eq(receipt.payload.issue_number, issue_number)
    t.eq(receipt.payload.source_ref.ref, source_ref.ref)
    t.is_true(receipt.payload.body:find("Terminal state: `declined`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Terminal marker version: `" .. terminal_version .. "`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Decline reason: `premise-refuted`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Elapsed dwell: `", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("reopening with a corrected premise or new evidence", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('proposal="' .. proposal_id .. '"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('terminal_version="' .. terminal_version .. '"', 1, true) ~= nil)
    t.eq(#close_writes(model), 0)
    t.eq(#reads, 1)
    t.eq(reads[1].ref, source_ref.ref)
    t.eq(reads[1].force_fresh, true)

    table.insert(model.issues[source_ref.ref].comments, bot_comment(receipt.payload.body, "2000-01-02T00:00:00Z"))
    mock_census(model.issues[source_ref.ref].comments, "OPEN")
    local second = run_tick(department)
    local closes = close_writes(model)

    t.eq(receipt_raise(second), nil)
    t.eq(#closes, 1)
    t.eq(closes[1].argv[4], tostring(issue_number))
    t.eq(closes[1].argv[6], repo)
    t.eq(closes[1].argv[7], "--reason")
    t.eq(closes[1].argv[8], "not planned")
    t.eq(#reads, 2)
    t.eq(reads[2].ref, source_ref.ref)
    t.eq(reads[2].force_fresh, true)

    model.issues[source_ref.ref].state = "CLOSED"
    mock_census(model.issues[source_ref.ref].comments, "CLOSED")
    local replay = run_tick(department)

    t.eq(receipt_raise(replay), nil)
    t.eq(#close_writes(model), 1)
    t.eq(#reads, 2)
  end,

  test_dry_run_logs_would_retire_and_performs_no_github_writes = function()
    mock_env("")
    local comments = declined_comments()
    local department, model = fake_department(comments)
    mock_census(comments, "OPEN")

    local result, logs = capture_info_logs(function()
      return run_tick(department)
    end)

    t.eq(receipt_raise(result), nil)
    t.eq(#model.writes, 0)
    local body = table.concat(logs, "\n")
    t.is_true(body:find("tag=TERMINAL_RETIREMENT", 1, true) ~= nil)
    t.is_true(body:find("decision=eligible", 1, true) ~= nil)
    t.is_true(body:find("action=would-retire", 1, true) ~= nil)
    t.is_true(body:find("mode=dry-run", 1, true) ~= nil)
  end,
}
