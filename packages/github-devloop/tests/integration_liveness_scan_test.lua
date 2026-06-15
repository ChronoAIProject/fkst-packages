local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local reviewing = h.reviewing
local mock_issue_state = h.mock_issue_state
local run_observe = h.run_observe
local run_observe_pr = h.run_observe_pr
local find_raise = h.find_raise
local render_comment = h.render_comment
local json_string = h.json_string
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function run_liveness_scan(name)
  return t.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    ts = "2026-06-03T01:32:03Z",
  }, opts(name or "liveness-scan"))
end

local function run_liveness_scan_at(name, ts, run_opts)
  return t.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    ts = ts,
  }, run_opts or opts(name or "liveness-scan"))
end

local function mock_repo()
  t.mock_command(core.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function numbered_list_json(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      tonumber(item.number),
      json_string(item.state or "open"),
      json_string(item.updated_at or "")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function mock_issue_list(items)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = numbered_list_json(items),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_state_number(issue_number, labels, state, comments)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    title = "Issue " .. tostring(issue_number),
    body = "",
    state = state or "OPEN",
    labels = labels,
    comments = comments,
    assignees = { "fkst-test-bot" },
  }, "title,body,comments,labels,state,updatedAt,assignees")
end

local function mock_numbered_terminal_issue_states(items)
  for _, item in ipairs(items or {}) do
    local number = tonumber(item.number)
    mock_issue_state_number(number, { "fkst-dev:enabled", "fkst-dev:merged" }, "OPEN", {
      core.state_marker(core.proposal_id(repo, number), "merged", "v-" .. tostring(number)),
    })
  end
end

