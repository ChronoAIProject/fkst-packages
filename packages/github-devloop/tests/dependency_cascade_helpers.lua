local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local dependency_gate = require("devloop.dependency_gate")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local m_builders = require("devloop.markers.builders")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

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

local function issue_comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function issue_view_json(labels, comments, state)
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, string.format('{"name":"%s"}', encode_json_string(label)))
  end
  return string.format(
    '{"title":"Implement dependency cascade","state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    encode_json_string(state or "OPEN"),
    table.concat(rendered_labels, ","),
    issue_comments_json(comments)
  )
end

local function observe_issue_state_json(labels, comments, state)
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, string.format('{"name":"%s"}', encode_json_string(label)))
  end
  return string.format(
    '{"state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    encode_json_string(state or "OPEN"),
    table.concat(rendered_labels, ","),
    issue_comments_json(comments)
  )
end

local function blocked_by_json(nodes)
  local rendered = {}
  local input = nodes or {}
  for _, node in ipairs(input) do
    local state_reason = node.state_reason or node.stateReason or ""
    table.insert(rendered, string.format(
      '{"number":%s,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tostring(node.number),
      encode_json_string(node.state or "OPEN"),
      encode_json_string(state_reason),
      encode_json_string(node.repo or repo)
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#input)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function mock_blocked_by(issue_number, nodes)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = blocked_by_json(nodes),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocked_by_failure(issue_number)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = "",
    stderr = "graphql failed",
    exit_code = 1,
  })
end

local function mock_blocked_by_malformed(issue_number)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = "{",
    stderr = "",
    exit_code = 0,
  })
end

-- gh succeeds but the blockedBy list is truncated (more blockers than the page
-- returns). An unseen unmet blocker must fail-closed, never read as absent.
local function mock_blocked_by_truncated(issue_number)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":51,"pageInfo":{"hasNextPage":true},"nodes":[{"number":7,"state":"CLOSED","repository":{"nameWithOwner":"' .. repo .. '"}}]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocker_issue(issue_number, state_name)
  local comments = {}
  if state_name ~= nil then
    table.insert(comments, h.state_comment(base_ids.proposal_id(repo, issue_number), state_name, "v-" .. tostring(issue_number)))
  end
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"OPEN","comments":[' .. issue_comments_json(comments) .. '],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function dependency_waiver_comment(blocker_number, waiver_version)
  return core.dependency_waiver_marker(
    proposal_id,
    waiver_version or version,
    blocker_number,
    "operator-waiver"
  )
end

local function mock_blocker_issue_failure(issue_number)
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = "",
    stderr = "issue view failed",
    exit_code = 1,
  })
end

local function mock_blocker_issue_with_pr_link(issue_number, pr_number, state_name)
  local blocker_proposal_id = base_ids.proposal_id(repo, issue_number)
  local branch = "devloop-owner-repo-" .. tostring(issue_number) .. "-01HY"
  local impl_version = "v-" .. tostring(issue_number)
  local comments = {}
  if state_name ~= nil then
    table.insert(comments, h.state_comment(blocker_proposal_id, state_name, impl_version))
  end
  table.insert(comments, m_builders.pr_link_marker(blocker_proposal_id, pr_number, branch, impl_version, "dev"))
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"OPEN","comments":[' .. issue_comments_json(comments) .. '],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
  return {
    proposal_id = blocker_proposal_id,
    branch = branch,
    impl_version = impl_version,
    base_branch = "dev",
  }
end

