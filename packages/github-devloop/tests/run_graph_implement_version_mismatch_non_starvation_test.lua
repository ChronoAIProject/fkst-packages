local author_policy = require("testkit_internal.github_author_policy")
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")

local core = h.core
local t = h.t

local repo = "owner/repo"
local stale_issue_number = 42
local healthy_issue_number = 43
local stale_pr_number = 7
local stale_proposal_id = base_ids.proposal_id(repo, stale_issue_number)
local healthy_proposal_id = base_ids.proposal_id(repo, healthy_issue_number)
local stale_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local healthy_version = "ready/consensus-github-devloop/issue/owner/repo/43/2026-06-03T01-03-03Z"
local stale_branch = devloop_base.implement_branch(repo, stale_issue_number, stale_version)
local healthy_branch = devloop_base.implement_branch(repo, healthy_issue_number, healthy_version)
local stale_head_sha = "0123456789abcdef0123456789abcdef01234567"
local stale_base_sha = "1111111111111111111111111111111111111111"
local runtime_root = "/tmp/fkst-packages-test/github-devloop-run-graph-version-mismatch/runtime"

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function issue_source_ref(issue_number)
  return entity_lib.issue_source_ref(repo, issue_number)
end

local function initial_event()
  return {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#liveness/implement-version-mismatch",
    },
  }
end

local function mock_env(name, value, times)
  for _ = 1, times or 1 do
    t.mock_command(devloop_base.read_env_command(name), {
      stdout = value or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_runtime_and_config(write_mode)
  author_policy.mock_env(t, nil, { times = 64 })
  mock_env("FKST_GITHUB_REPO", repo, 16)
  mock_env("FKST_GITHUB_WRITE", write_mode, 64)
  mock_env("FKST_GITHUB_CLAIM_MODE", "", 32)
  mock_env("FKST_DEVLOOP_UPSTREAM_BRANCH", "dev", 32)
  mock_env("FKST_DEVLOOP_INTEGRATION_BRANCH", "", 32)
  mock_env("FKST_DEVLOOP_ROLLUP_MERGE", "", 16)
  mock_env("FKST_DEVLOOP_MAX_INFLIGHT", "", 16)
  for _ = 1, 32 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = runtime_root,
      stderr = "",
      exit_code = 0,
    })
  end
end

local function issue_list_json()
  return '[{"number":42,"state":"open","updated_at":"2026-06-03T02:05:04Z"},'
    .. '{"number":43,"state":"open","updated_at":"2026-06-03T02:05:05Z"}]\n'
end

local function empty_blocked_by_json()
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,'
    .. '"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n'
end

local function stale_issue_comments()
  local child_pr = entity_lib.pr_proposal_id(repo, stale_pr_number)
  local diverged_version = core.implementation_attempt_version(stale_version, 2)
  return {
    trusted_comment(core.state_marker(stale_proposal_id, "implementing", stale_version)),
    trusted_comment(core.implement_attempt_marker(
      stale_proposal_id,
      stale_version,
      2,
      tostring(now() - 60),
      core.implement_exec_ref(stale_proposal_id, stale_version)
    )),
    trusted_comment(m_builders.implementing_marker(
      stale_proposal_id,
      stale_version,
      stale_branch,
      stale_head_sha,
      "integration-elonsg",
      stale_base_sha
    )),
    trusted_comment(m_builders.pr_delegation_marker(
      stale_proposal_id,
      child_pr,
      stale_pr_number,
      stale_version,
      "g1"
    )),
    trusted_comment(core.implement_version_mismatch_marker(
      stale_proposal_id,
      diverged_version,
      stale_version,
      1
    )),
    trusted_comment(core.implement_version_mismatch_marker(
      stale_proposal_id,
      diverged_version,
      stale_version,
      2
    )),
    trusted_comment(core.implement_version_mismatch_marker(
      stale_proposal_id,
      diverged_version,
      stale_version,
      3
    )),
  }
end

local function healthy_issue_comments()
  return {
    trusted_comment(core.state_marker(healthy_proposal_id, "implementing", healthy_version)),
    trusted_comment(core.implement_attempt_marker(
      healthy_proposal_id,
      healthy_version,
      1,
      tostring(now() - 60),
      core.implement_exec_ref(healthy_proposal_id, healthy_version)
    )),
  }
