local entity_lib = require("devloop.entity")
local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local transition_version = require("contract.transition_version")
local payloads_builders = require("devloop.payloads.builders")
local m_mq = require("devloop.merge_queue")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local opts = h.opts
local merge_ready = h.merge_ready
local ready = h.ready
local run_merge = h.run_merge
local run_implement = h.run_implement
local mock_bot_env = h.mock_bot_env
local mock_write_env = h.mock_write_env
local mock_issue_merge = h.mock_issue_merge
local mock_issue_implement = h.mock_issue_implement
local mock_pr_merge = h.mock_pr_merge
local mock_merging_comment = h.mock_merging_comment
local mock_issue_close = h.mock_issue_close
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local merge_comments = h.merge_comments
local count_calls = h.count_calls
local find_raise = h.find_raise
local find_causal_raise = h.find_causal_raise
local render_comment = h.render_comment
local json_string = h.json_string

local function json_literal(value)
  return '"' .. json_string(value) .. '"'
end

local function branch_for_pr(pr_number)
  return "devloop-owner-repo-" .. tostring(pr_number)
end

local function run_merge_queue_tick(run_opts)
  return t.run_department("departments/merge_queue/main.lua", {
    queue = "github-devloop-pr.devloop_merge_queue_tick",
    payload = {
      schema = "github-devloop.merge-queue-tick.v1",
    },
  }, run_opts)
end

local function run_starvation_merge_queue_tick(event, run_opts)
  return t.run_department("departments/merge_queue/main.lua", {
    queue = "devloop_merge_queue_tick",
    payload = m_mq.merge_queue_starvation_tick_payload("owner/repo", "merge-ready/pr/" .. tostring(event.pr_number), {
      pr_number = event.pr_number,
      proposal_id = event.proposal_id,
      version = event.version,
      head_sha = event.reviewed_head_sha,
    }),
  }, run_opts)
end

local function mock_repo_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_config_env(times)
  for _ = 1, times or 1 do
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_write_env_many(times)
  for _ = 1, times do
    mock_write_env("1")
  end
end

local function merge_comments_with_origin(event, origin_marker)
  local comments = { origin_marker }
  for _, comment in ipairs(merge_comments(event)) do
    table.insert(comments, comment)
  end
  return comments
end

local function merge_comments_for_event(event)
  local entity = entity_lib.parse_entity_proposal_id(event.proposal_id)
  return {
    m_builders.pr_origin_marker(event.proposal_id,
      tostring(entity.issue_number),
      branch_for_pr(event.pr_number),
      event.version,
      "dev"
    ),
    core.state_marker(event.proposal_id, "merge-ready", event.version),
    m_builders.merge_ready_marker(event.proposal_id, event.pr_number, event.version, event.review_proposal_id, event.review_dedup_key, event.reviewed_head_sha),
    m_builders.review_result_marker(event.review_proposal_id, event.proposal_id, "approve", event.review_dedup_key),
  }
end

local function event_for_pr(pr_number, issue_number, version_time, head_sha)
  local version = "ready/consensus-github-devloop/issue/owner/repo/" .. tostring(issue_number) .. "/" .. tostring(version_time)
  local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(issue_number)
  local review_proposal_id = devloop_base.pr_review_proposal_id("owner/repo", pr_number, version, head_sha)
  return payloads_builders.build_devloop_merge_ready_payload(proposal_id, pr_number, version, {
    review_proposal_id = review_proposal_id,
    review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
    reviewed_head_sha = head_sha,
  }, {
    kind = "external",
    ref = "owner/repo#pr/" .. tostring(pr_number),
  })
end

local function mock_claimed_issue_for_event(event, times)
  local entity = entity_lib.parse_entity_proposal_id(event.proposal_id)
  for _ = 1, times or 1 do
    entity_read_mocks.mock_issue_view_selector(t, {
      repo = "owner/repo",
      number = entity.issue_number,
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
    }, "assignees,author,labels")
  end
end