local function mock_blocker_pr(issue_number, pr_number, link, comments)
  local rendered_comments = comments or {
    m_builders.pr_origin_marker(link.proposal_id, issue_number, link.branch, link.impl_version, link.base_branch),
  }
  t.mock_command(core.gh_pr_view_observe_cmd(repo, pr_number), {
    stdout = '{"headRefName":"' .. encode_json_string(link.branch)
      .. '","headRefOid":"abc123","baseRefName":"' .. encode_json_string(link.base_branch)
      .. '","state":"MERGED","comments":[' .. issue_comments_json(rendered_comments) .. ']}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocker_pr_failure(pr_number)
  t.mock_command(core.gh_pr_view_observe_cmd(repo, pr_number), {
    stdout = "",
    stderr = "pr view failed",
    exit_code = 1,
  })
end

local function mock_result_issue(labels, comments)
  h.mock_issue_result(labels or { "fkst-dev:thinking" }, comments or {
    core.state_marker(proposal_id, "thinking", "2026-06-02T00-00-00Z"),
  }, {
    title = "Implement dependency cascade",
  })
end

local function mock_observe_issue(labels, comments)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 42,
    labels = labels or { "fkst-dev:enabled", "fkst-dev:ready" },
    comments = comments or {
      h.projected_state_comment(proposal_id, "ready", version),
    },
    times = 1,
  })
  t.mock_command(core.gh_issue_view_entity_cmd(repo, 42), {
    stdout = issue_view_json(labels or { "fkst-dev:enabled", "fkst-dev:ready" }, comments or {
      h.projected_state_comment(proposal_id, "ready", version),
    }),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_implement_issue(labels, comments)
  t.mock_command(core.gh_issue_view_implement_cmd(repo, 42), {
    stdout = issue_view_json(labels or { "fkst-dev:ready" }, comments or {
      h.projected_state_comment(proposal_id, "ready", h.ready().dedup_key),
    }),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_repo()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_liveness_issue_list(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      tonumber(item.number),
      encode_json_string(item.state or "open"),
      encode_json_string(item.updated_at or "")
    ))
  end
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = "[" .. table.concat(rendered, ",") .. "]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_liveness_pr_list(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      tonumber(item.number),
      encode_json_string(item.state or "open"),
      encode_json_string(item.updated_at or "")
    ))
  end
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[" .. table.concat(rendered, ",") .. "]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function reached()
  return {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal_id,
    decision = "approve",
    body = "Approved.",
    dedup_key = version,
    source_ref = source_ref(),
  }
end

local function run_result()
  return h.run_result(reached(), h.opts("dependency-result"))
end

local function run_observe()
  return h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = h.issue(),
  }, h.opts("dependency-observe"))
end

local function run_liveness_scan()
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = { schema = "github-devloop.tick.v1" },
    ts = "2026-06-03T01:32:03Z",
  }, h.opts("dependency-liveness-scan"))
end

local function run_implement()
  return h.run_department("departments/implement/main.lua", {
    queue = "devloop_ready",
    payload = h.ready(),
  }, h.opts("dependency-implement"))
end

local function find_raise(raises, queue, predicate)
  for _, item in ipairs(raises or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload)) then
      return item
    end
  end
  return nil
end

local function has_queue(raises, queue)
  return find_raise(raises, queue) ~= nil
end

local function count_queue(raises, queue)
  local count = 0
  for _, item in ipairs(raises or {}) do
    if item.queue == queue then
      count = count + 1
    end
  end
  return count
end

local function has_marker(raises, marker_text)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find(marker_text, 1, true) ~= nil
  end) ~= nil
end

local function count_calls(needle)
  return gh_argv.count_calls(t, needle)
end

local function marker_body(raises, needle)
  local raise = find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return type(payload.body) == "string" and payload.body:find(needle, 1, true) ~= nil
  end)
  return raise and raise.payload.body or nil
end

local function ready_handoff_raise(raises)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return type(payload.handoff) == "table"
      and payload.handoff.kind == "github-devloop.ready"
  end)
end

return {
  devloop_base = devloop_base,
  base_ids = base_ids,
  dependency_gate = dependency_gate,
  h = h,
  t = t,
  core = core,
  entity_read_mocks = entity_read_mocks,
  gh_argv = gh_argv,
  m_builders = m_builders,
  repo = repo,
  proposal_id = proposal_id,
  version = version,
  source_ref = source_ref,
  encode_json_string = encode_json_string,
  render_comment = render_comment,
  issue_comments_json = issue_comments_json,
  issue_view_json = issue_view_json,
  observe_issue_state_json = observe_issue_state_json,
  blocked_by_json = blocked_by_json,
  mock_blocked_by = mock_blocked_by,
  mock_blocked_by_failure = mock_blocked_by_failure,
  mock_blocked_by_malformed = mock_blocked_by_malformed,
  mock_blocked_by_truncated = mock_blocked_by_truncated,
  mock_blocker_issue = mock_blocker_issue,
  dependency_waiver_comment = dependency_waiver_comment,
  mock_blocker_issue_failure = mock_blocker_issue_failure,
  mock_blocker_issue_with_pr_link = mock_blocker_issue_with_pr_link,
  mock_blocker_pr = mock_blocker_pr,
  mock_blocker_pr_failure = mock_blocker_pr_failure,
  mock_result_issue = mock_result_issue,
  mock_observe_issue = mock_observe_issue,
  mock_implement_issue = mock_implement_issue,
  mock_repo = mock_repo,
  mock_liveness_issue_list = mock_liveness_issue_list,
  mock_liveness_pr_list = mock_liveness_pr_list,
  reached = reached,
  run_result = run_result,
  run_observe = run_observe,
  run_liveness_scan = run_liveness_scan,
  run_implement = run_implement,
  find_raise = find_raise,
  has_queue = has_queue,
  count_queue = count_queue,
  has_marker = has_marker,
  count_calls = count_calls,
  marker_body = marker_body,
  ready_handoff_raise = ready_handoff_raise,
}