end

local function mock_issue(number, title, labels, comments)
  local fields = {
    repo = repo,
    number = number,
    title = title,
    body = "Production-shaped run_graph regression fixture.",
    state = "OPEN",
    labels = labels,
    comments = comments,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    updated_at = "2026-06-03T02:05:04Z",
    times = 30,
    register_all_views = true,
  }
  entity_read_mocks.mock_issue_read_with_defaults(t, labels, comments, fields)
  entity_read_mocks.mock_issue_view_selector(
    t,
    fields,
    "title,body,labels,comments,state,author",
    30
  )
end

local function mock_open_child_pr()
  local fields = {
    repo = repo,
    number = stale_pr_number,
    state = "OPEN",
    base_branch = "integration-elonsg",
    head = stale_branch,
    head_sha = stale_head_sha,
    comments = {
      trusted_comment(m_builders.pr_origin_marker(
        stale_proposal_id,
        stale_issue_number,
        stale_branch,
        stale_version,
        "integration-elonsg"
      )),
      trusted_comment(core.state_marker(stale_proposal_id, "pr-open", stale_version)),
    },
    times = 8,
    register_all_views = true,
  }
  entity_read_mocks.mock_pr_read_forms(t, fields)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_origin_selector, 8)
end

local function mock_github_state(stale_comments, healthy_comments)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = issue_list_json(),
    stderr = "",
    exit_code = 0,
  })
  mock_issue(stale_issue_number, "Merged implementation awaiting rollup", {
    "fkst-dev:enabled",
    "fkst-dev:implementing",
  }, stale_comments)
  mock_issue(healthy_issue_number, "Independent implementation", {
    "fkst-dev:enabled",
    "fkst-dev:implementing",
  }, healthy_comments)
  for _, issue_number in ipairs({ stale_issue_number, healthy_issue_number }) do
    t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
      stdout = empty_blocked_by_json(),
      stderr = "",
      exit_code = 0,
    })
  end
  mock_open_child_pr()
end