local function mock_queue_pr(event, created_at, state, state_version, mergeable, merge_state, rollup_state, rollup_conclusion, base_sha)
  local comments = {}
  for _, comment in ipairs(merge_comments_for_event(event)) do
    table.insert(comments, {
      body = comment,
      author_login = "fkst-test-bot",
      created_at = created_at,
    })
  end
  if state ~= nil then
    table.insert(comments, {
      body = core.state_marker(event.proposal_id, state, state_version or event.version),
      author_login = "fkst-test-bot",
      created_at = created_at,
    })
  end
  entity_read_mocks.mock_pr_merge_view(t, {
    repo = "owner/repo",
    number = event.pr_number,
    comments = comments,
    head = branch_for_pr(event.pr_number),
    head_sha = event.reviewed_head_sha,
    base_sha = base_sha or "abc123",
    updated_at = created_at,
    state = "OPEN",
    mergeable = mergeable or "MERGEABLE",
    merge_state = merge_state or "CLEAN",
    status_check_rollup_json = '[{"name":"test","status":' .. json_literal(rollup_state or "COMPLETED") .. ',"conclusion":' .. json_literal(rollup_conclusion or "SUCCESS") .. '}]',
  })
end

local function mock_merge_pr_view(event, state, mergeable, merge_state, rollup_state, rollup_conclusion, base_sha)
  local comments = {}
  for _, comment in ipairs(merge_comments_for_event(event)) do
    table.insert(comments, {
      body = comment,
      author_login = "fkst-test-bot",
      created_at = "2026-06-03T01:00:00Z",
    })
  end
  entity_read_mocks.mock_pr_merge_view(t, {
    repo = "owner/repo",
    number = event.pr_number,
    comments = comments,
    head = branch_for_pr(event.pr_number),
    head_sha = event.reviewed_head_sha,
    base_sha = base_sha or "abc123",
    state = state or "OPEN",
    mergeable = mergeable or "MERGEABLE",
    merge_state = merge_state or "CLEAN",
    status_check_rollup_json = '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:04:04Z","conclusion":' .. json_literal(rollup_conclusion or "SUCCESS") .. ',"detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T02:03:04Z","status":' .. json_literal(rollup_state or "COMPLETED") .. ',"workflowName":"test"}]',
  })
end

local function mock_merged_pr_view(event)
  local entity = entity_lib.parse_entity_proposal_id(event.proposal_id)
  local comments = {
    m_builders.pr_origin_marker(event.proposal_id, entity and entity.issue_number or 42, branch_for_pr(event.pr_number), event.version, "dev"),
    core.state_marker(event.proposal_id, "merge-ready", event.version),
    m_builders.merge_ready_marker(event.proposal_id, event.pr_number, event.version, event.review_proposal_id, event.review_dedup_key, event.reviewed_head_sha),
    m_builders.review_result_marker(event.review_proposal_id, event.proposal_id, "approve", event.review_dedup_key),
  }
  table.insert(comments, core.state_marker(event.proposal_id, "merging", event.version))
  table.insert(comments, m_builders.merging_marker(event.proposal_id, event.pr_number, event.version, event.reviewed_head_sha))
  entity_read_mocks.mock_pr_merge_view(t, {
    repo = "owner/repo",
    number = event.pr_number,
    comments = comments,
    head = branch_for_pr(event.pr_number),
    head_sha = event.reviewed_head_sha,
    state = "MERGED",
    merged_at = "2026-06-03T02:05:04Z",
    status_check_rollup_json = '[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]',
  })
end