local function mock_empty_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_list(items)
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = numbered_list_json(items),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_state(comments, state)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  t.mock_command(core.gh_pr_view_entity_cmd(repo, 7), {
    stdout = string.format(
      '{"headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"%s","updatedAt":"2026-06-04T01:02:03Z","comments":[%s]}\n',
      json_string(state or "OPEN"),
      table.concat(rendered, ",")
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_linked_pr_state(comments, state, exit_code, times)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  local stderr = ""
  if exit_code ~= nil and exit_code ~= 0 then
    stderr = "pr view failed"
  end
  entity_read_mocks.mock_pr_view_raw_selector(t, { repo = repo, number = 7 }, entity_read_mocks.pr_origin_selector, {
    stdout = string.format(
      '{"headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"%s","updatedAt":"2026-06-04T01:02:03Z","comments":[%s]}\n',
      json_string(state or "OPEN"),
      table.concat(rendered, ",")
    ),
    stderr = stderr,
    exit_code = exit_code or 0,
  }, times or 1)
end

local function assert_no_entity_change(result)
  t.eq(result.exit_code, 0)
  t.eq(find_raise(result.raises, "github-proxy.github_entity_changed"), nil)
end

return {
  test_liveness_scan_requeues_pr_open_issue_and_observe_replays_reviewing = function()
    local ready_payload = reviewing()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:pr-open" }, "OPEN", {
      core.state_marker(proposal_id, "pr-open", version),
      core.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", version, "dev"),
    })
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-pr-open")
    t.eq(scanned.exit_code, 0)
    local raised = find_raise(scanned.raises, "github-proxy.github_entity_changed")
    t.is_true(raised ~= nil)
    t.eq(raised.payload.type, "issue")
    t.eq(raised.payload.repo, repo)
    t.eq(raised.payload.number, 42)
    t.eq(raised.payload.updated_at, "2026-06-03T01:02:03Z")
    t.eq(raised.payload.source, "liveness-scan")
    t.eq(raised.payload.source_ref.ref, "owner/repo#issue/42")
    t.is_true(tostring(raised.payload.dedup_key):find("liveness%-scan", 1) ~= nil)

    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:pr-open" }, "OPEN", {
      core.state_marker(proposal_id, "pr-open", version),
      core.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", version, "dev"),
    })
    mock_linked_pr_state({}, nil, nil, 2)
    local observed = run_observe(issue({
      dedup_key = raised.payload.dedup_key,
      source = raised.payload.source,
      source_ref = raised.payload.source_ref,
    }), opts("liveness-scan-observe-pr-open"))
    t.eq(observed.exit_code, 0)
    local reviewing_raise = find_raise(observed.raises, "devloop_reviewing")
    t.is_true(reviewing_raise ~= nil)
    t.eq(reviewing_raise.payload.proposal_id, ready_payload.proposal_id)
    t.eq(reviewing_raise.payload.pr_number, ready_payload.pr_number)
    t.eq(reviewing_raise.payload.version, version .. "/review-loop/1")
  end,

  test_liveness_scan_skips_terminal_issue = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:merged" }, "OPEN", {
      core.state_marker(proposal_id, "merged", version),
    })
    mock_empty_pr_list()

    assert_no_entity_change(run_liveness_scan("liveness-scan-terminal"))
  end,

  test_liveness_scan_skips_issue_without_state = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})
    mock_empty_pr_list()

    assert_no_entity_change(run_liveness_scan("liveness-scan-no-state"))
  end,

  test_liveness_scan_requeues_ready_dependency_hold = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }, "OPEN", {
      core.state_marker(proposal_id, "ready", version),
      core.dependency_wait_marker(proposal_id, version, { 7 }),
    })
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-ready-dependency-hold")
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, "github-proxy.github_entity_changed")
    t.is_true(raised ~= nil)
    t.eq(raised.payload.type, "issue")
    t.eq(raised.payload.source, "liveness-scan")
    t.is_true(tostring(raised.payload.dedup_key):find("liveness%-scan", 1) ~= nil)
  end,

  test_liveness_scan_requeues_open_pr_with_non_terminal_state = function()
    local event = reviewing()
    mock_repo()
    mock_issue_list({})
    mock_pr_list({ { number = 7, state = "open", updated_at = "2026-06-04T01:02:03Z" } })
    mock_pr_state({
      core.pr_origin_marker(event.proposal_id, 42, "devloop-owner-repo-42-01HY", event.version, "dev"),
      core.state_marker(event.proposal_id, "reviewing", event.version),
    }, "OPEN")
    t.mock_command(core.gh_issue_view_claim_cmd(repo, 42), {
      stdout = '{"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_liveness_scan("liveness-scan-pr-reviewing")
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, "github-proxy.github_entity_changed")
    t.is_true(raised ~= nil)
    t.eq(raised.payload.type, "pr")
    t.eq(raised.payload.repo, repo)
    t.eq(raised.payload.number, 7)
    t.eq(raised.payload.source_ref.ref, "owner/repo#pr/7")
    t.is_true(tostring(raised.payload.dedup_key):find("liveness%-scan", 1) ~= nil)

    mock_pr_state({
      core.pr_origin_marker(event.proposal_id, 42, "devloop-owner-repo-42-01HY", event.version, "dev"),
      core.state_marker(event.proposal_id, "reviewing", event.version),
    }, "OPEN")
    local observed = run_observe_pr({
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = 7,
      updated_at = raised.payload.updated_at,
      dedup_key = raised.payload.dedup_key,
      source = raised.payload.source,
      source_ref = raised.payload.source_ref,
    }, opts("liveness-scan-observe-pr-reviewing"))
    t.eq(observed.exit_code, 0)
    local reviewing_raise = find_raise(observed.raises, "devloop_reviewing")
    t.is_true(reviewing_raise ~= nil)
    t.eq(reviewing_raise.payload.version, event.version .. "/review-loop/1")
  end,

  test_liveness_scan_skips_other_owned_pr_before_reinjecting = function()
    local event = reviewing()
    mock_repo()
    mock_issue_list({})
    mock_pr_list({ { number = 7, state = "open", updated_at = "2026-06-04T01:02:03Z" } })
    mock_pr_state({
      core.pr_origin_marker(event.proposal_id, 42, "devloop-owner-repo-42-01HY", event.version, "dev"),
      core.state_marker(event.proposal_id, "reviewing", event.version),
    }, "OPEN")
    t.mock_command(core.gh_issue_view_claim_cmd(repo, 42), {
      stdout = '{"assignees":[{"login":"human"}],"author":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })

    assert_no_entity_change(run_liveness_scan("liveness-scan-pr-other-owned"))
  end,

  test_liveness_scan_caps_before_fresh_entity_views = function()
    local items = {}
    for number = 1, 101 do
      table.insert(items, { number = number, state = "open", updated_at = "2026-06-03T01:02:03Z" })
    end
    mock_repo()
    mock_issue_list(items)
    mock_empty_pr_list()
    mock_numbered_terminal_issue_states(items)

    local result = run_liveness_scan("liveness-scan-cap-before-views")
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_entity_changed"), nil)
  end,

  test_liveness_scan_defers_slow_issue_view_without_retry_failure = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_empty_pr_list()
    t.mock_command(core.gh_issue_view_entity_cmd(repo, 42), {
      stdout = "",
      stderr = "timed out",
      exit_code = 124,
    })

    local result = run_liveness_scan("liveness-scan-view-timeout-deferred")
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_entity_changed"), nil)
  end,
}
