local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local liveness_scan = require("devloop.liveness_scan")

local t = h.t
local core = h.core
local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function comment(state, marker_version, author_login, created_at, effects)
  return {
    id = "IC_" .. tostring(state) .. "_" .. tostring(marker_version),
    body = h.state_comment(proposal_id, state, marker_version, effects),
    author_login = author_login or core._test_bot_login,
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function mock_repo()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list()
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = '[{"number":42,"title":"Projection mismatch","state":"open","updated_at":"2026-06-03T01:02:03Z","author":{"login":"fkst-test-bot"}}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_empty_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue(labels, comments)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = issue_number,
    title = "Projection mismatch",
    body = "",
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
    labels = labels,
    comments = comments,
    assignees = { core._test_bot_login },
    times = 1,
  })
end

local function mock_unblocked_issue()
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function run_liveness_scan(name)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = { schema = "github-devloop.tick.v1" },
    ts = "2026-06-03T01:32:03Z",
  }, h.opts(name))
end

local has_value = require("testkit_internal.values").has_value

local function raise_queue_names(raises)
  local names = {}
  for _, raised in ipairs(raises or {}) do
    names[#names + 1] = tostring(raised.queue)
  end
  return table.concat(names, ",")
end

return {
  test_canonical_corpus_recomputation_reinjects_every_reported_mismatch_class = function()
    local cases = {
      { label_state = "thinking", marker_state = "implementing" },
      { label_state = "blocked", marker_state = "implementing" },
      { label_state = "blocked", marker_state = "thinking" },
      { label_state = "thinking", marker_state = "impl-failed" },
      { label_state = "blocked", marker_state = "impl-failed" },
      { label_state = "thinking", marker_state = "declined" },
    }

    for index, case in ipairs(cases) do
      local marker_version = version .. "/reimplement/" .. tostring(index)
      local comments = {
        comment(case.marker_state, marker_version),
        comment(case.label_state, marker_version .. "/loop/99", "mallory"),
      }
      local current = devloop_state.current_state(comments, proposal_id)
      local labels = { "fkst-dev:enabled", devloop_state.state_label(case.label_state) }

      t.eq(current.state, case.marker_state)
      t.eq(liveness_scan.liveness_scan_should_reinject_state(core, proposal_id, current, labels), true)
      local add_labels, remove_labels = devloop_state.state_label_reconcile_changes(labels, current.state)
      t.eq(add_labels[1], devloop_state.state_label(case.marker_state))
      t.is_true(has_value(remove_labels, devloop_state.state_label(case.label_state)))
    end
  end,

  test_terminal_projection_mismatch_reaches_existing_marker_guarded_projector = function()
    local labels = { "fkst-dev:enabled", "fkst-dev:thinking" }
    local comments = { comment("declined", version) }
    mock_repo()
    mock_issue_list()
    mock_issue(labels, comments)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("label-projection-terminal-scan")
    t.eq(scanned.exit_code, 0)
    local redrive = h.find_raise(scanned.raises, "devloop_observe_issue")
    t.is_true(redrive ~= nil, "scan queues=" .. raise_queue_names(scanned.raises))
    t.eq(redrive.payload.title, "Projection mismatch")
    t.eq(redrive.payload.source_ref.ref, "owner/repo#issue/42")

    mock_issue(labels, comments)
    local observed = h.run_observe(redrive.payload, h.opts("label-projection-terminal-observe"))
    t.eq(observed.exit_code, 0)
    local label = h.find_raise(observed.raises, "github-proxy.github_issue_label_request")
    t.is_true(label ~= nil, "observe queues=" .. raise_queue_names(observed.raises)
      .. " stderr=" .. tostring(observed.stderr or ""))
    t.eq(label.payload.add_labels[1], "fkst-dev:declined")
    t.is_true(has_value(label.payload.remove_labels, "fkst-dev:thinking"))
    t.eq(label.payload.require_marker_guard, true)
    t.eq(label.payload.marker_guard.expected.state, "declined")
    t.eq(label.payload.marker_guard.expected.version, version)
  end,

  test_overdue_active_projection_mismatch_reinjects_before_timeout_redrive = function()
    local labels = { "fkst-dev:enabled", "fkst-dev:thinking" }
    local comments = {
      comment("ready", version, nil, "2026-06-03T00:00:00Z", "result-marker,ready-label,devloop-ready"),
    }
    mock_repo()
    mock_issue_list()
    mock_issue(labels, comments)
    mock_unblocked_issue()
    mock_empty_pr_list()

    local result = run_liveness_scan("label-projection-overdue-ready-scan")
    t.eq(result.exit_code, 0)
    t.is_true(h.find_raise(result.raises, "devloop_observe_issue") ~= nil)
    t.eq(h.find_raise(result.raises, "devloop_ready"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,
}