local function mock_diff_name_only(pr_number, paths)
  for _ = 1, 3 do
    t.mock_command("gh pr diff '" .. tostring(pr_number) .. "' --repo 'owner/repo' --name-only", {
      stdout = table.concat(paths or {}, "\n") .. "\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_current_base_head(base_sha)
  t.mock_command("git fetch origin dev", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/dev^{commit}'", {
    stdout = tostring(base_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_candidate_head_contains_base(event, contains)
  t.mock_command("git fetch 'origin' '" .. branch_for_pr(event.pr_number) .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git rev-parse --verify FETCH_HEAD^{commit}", {
    stdout = tostring(event.reviewed_head_sha) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git merge-base --is-ancestor", {
    stdout = "",
    stderr = "",
    exit_code = contains == false and 1 or 0,
  })
end

local function mock_merge_command(event)
  t.mock_command("gh pr comment '" .. tostring(event.pr_number) .. "' --repo 'owner/repo' --body-file", {
    stdout = "commented\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr merge '" .. tostring(event.pr_number) .. "' --repo 'owner/repo' --merge --match-head-commit '" .. tostring(event.reviewed_head_sha) .. "'", {
    stdout = "merged\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_close_for(_event)
  t.mock_command("gh issue close", {
    stdout = "closed\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_queue_list(pr_numbers)
  local items = {}
  for _, number in ipairs(pr_numbers or {}) do
    table.insert(items, string.format('{"number":%d,"state":"open","base":{"ref":"dev"},"head":{"ref":"devloop-owner-repo-%d","sha":"def%d"}}', number, number, number))
  end
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&base=dev&per_page=100'", {
    stdout = "[" .. table.concat(items, ",") .. "]\n",
    stderr = "",
    exit_code = 0,
  })
end



local function predecessor_set_for(event)
  return "pr" .. tostring(event.pr_number)
    .. "-" .. transition_version.safe_version_segment(event.proposal_id)
    .. "-" .. transition_version.safe_version_segment(event.version)
    .. "-" .. tostring(event.reviewed_head_sha)
end


return {
  entity_lib = entity_lib,
  devloop_base = devloop_base,
  base_ids = base_ids,
  h = h,
  transition_version = transition_version,
  payloads_builders = payloads_builders,
  m_mq = m_mq,
  t = t,
  core = core,
  entity_read_mocks = entity_read_mocks,
  m_builders = m_builders,
  opts = opts,
  merge_ready = merge_ready,
  ready = ready,
  run_merge = run_merge,
  run_implement = run_implement,
  mock_bot_env = mock_bot_env,
  mock_write_env = mock_write_env,
  mock_issue_merge = mock_issue_merge,
  mock_issue_implement = mock_issue_implement,
  mock_pr_merge = mock_pr_merge,
  mock_merging_comment = mock_merging_comment,
  mock_issue_close = mock_issue_close,
  mock_fresh_implement_worktree = mock_fresh_implement_worktree,
  mock_implement_codex = mock_implement_codex,
  mock_git_status = mock_git_status,
  merge_comments = merge_comments,
  count_calls = count_calls,
  find_raise = find_raise,
  find_causal_raise = find_causal_raise,
  render_comment = render_comment,
  json_string = json_string,
  json_literal = json_literal,
  branch_for_pr = branch_for_pr,
  run_merge_queue_tick = run_merge_queue_tick,
  run_starvation_merge_queue_tick = run_starvation_merge_queue_tick,
  mock_repo_env = mock_repo_env,
  mock_branch_config_env = mock_branch_config_env,
  mock_write_env_many = mock_write_env_many,
  merge_comments_with_origin = merge_comments_with_origin,
  merge_comments_for_event = merge_comments_for_event,
  event_for_pr = event_for_pr,
  mock_claimed_issue_for_event = mock_claimed_issue_for_event,
  mock_queue_pr = mock_queue_pr,
  mock_merge_pr_view = mock_merge_pr_view,
  mock_merged_pr_view = mock_merged_pr_view,
  mock_diff_name_only = mock_diff_name_only,
  mock_current_base_head = mock_current_base_head,
  mock_candidate_head_contains_base = mock_candidate_head_contains_base,
  mock_merge_command = mock_merge_command,
  mock_issue_close_for = mock_issue_close_for,
  mock_queue_list = mock_queue_list,
  predecessor_set_for = predecessor_set_for,
}
