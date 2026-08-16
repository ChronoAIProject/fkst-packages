local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local repo = "owner/repo"
local dependent_number = 42
local dependent_proposal_id = base_ids.proposal_id(repo, dependent_number)
local dependent_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function encode_json_string(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function render_comment(body)
  return string.format(
    '{"body":"%s","author":{"login":"fkst-test-bot"},"createdAt":"2026-06-03T01:00:00Z"}',
    encode_json_string(body or "")
  )
end

local function comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function blocked_by_json(nodes)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tonumber(node.number),
      encode_json_string(node.state or "OPEN"),
      encode_json_string(node.state_reason or ""),
      repo
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#rendered)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function issue_view_json(labels, comments)
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, string.format('{"name":"%s"}', encode_json_string(label)))
  end
  return '{"title":"Monotone dependency release","state":"OPEN","labels":['
    .. table.concat(rendered_labels, ",")
    .. '],"comments":['
    .. comments_json(comments)
    .. '],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n'
end

local function mock_blocked_by(nodes)
  t.mock_command(core.gh_blocked_by_cmd(repo, dependent_number), {
    stdout = blocked_by_json(nodes),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocker_issue(issue_number, comments)
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"CLOSED","stateReason":"COMPLETED","comments":['
      .. comments_json(comments)
      .. '],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function find_raise(raises, queue, predicate)
  for _, item in ipairs(raises or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload)) then
      return item
    end
  end
  return nil
end

return {
  test_regressed_current_cursors_do_not_hide_trusted_merged_milestones = function()
    local labels = { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }
    local dependent_comments = {
      h.projected_state_comment(dependent_proposal_id, "dependency_wait", dependent_version),
      core.dependency_wait_marker(dependent_proposal_id, dependent_version, { 51, 52 }),
    }
    entity_read_mocks.mock_issue_read_forms(t, {
      repo = repo,
      number = dependent_number,
      labels = labels,
      comments = dependent_comments,
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      times = 1,
    })
    t.mock_command(core.gh_issue_view_entity_cmd(repo, dependent_number), {
      stdout = issue_view_json(labels, dependent_comments),
      stderr = "",
      exit_code = 0,
    })
    mock_blocked_by({
      { number = 51, state = "CLOSED", state_reason = "COMPLETED" },
      { number = 52, state = "CLOSED", state_reason = "COMPLETED" },
    })

    local issue_blocker_id = base_ids.proposal_id(repo, 51)
    mock_blocker_issue(51, {
      core.state_marker(issue_blocker_id, "merged", "v-1"),
      h.projected_state_comment(issue_blocker_id, "ready", "v-2"),
    })

    local pr_blocker_id = base_ids.proposal_id(repo, 52)
    local link = {
      proposal_id = pr_blocker_id,
      pr_number = 53,
      branch = "devloop-owner-repo-52-01HY",
      impl_version = "v-52",
      base_branch = "dev",
    }
    mock_blocker_issue(52, {
      core.state_marker(pr_blocker_id, "pr-open", link.impl_version),
      m_builders.pr_link_marker(
        link.proposal_id,
        link.pr_number,
        link.branch,
        link.impl_version,
        link.base_branch
      ),
    })
    t.mock_command(core.gh_pr_view_observe_cmd(repo, link.pr_number), {
      stdout = '{"headRefName":"' .. link.branch
        .. '","headRefOid":"def456","baseRefName":"' .. link.base_branch
        .. '","state":"MERGED","comments":['
        .. comments_json({
          m_builders.pr_origin_marker(
            link.proposal_id,
            52,
            link.branch,
            link.impl_version,
            link.base_branch
          ),
          core.state_marker(link.proposal_id, "merged", "v-1"),
          m_builders.merged_marker(link.proposal_id, link.pr_number, "v-1", "def456"),
          core.state_marker(link.proposal_id, "fixing", "v-2"),
        })
        .. ']}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = h.run_department("departments/observe_issue/main.lua", {
      queue = "github-proxy.github_entity_changed",
      payload = h.issue(),
    }, h.opts("dependency-monotone-merged"))

    t.eq(result.exit_code, 0)
    t.is_true(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:dependency-release:v1", 1, true) ~= nil
    end) ~= nil)
    t.is_true(find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return type(payload.handoff) == "table" and payload.handoff.kind == "github-devloop.ready"
    end) ~= nil)
  end,
}