local function mock_stale_implementation_progress()
  t.mock_command("git fetch origin " .. stale_branch, {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/origin/" .. stale_branch .. "^{commit}", {
    stdout = stale_head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_comment_writes(number, count)
  for _ = 1, count do
    for _, command in ipairs({
      "gh api --paginate --slurp repos/" .. repo .. "/issues/" .. number .. "/comments?per_page=100",
      "gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. number .. "/comments?per_page=100'",
    }) do
      t.mock_command(command, {
        stdout = "[[]]\n",
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command("gh api --method POST repos/" .. repo .. "/issues/" .. number .. "/comments --field 'body=", {
      stdout = '{"id":123456,"body":"created","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_proxy_writes()
  for _, issue_number in ipairs({ stale_issue_number, healthy_issue_number }) do
    for _ = 1, 8 do
      t.mock_command("gh api repos/" .. repo .. "/issues/" .. issue_number, {
        stdout = '{"labels":[{"name":"fkst-dev:implementing"}],'
          .. '"assignees":[{"login":"fkst-test-bot"}],'
          .. '"user":{"login":"fkst-test-bot"}}\n',
        stderr = "",
        exit_code = 0,
      })
    end
  end
  mock_comment_writes(stale_issue_number, 2)
  mock_comment_writes(healthy_issue_number, 4)
  for _ = 1, 8 do
    t.mock_command("gh label list --repo " .. repo .. " --limit 1000 --json name", {
      stdout = '[{"name":"fkst-dev:implementing"},{"name":"fkst-dev:awaiting-pr"},'
        .. '{"name":"fkst-dev:impl-failed"}]\n',
      stderr = "",
      exit_code = 0,
    })
  end
  for _, issue_number in ipairs({ stale_issue_number, healthy_issue_number }) do
    for _ = 1, 4 do
      t.mock_command("gh issue edit " .. issue_number .. " --repo " .. repo, {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function mock_healthy_implementation()
  h.mock_context_bundle({
    proposal_id = healthy_proposal_id,
    dedup_key = healthy_version,
    source_ref = issue_source_ref(healthy_issue_number),
  })
  t.mock_command("git worktree list --porcelain", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'origin' '" .. healthy_branch .. "'", {
    stdout = "",
    stderr = "fatal: couldn't find remote ref",
    exit_code = 128,
  })
  for _ = 1, 2 do
    t.mock_command("git rev-list --count abc123..refs/heads/" .. healthy_branch, {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("git worktree add", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show " .. healthy_branch .. ":.fkst/substrate-ref", {
    stdout = "2222222222222222222222222222222222222222\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_fresh_implement_worktree({
    runtime = runtime_root,
    issue_number = healthy_issue_number,
    impl_version = healthy_version,
  })
  h.mock_implement_codex(7, "", "synthetic independent implementation failure")
  h.mock_git_status("")
end

local function find_step_raise(step, queue, fragment)
  for _, raised in ipairs(step.raises or {}) do
    if raised.queue == queue
      and tostring(raised.payload and raised.payload.body or ""):find(fragment, 1, true) ~= nil then
      return raised
    end
  end
  return nil
end

local function codex_dispatch_worktree()
  local worktree = nil
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
      count = count + 1
      worktree = tostring(call.rendered or "")
    end
  end
  return count, worktree
end

return {
  test_run_graph_replay_uses_marker_lineage_and_does_not_starve_implement = function()
    local stale_comments = stale_issue_comments()
    local healthy_comments = healthy_issue_comments()
    local persisted = core.latest_implement_attempt_fact(
      stale_comments,
      stale_proposal_id,
      stale_version
    )
    t.eq(persisted.attempt, 2)
    t.eq(persisted.dedup_key, stale_version)
    t.eq(core.implement_version_mismatch_attempt_count(
      stale_comments,
      stale_proposal_id,
      core.implementation_attempt_version(stale_version, 2),
      stale_version
    ), 3)

    mock_runtime_and_config("1")
    mock_github_state(stale_comments, healthy_comments)
    mock_stale_implementation_progress()
    mock_healthy_implementation()
    mock_proxy_writes()

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 32 }))
    local stale_redrive = graph.require_raise(trace, "github-devloop.devloop_ready", function(raised)
      return raised.payload.proposal_id == stale_proposal_id
    end)
    t.eq(stale_redrive.payload.implementation_version, stale_version)
    t.eq(stale_redrive.payload.impl_retry_attempt, nil)

    local stale_step = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
      predicate = function(step)
        return find_step_raise(
          step,
          "github-proxy.github_issue_comment_request",
          'state="awaiting-pr"'
        ) ~= nil
      end,
    })
    t.eq(stale_step.status, "accepted")
    t.eq(stale_step.exit_code, 0)
    t.eq(find_step_raise(
      stale_step,
      "github-proxy.github_issue_comment_request",
      'fkst:github-devloop:implement-version-mismatch:v1 proposal="' .. stale_proposal_id .. '"'
    ), nil)
    local successor = find_step_raise(
      stale_step,
      "github-proxy.github_issue_comment_request",
      'state="awaiting-pr"'
    )
    t.is_true(successor ~= nil)
    t.is_true(tostring(successor.payload.body):find(
      'fkst:github-devloop:pr-delegation:v1 proposal="' .. stale_proposal_id .. '"',
      1,
      true
    ) ~= nil)
    t.eq(trace.final.pending, 0)
    t.eq(trace.final.deliveries, 0)
    t.eq(trace.final.dead_letters, 0)

    local healthy_step = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
      predicate = function(step)
        return find_step_raise(
          step,
          "github-proxy.github_issue_comment_request",
          'fkst:github-devloop:implement-attempt:v1 proposal="' .. healthy_proposal_id .. '"'
        ) ~= nil
      end,
    })
    t.eq(healthy_step.status, "accepted")
    t.eq(healthy_step.exit_code, 0)

    local codex_count, codex_worktree = codex_dispatch_worktree()
    t.eq(codex_count, 1)
    t.is_true(codex_worktree:find("devloop-owner-repo-43", 1, true) ~= nil)
    t.eq(codex_worktree:find("devloop-owner-repo-42", 1, true), nil)
  end,
}
