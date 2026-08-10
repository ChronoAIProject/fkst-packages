local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local github_fake = require("forge.github_fake")
local github_view = require("forge.github_view")
local queue_starvation = require("devloop.queue_starvation")
local output_obligation_resolution = require("departments.observability.output_obligation_resolution")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local payload_registry = require("devloop.payload_registry")
local decompose = require("devloop.decompose")
local conv_reconcile = require("devloop.convergence.reconcile")
local transition_version = require("contract.transition_version")
require("departments.observability.terminal_retirement")

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local declined_terminal_version = "github-devloop/issue/owner/repo/42/intake/retirement-test"
local result_dedup = "consensus:github-devloop/issue/owner/repo/42/intake/retirement-test"
local reconcile_base_version = "github-devloop/issue/owner/repo/42/intake/reconcile-retirement-test"
local reconcile_round = 3
local reconcile_terminal_version = conv_reconcile.reconcile_state_version(reconcile_base_version, reconcile_round)
local reconcile_impl_version = payload_registry.resolve("dedup:ready", {
  dedup_key = reconcile_base_version,
})
local delegated_pr_number = 7
local delegated_version = "ready/consensus-github-devloop/issue/owner/repo/42/retirement/fix/4"
local delegated_parent_version = transition_version.next_blocked(delegated_version, "child-pr-blocked")
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
        .. core.state_marker(proposal_id, "declined", declined_terminal_version, "result-marker,declined-label,premise-refuted")
        .. "\n"
        .. m_builders.result_marker(
          proposal_id,
          "reject",
          result_dedup,
          "premise-refuted",
          declined_terminal_version
        )
    ),
  }
end

local function reconcile_drop_comments(extra_comments)
  local comments = {
    bot_comment(
      "github-devloop reconcile action: drop\n\n"
        .. core.state_marker(proposal_id, "blocked", reconcile_terminal_version)
        .. "\n"
        .. conv_reconcile.reconcile_marker(
          proposal_id,
          reconcile_base_version,
          reconcile_round,
          "drop",
          "no-semantic-progress"
        )
    ),
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function delegated_parent_comments(extra_comments)
  local comments = {
    bot_comment(
      m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/7",
        delegated_pr_number,
        delegated_version,
        "g1"
      ),
      "2026-07-29T23:59:00Z"
    ),
    bot_comment(
      core.state_marker(proposal_id, "blocked", delegated_parent_version),
      "2026-07-30T00:02:00Z"
    ),
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function delegated_pr_comments(extra_comments, overrides)
  local values = overrides or {}
  local comments = {}
  if values.pr_link ~= false then
    table.insert(comments, bot_comment(
      values.pr_link or m_builders.pr_link_marker(
        proposal_id,
        delegated_pr_number,
        "devloop-owner-repo-42",
        delegated_version,
        "dev"
      ),
      "2026-07-29T23:59:00Z"
    ))
  end
  local reconcile_marker = values.reconcile_marker
    or conv_reconcile.fix_reconcile_marker(proposal_id, delegated_version, "drop")
  table.insert(comments, bot_comment(
    core.state_marker(proposal_id, "blocked", delegated_version)
      .. "\n" .. reconcile_marker,
    "2026-07-30T00:00:00Z"
  ))
  table.insert(comments, bot_comment(
    decompose.decomposed_marker(proposal_id, delegated_version, delegated_pr_number, 2),
    "2026-07-30T00:01:00Z"
  ))
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function delegated_child_issues()
  return {
    {
      number = 101,
      title = "First child",
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        1
      ),
      url = "https://example.test/owner/repo/issues/101",
    },
    {
      number = 102,
      title = "Second child",
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        2
      ),
      url = "https://example.test/owner/repo/issues/102",
    },
  }
end

local function child_issue_list_stdout(issues)
  local rows = {}
  for _, issue in ipairs(issues or {}) do
    table.insert(rows, "{"
      .. '"number":' .. github_view.json_value(issue.number)
      .. ',"title":' .. github_view.json_value(issue.title)
      .. ',"state":' .. github_view.json_value(issue.state)
      .. ',"author":{"login":' .. github_view.json_value(issue.author_login) .. "}"
      .. ',"body":' .. github_view.json_value(issue.body)
      .. ',"url":' .. github_view.json_value(issue.url)
      .. "}")
  end
  return "[" .. table.concat(rows, ",") .. "]\n"
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

