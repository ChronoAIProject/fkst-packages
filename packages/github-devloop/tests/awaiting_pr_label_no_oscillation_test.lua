local entity_lib = require("devloop.entity")
local transition_version = require("contract.transition_version")
local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local entity_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local core = h.core
local t = h.t

local repo = "owner/repo"
local issue_number = 42
local pr_number = 7
local parent = "github-devloop/issue/owner/repo/42"
local child_pr = "github-devloop/pr/owner/repo/7"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local delegation = "g1"
local head_sha = "0123456789abcdef0123456789abcdef01234567"
local integration_branch = "integration/dev"
local original_branch = devloop_base.implement_branch(repo, issue_number, core.implementation_base_version(version))

local function comment(body, author, created_at)
  return {
    id = tostring(created_at or body):gsub("[^%w_%-]", "_"):sub(1, 60),
    body = body,
    author_login = author or core._test_bot_login,
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function parent_comments(opts)
  local options = opts or {}
  local comments = {
    comment(core.state_marker(parent, "awaiting-pr", version), core._test_bot_login, "2026-06-03T01:02:03Z"),
    comment(m_builders.pr_delegation_marker(parent, child_pr, pr_number, version, delegation), core._test_bot_login, "2026-06-03T01:03:03Z"),
  }
  if options.blocked_visible == true then
    table.insert(comments, comment(
      core.state_marker(parent, "blocked", transition_version.next_blocked(version, "child-pr-blocked")),
      core._test_bot_login,
      "2026-06-03T01:05:03Z"
    ))
  end
  return comments
end

local function child_blocked_comments()
  return {
    comment(
      m_builders.pr_origin_marker(parent, issue_number, original_branch, version, integration_branch)
        .. "\n" .. core.state_marker(parent, "blocked", version),
      core._test_bot_login,
      "2026-06-03T01:04:03Z"
    ),
  }
end

local function find_raise(raises, queue, predicate)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue and (predicate == nil or predicate(raised.payload or {}, raised)) then
      return raised
    end
  end
  return nil
end

local function raises_for(raises, queue)
  local matches = {}
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      table.insert(matches, raised)
    end
  end
  return matches
end

local function has_label(labels, label)
  for _, candidate in ipairs(labels or {}) do
    if candidate == label then
      return true
    end
  end
  return false
end

local function count_awaiting_pr_label_adds(raises)
  local count = 0
  for _, raised in ipairs(raises_for(raises, "github-proxy.github_issue_label_request")) do
    if has_label(raised.payload.add_labels, "fkst-dev:awaiting-pr") then
      count = count + 1
    end
  end
  return count
end

local function mock_env()
  h.mock_bot_env()
  h.mock_write_env("")
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_reads(issue_comments, pr_comments, opts)
  local options = opts or {}
  t.mock_command(core.gh_issue_list_decompose_children_cmd(repo, parent), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  entity_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    labels = options.labels or { "fkst-dev:enabled", "fkst-dev:awaiting-pr" },
    comments = issue_comments,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "title,body,comments,labels,state,createdAt,updatedAt,assignees,author")
  entity_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = pr_number,
    comments = pr_comments,
    head = original_branch,
    head_sha = head_sha,
    state = "OPEN",
    base_branch = integration_branch,
    labels = {},
  }, entity_mocks.pr_origin_selector, options.pr_view_times)
end

local function run_issue_observe(issue_comments, pr_comments, opts)
  local options = opts or {}
  local labels = options.labels or { "fkst-dev:enabled", "fkst-dev:awaiting-pr" }
  mock_env()
  mock_reads(issue_comments, pr_comments, options)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Implement decision recorder",
      state = "OPEN",
      updated_at = "2026-06-03T01:02:03Z",
      labels = labels,
      dedup_key = "owner/repo#issue#42@2026-06-03T01:02:03Z",
      source_ref = entity_lib.issue_source_ref(repo, issue_number),
    },
  })
end

local function run_pr_observe(issue_comments, pr_comments, opts)
  local options = opts or {}
  options.pr_view_times = options.pr_view_times or 2
  mock_env()
  mock_reads(issue_comments, pr_comments, options)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      state = "OPEN",
      updated_at = "2026-06-03T02:03:04Z",
      dedup_key = "owner/repo#pr#7@2026-06-03T02:03:04Z",
      source_ref = entity_lib.pr_source_ref(repo, pr_number),
    },
  })
end

local function assert_no_awaiting_pr_label_add(result)
  t.eq(count_awaiting_pr_label_adds(result.raises), 0)
end

local function assert_success(result, pass)
  if result.exit_code ~= 0 then
    error(tostring(pass) .. " failed: " .. tostring(result.error or result.stderr or "unknown department failure"))
  end
end

local function assert_no_parent_marker_rewrite(result)
  t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
end

local function assert_settled_blocked_stable(result, pass)
  assert_success(result, pass)
  t.eq(#raises_for(result.raises, "github-proxy.github_issue_label_request"), 0)
  assert_no_parent_marker_rewrite(result)
end

return {
  test_awaiting_pr_child_blocked_label_reconciliation_does_not_oscillate = function()
    local child_comments = child_blocked_comments()

    local first = run_issue_observe(parent_comments(), child_comments)
    assert_success(first, "pass1")
    local first_resume = find_raise(first.raises, "github-proxy.github_issue_comment_request")
    t.is_true(first_resume ~= nil)
    t.is_true(first_resume.payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(first_resume.payload.body:find("child-pr-blocked", 1, true) ~= nil)
    local first_labels = raises_for(first.raises, "github-proxy.github_issue_label_request")
    t.eq(#first_labels, 1)
    t.is_true(has_label(first_labels[1].payload.add_labels, "fkst-dev:blocked"))
    t.is_true(has_label(first_labels[1].payload.remove_labels, "fkst-dev:awaiting-pr"))
    assert_no_awaiting_pr_label_add(first)

    local second = run_issue_observe(parent_comments({ blocked_visible = true }), child_comments)
    assert_success(second, "pass2")
    assert_no_awaiting_pr_label_add(second)
    local second_label = find_raise(second.raises, "github-proxy.github_issue_label_request")
    if second_label ~= nil then
      t.is_true(has_label(second_label.payload.add_labels, "fkst-dev:blocked"))
      t.is_true(has_label(second_label.payload.remove_labels, "fkst-dev:awaiting-pr"))
    end

    local third = run_pr_observe(parent_comments({ blocked_visible = true }), child_comments)
    assert_success(third, "pass3")
    assert_no_awaiting_pr_label_add(third)
    t.eq(find_raise(third.raises, "github-proxy.github_issue_comment_request"), nil)

    local settled_labels = { "fkst-dev:enabled", "fkst-dev:blocked" }
    local issue_settled = run_issue_observe(parent_comments({ blocked_visible = true }), child_comments, {
      labels = settled_labels,
    })
    assert_settled_blocked_stable(issue_settled, "issue settled stability")

    local pr_settled = run_pr_observe(parent_comments({ blocked_visible = true }), child_comments, {
      labels = settled_labels,
    })
    assert_settled_blocked_stable(pr_settled, "pr settled stability")
  end,
}