local function mock_census(comments, state, state_name)
  local terminal_state = state_name or "declined"
  local empty = { stdout = "[]\n", stderr = "", exit_code = 0 }
  t.mock_command(core.gh_issue_list_observe_cmd(repo, core._enabled_label, 1, true), empty)
  t.mock_command(core.gh_issue_list_observe_cmd(repo, core._hold_label, 1, true), empty)
  for _, state_name in ipairs(core.lifecycle_state_order()) do
    if state_name == terminal_state then
      entity_read_mocks.mock_issue_list_command(
        t,
        core.gh_issue_list_observe_cmd(repo, core.state_label(state_name), 1, true),
        {
          {
            number = issue_number,
            state = state or "OPEN",
            labels = { core.state_label(terminal_state) },
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
    title = "Terminal proposal",
    body = "Proposal body",
    state = state or "OPEN",
    labels = { core.state_label(terminal_state) },
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
    reconcile_output_obligation = output_obligation_resolution.reconcile,
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
  output_obligation_resolution.reconcile = function() return nil end

  local ok, result = pcall(fn)
  core.collect_recent_merged_prs = originals.collect_recent_merged_prs
  core.collect_recent_merged_issues = originals.collect_recent_merged_issues
  core.reap_orphan_prs = originals.reap_orphan_prs
  core.observe_conflict_hotspots = originals.observe_conflict_hotspots
  core.render_observability_dashboard = originals.render_observability_dashboard
  core.publish_observability_dashboard = originals.publish_observability_dashboard
  core.observability_topology_mermaid = originals.observability_topology_mermaid
  queue_starvation.observe_queue_starvation = originals.observe_queue_starvation
  output_obligation_resolution.reconcile = originals.reconcile_output_obligation
  if not ok then error(result, 0) end
  return result
end

local function fake_department(comments, state, state_name, delegated)
  local terminal_state = state_name or "declined"
  local model = github_fake.model({
    issues = {
      [source_ref.ref] = {
        repo = repo,
        number = issue_number,
        state = state or "OPEN",
        title = "Terminal proposal",
        body = "Proposal body",
        comments = comments,
        labels = { core.state_label(terminal_state) },
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
      kind = "issue",
      ref = ref.ref,
      force_fresh = opts and opts.force_fresh,
    })
    return read_issue(ref, opts)
  end
  if type(delegated) == "table" then
    github.pr_cli_view = function(read_repo, read_pr_number, fields, timeout)
      table.insert(reads, {
        kind = "pr",
        repo = read_repo,
        number = read_pr_number,
        fields = fields,
        timeout = timeout,
      })
      if delegated.pr_result ~= nil then
        return delegated.pr_result
      end
      return {
        stdout = entity_read_mocks.pr_view_stdout({
          repo = repo,
          number = delegated_pr_number,
          state = "OPEN",
          comments = delegated.pr_comments,
        }),
        stderr = "",
        exit_code = 0,
      }
    end
    github.issue_search = function(read_repo, query, fields, timeout)
      table.insert(reads, {
        kind = "children",
        repo = read_repo,
        query = query,
        fields = fields,
        timeout = timeout,
      })
      if delegated.children_result ~= nil then
        return delegated.children_result
      end
      return {
        stdout = child_issue_list_stdout(delegated.child_issues),
        stderr = "",
        exit_code = 0,
      }
    end
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
    t.is_true(receipt.payload.body:find("Terminal marker version: `" .. declined_terminal_version .. "`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Decline reason: `premise-refuted`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Elapsed dwell: `", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("reopening with a corrected premise or new evidence", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('proposal="' .. proposal_id .. '"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('terminal_version="' .. declined_terminal_version .. '"', 1, true) ~= nil)
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

  test_reconcile_drop_blocked_issue_emits_receipt_then_closes_not_planned_once = function()
    mock_env("1")
    local comments = reconcile_drop_comments()
    local department, model, reads = fake_department(comments, "OPEN", "blocked")

    mock_census(comments, "OPEN", "blocked")
    local first = run_tick(department)
    local receipt = receipt_raise(first)

    t.is_true(receipt ~= nil)
    t.eq(receipt.payload.issue_number, issue_number)
    t.eq(receipt.payload.source_ref.ref, source_ref.ref)
    t.is_true(receipt.payload.body:find("Terminal authority: `reconcile:v1`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Reconcile action: `drop`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Terminal cause: `no-semantic-progress`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Proposal: `" .. proposal_id .. "`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Terminal marker version: `" .. reconcile_terminal_version .. "`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Required dwell: `1440 minutes`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find(
      "Decompose check: `no trusted pr-delegation for this proposal; no decomposed:v1 for this terminal version lineage`",
      1,
      true
    ) ~= nil)
    t.is_true(receipt.payload.body:find(
      "Operator-handling check: `no non-bot comment after the reconcile terminal comment`",
      1,
      true
    ) ~= nil)
    t.is_true(receipt.payload.body:find('terminal_authority="reconcile:v1"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('action="drop"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('terminal_cause="no-semantic-progress"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('proposal="' .. proposal_id .. '"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('terminal_version="' .. reconcile_terminal_version .. '"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('dwell_minutes="1440"', 1, true) ~= nil)
    t.is_true(receipt.payload.body:find(
      'decompose_check="no-proposal-pr-delegation-or-terminal-lineage-decomposed"',
      1,
      true
    ) ~= nil)
    t.is_true(receipt.payload.body:find('operator_handling_check="no-post-terminal-human-comment"', 1, true) ~= nil)
    t.eq(#close_writes(model), 0)
    t.eq(#reads, 1)
    t.eq(reads[1].ref, source_ref.ref)
    t.eq(reads[1].force_fresh, true)

    table.insert(model.issues[source_ref.ref].comments, bot_comment(receipt.payload.body, "2000-01-02T00:00:00Z"))
    mock_census(model.issues[source_ref.ref].comments, "OPEN", "blocked")
    local second = run_tick(department)
    local closes = close_writes(model)

    t.eq(receipt_raise(second), nil)
    t.eq(#closes, 1)
    t.eq(closes[1].argv[4], tostring(issue_number))
    t.eq(closes[1].argv[6], repo)
    t.eq(closes[1].argv[7], "--reason")
    t.eq(closes[1].argv[8], "not planned")
    t.eq(#reads, 2)
    t.eq(reads[2].force_fresh, true)

    model.issues[source_ref.ref].state = "CLOSED"
    mock_census(model.issues[source_ref.ref].comments, "CLOSED", "blocked")
    local replay = run_tick(department)

    t.eq(receipt_raise(replay), nil)
    t.eq(#close_writes(model), 1)
    t.eq(#reads, 2)
  end,

  test_dwell_only_blocked_issue_remains_open = function()
    mock_env("1")
    local comments = {
      bot_comment(core.state_marker(proposal_id, "blocked", reconcile_terminal_version)),
    }
    local department, model = fake_department(comments, "OPEN", "blocked")
    mock_census(comments, "OPEN", "blocked")

    local result = run_tick(department)

    t.eq(receipt_raise(result), nil)
    t.eq(#close_writes(model), 0)
  end,

  test_pr_delegated_reconcile_drop_lineage_remains_open = function()
    mock_env("1")
    local comments = reconcile_drop_comments({
      bot_comment(
        m_builders.pr_delegation_marker(
          proposal_id,
          "github-devloop/pr/owner/repo/7",
          7,
          reconcile_impl_version,
          "g1"
        ),
        "2000-01-02T00:00:00Z"
      ),
    })
    local department, model = fake_department(comments, "OPEN", "blocked")
    mock_census(comments, "OPEN", "blocked")

    local result = run_tick(department)

    t.eq(receipt_raise(result), nil)
    t.eq(#close_writes(model), 0)
  end,

  test_decomposed_reconcile_drop_lineage_remains_open_without_child_proof = function()
    mock_env("1")
    local comments = reconcile_drop_comments({
      bot_comment(
        decompose.decomposed_marker(proposal_id, reconcile_terminal_version, 7, 1),
        "2000-01-02T00:00:00Z"
      ),
    })
    local department, model = fake_department(comments, "OPEN", "blocked")
    mock_census(comments, "OPEN", "blocked")

    local result = run_tick(department)

    t.eq(receipt_raise(result), nil)
    t.eq(#close_writes(model), 0)
  end,

  test_post_reconcile_rereview_comment_keeps_blocked_issue_open = function()
    mock_env("1")
    local comments = reconcile_drop_comments({
      {
        body = "fkst: rereview",
        author_login = "alice",
        created_at = "2000-01-02T00:00:00Z",
      },
    })
    local department, model = fake_department(comments, "OPEN", "blocked")
    mock_census(comments, "OPEN", "blocked")

    local result = run_tick(department)

    t.eq(receipt_raise(result), nil)
    t.eq(#close_writes(model), 0)
  end,

  test_delegated_fix_reconcile_proof_emits_receipt_then_closes_not_planned_once = function()
    mock_env("1")
    local comments = delegated_parent_comments()
    local delegated = {
      pr_comments = delegated_pr_comments(),
      child_issues = delegated_child_issues(),
    }
    local department, model, reads = fake_department(comments, "OPEN", "blocked", delegated)

    mock_census(comments, "OPEN", "blocked")
    local first = run_tick(department)
    local receipt = receipt_raise(first)

    t.is_true(receipt ~= nil)
    t.is_true(receipt.payload.body:find("Terminal authority: `delegated-fix-reconcile:v1`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Delegated PR: `#7`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find("Decomposition count: `2`", 1, true) ~= nil)
    t.is_true(receipt.payload.body:find('proof_digest="', 1, true) ~= nil)
    t.eq(#close_writes(model), 0)
    t.eq(#reads, 3)
    t.eq(reads[1].kind, "issue")
    t.eq(reads[1].force_fresh, true)
    t.eq(reads[2].kind, "pr")
    t.eq(reads[2].number, delegated_pr_number)
    t.eq(reads[3].kind, "children")

    table.insert(model.issues[source_ref.ref].comments, bot_comment(receipt.payload.body, "2026-07-31T00:00:00Z"))
    mock_census(model.issues[source_ref.ref].comments, "OPEN", "blocked")
    local second = run_tick(department)

    t.eq(receipt_raise(second), nil)
    t.eq(#close_writes(model), 1)
    t.eq(#reads, 6)
    t.eq(reads[4].kind, "issue")
    t.eq(reads[4].force_fresh, true)
    t.eq(reads[5].kind, "pr")
    t.eq(reads[6].kind, "children")

    model.issues[source_ref.ref].state = "CLOSED"
    mock_census(model.issues[source_ref.ref].comments, "CLOSED", "blocked")
    local replay = run_tick(department)

    t.eq(receipt_raise(replay), nil)
    t.eq(#close_writes(model), 1)
    t.eq(#reads, 6)
  end,

  test_force_fresh_delegated_proof_change_keeps_parent_open = function()
    mock_env("1")
    local comments = delegated_parent_comments()
    local delegated = {
      pr_comments = delegated_pr_comments(),
      child_issues = delegated_child_issues(),
    }
    local department, model, reads = fake_department(comments, "OPEN", "blocked", delegated)

    mock_census(comments, "OPEN", "blocked")
    local first = run_tick(department)
    local receipt = receipt_raise(first)
    t.is_true(receipt ~= nil)
    table.insert(model.issues[source_ref.ref].comments, bot_comment(receipt.payload.body, "2026-07-31T00:00:00Z"))
    table.insert(delegated.child_issues, {
      number = 103,
      title = "Duplicate first child",
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        1
      ),
      url = "https://example.test/owner/repo/issues/103",
    })

    mock_census(model.issues[source_ref.ref].comments, "OPEN", "blocked")
    local second = run_tick(department)

    t.eq(receipt_raise(second), nil)
    t.eq(#close_writes(model), 0)
    t.eq(#reads, 6)
  end,

  test_unavailable_delegated_pr_read_keeps_parent_open = function()
    mock_env("1")
    local comments = delegated_parent_comments()
    local delegated = {
      pr_result = { stdout = "", stderr = "not found", exit_code = 1 },
      child_issues = delegated_child_issues(),
    }
    local department, model, reads = fake_department(comments, "OPEN", "blocked", delegated)
    mock_census(comments, "OPEN", "blocked")

    local result = run_tick(department)

    t.eq(receipt_raise(result), nil)
    t.eq(#close_writes(model), 0)
    t.eq(#reads, 2)
    t.eq(reads[1].kind, "issue")
    t.eq(reads[2].kind, "pr")
  end,

  test_production_shaped_delegated_refusals_keep_parent_open = function()
    local human_comment = {
      body = "Do not retire this yet.",
      author_login = "alice",
      created_at = "2026-07-30T00:03:00Z",
    }
    local duplicate_children = delegated_child_issues()
    table.insert(duplicate_children, {
      number = 103,
      title = "Duplicate first child",
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(proposal_id, delegated_version, delegated_pr_number, 1),
      url = "https://example.test/owner/repo/issues/103",
    })
    local cases = {
      { pr_comments = delegated_pr_comments(nil, { pr_link = false }), child_issues = delegated_child_issues() },
      { pr_comments = delegated_pr_comments({ human_comment }), child_issues = delegated_child_issues() },
      { pr_comments = delegated_pr_comments(), child_issues = duplicate_children },
      {
        pr_comments = delegated_pr_comments(nil, {
          reconcile_marker = conv_reconcile.review_reconcile_marker(
            proposal_id,
            delegated_version,
            4,
            "drop",
            "no-semantic-progress"
          ),
        }),
        child_issues = delegated_child_issues(),
      },
      {
        pr_comments = delegated_pr_comments(nil, {
          reconcile_marker = '<!-- fkst:github-devloop:timeout-reconcile:v1 proposal="' .. proposal_id
            .. '" version="' .. delegated_version .. '" round="4" action="drop" -->',
        }),
        child_issues = delegated_child_issues(),
      },
    }

    for _, delegated in ipairs(cases) do
      mock_env("1")
      local comments = delegated_parent_comments()
      local department, model = fake_department(comments, "OPEN", "blocked", delegated)
      mock_census(comments, "OPEN", "blocked")

      local result = run_tick(department)

      t.eq(receipt_raise(result), nil)
      t.eq(#close_writes(model), 0)
    end
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
