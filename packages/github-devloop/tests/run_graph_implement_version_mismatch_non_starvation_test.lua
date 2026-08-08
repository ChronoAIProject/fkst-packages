local author_policy = require("testkit_internal.github_author_policy")
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")

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

local function divergent_ready_event()
  local source_ref = issue_source_ref(stale_issue_number)
  return {
    queue = "devloop_ready",
    payload = {
      schema = "github-devloop.ready.v1",
      proposal_id = stale_proposal_id,
      dedup_key = stale_version,
      impl_retry_attempt = 2,
      source_ref = source_ref,
    },
    source_ref = {
      kind = source_ref.kind,
      reference = source_ref.ref,
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
  mock_env("FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE", "", 32)
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
      "dev",
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

local function dead_worker_issue_comments()
  return {
    trusted_comment(core.state_marker(stale_proposal_id, "implementing", stale_version)),
    trusted_comment(core.implement_attempt_marker(
      stale_proposal_id,
      stale_version,
      1,
      tostring(now() - 60),
      core.implement_exec_ref(stale_proposal_id, stale_version)
    )),
  }
end

local function divergent_issue_comments()
  local child_pr = entity_lib.pr_proposal_id(repo, stale_pr_number)
  return {
    trusted_comment(core.state_marker(stale_proposal_id, "implementing", stale_version)),
    trusted_comment(core.implement_attempt_marker(
      stale_proposal_id,
      stale_version,
      2,
      tostring(now() - 60),
      core.implement_exec_ref(stale_proposal_id, stale_version)
    )),
    trusted_comment(m_builders.pr_delegation_marker(
      stale_proposal_id,
      child_pr,
      stale_pr_number,
      stale_version,
      "g1"
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

local function mock_issue(number, title, labels, comments, times)
  local read_times = times or 30
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
    times = read_times,
    register_all_views = true,
  }
  entity_read_mocks.mock_issue_read_with_defaults(t, labels, comments, fields)
  entity_read_mocks.mock_issue_view_selector(
    t,
    fields,
    "title,body,labels,comments,state,author",
    read_times
  )
end

local function created_child_comments()
  return {
    trusted_comment(m_builders.pr_origin_marker(
      stale_proposal_id,
      stale_issue_number,
      stale_branch,
      stale_version,
      "dev"
    ) .. "\n" .. m_builders.pr_link_marker(
      stale_proposal_id,
      stale_pr_number,
      stale_branch,
      stale_version,
      "dev"
    ) .. "\n" .. core.state_marker(stale_proposal_id, "pr-open", stale_version)),
  }
end

local function mock_created_child_pr(comments)
  local fields = {
    repo = repo,
    number = stale_pr_number,
    state = "OPEN",
    base_branch = "dev",
    head = stale_branch,
    head_sha = stale_head_sha,
    comments = comments or created_child_comments(),
    times = 16,
    register_all_views = true,
  }
  entity_read_mocks.mock_pr_read_forms(t, fields)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_origin_selector, 8)
end

local function mock_github_state(stale_comments, healthy_comments, times)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = issue_list_json(),
    stderr = "",
    exit_code = 0,
  })
  mock_issue(stale_issue_number, "Merged implementation awaiting rollup", {
    "fkst-dev:enabled",
    "fkst-dev:implementing",
  }, stale_comments, times)
  mock_issue(healthy_issue_number, "Independent implementation", {
    "fkst-dev:enabled",
    "fkst-dev:implementing",
  }, healthy_comments, times)
  for _, issue_number in ipairs({ stale_issue_number, healthy_issue_number }) do
    t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
      stdout = empty_blocked_by_json(),
      stderr = "",
      exit_code = 0,
    })
  end
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

local function mock_stale_worker_recovery()
  local durable_root = "/tmp/fkst-packages-test/github-devloop/durable"
  local worktree = devloop_base.implement_worktree_path(
    devloop_base.implementation_worktree_root(durable_root),
    repo,
    stale_issue_number,
    stale_version
  )
  h.mock_context_bundle({
    proposal_id = stale_proposal_id,
    dedup_key = stale_version,
    source_ref = issue_source_ref(stale_issue_number),
  })
  t.mock_command("git fetch 'origin' 'dev'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = stale_base_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 2 do
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 1,
    })
  end
  t.mock_command("git worktree list --porcelain", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  h.mock_force_clean(worktree)
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch 'origin' '" .. stale_branch .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. stale_branch .. "'^{commit}", {
    stdout = stale_head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree add --force -B", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("reset --hard", {
    stdout = "HEAD is now at " .. stale_head_sha .. " recovered implementation\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("clean -fd", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("merge --no-edit '" .. stale_base_sha .. "'", {
    stdout = "Already up to date.\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show " .. stale_base_sha .. ":.fkst/substrate-ref", {
    stdout = "2222222222222222222222222222222222222222\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git show", {
    stdout = "2222222222222222222222222222222222222222\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_implement_codex(0, "recovered committed implementation")
  for _ = 1, 2 do
    t.mock_command("[ -d '" .. worktree .. "' ]", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD " .. stale_head_sha
        .. "\nbranch refs/heads/" .. stale_branch .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
  end
  h.mock_git_status("")
  t.mock_command("git rev-list --count " .. stale_base_sha .. "..refs/heads/" .. stale_branch, {
    stdout = "1\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-parse --verify refs/heads/" .. stale_branch, {
    stdout = stale_head_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_branch_diff_paths("packages/github-devloop/core.lua\n")
  h.mock_result_checkpoint(stale_head_sha, stale_branch)
  h.mock_git_push(stale_branch)
end

local function mock_stale_pr_creation()
  local list_command = core.gh_pr_list_head_base_cmd(repo, stale_branch, "dev")
  t.mock_command(list_command, {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr create", {
    stdout = "https://github.example/owner/repo/pull/" .. tostring(stale_pr_number) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(list_command, {
    stdout = '[[{"number":' .. tostring(stale_pr_number)
      .. ',"head":{"ref":"' .. stale_branch .. '","sha":"' .. stale_head_sha
      .. '"},"base":{"ref":"dev"},"state":"open"}]]\n',
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
  mock_comment_writes(stale_issue_number, 10)
  mock_comment_writes(healthy_issue_number, 4)
  mock_comment_writes(stale_pr_number, 4)
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

local function codex_dispatch_worktrees()
  local worktrees = {}
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
      count = count + 1
      table.insert(worktrees, tostring(call.rendered or ""))
    end
  end
  return count, table.concat(worktrees, "\n")
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
    mock_created_child_pr(created_child_comments())
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
        return find_step_raise(step, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"') ~= nil
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
    t.eq(trace.final.pending, 0)
    t.eq(trace.final.deliveries, 0)
    t.eq(trace.final.dead_letters, 0)

    local codex_count, codex_worktree = codex_dispatch_worktrees()
    t.eq(codex_count, 1)
    t.is_true(codex_worktree:find("devloop-owner-repo-43", 1, true) ~= nil)
    t.eq(codex_worktree:find("devloop-owner-repo-42", 1, true), nil)
  end,

  test_run_graph_dead_worker_replay_recovers_committed_progress_to_awaiting_pr = function()
    local stale_comments = dead_worker_issue_comments()
    local healthy_comments = healthy_issue_comments()
    local persisted = core.latest_implement_attempt_fact(
      stale_comments,
      stale_proposal_id,
      stale_version
    )
    t.eq(persisted.attempt, 1)
    t.eq(persisted.dedup_key, stale_version)
    t.eq(m_facts.implementing_fact(stale_comments, stale_proposal_id, stale_version), nil)
    t.eq(m_facts.pr_delegation_fact(stale_comments, stale_proposal_id, stale_version), nil)

    mock_runtime_and_config("1")
    mock_github_state(stale_comments, healthy_comments, 3)
    mock_stale_implementation_progress()
    mock_stale_worker_recovery()
    mock_stale_pr_creation()
    mock_created_child_pr(created_child_comments())
    mock_healthy_implementation()
    mock_proxy_writes()

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 48 }))
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
          'fkst:github-devloop:implementing:v1 proposal="' .. stale_proposal_id .. '"'
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
    local published = find_step_raise(
      stale_step,
      "github-proxy.github_issue_comment_request",
      'fkst:github-devloop:implementing:v1 proposal="' .. stale_proposal_id .. '"'
    )
    local delegation = find_step_raise(
      stale_step,
      "github-proxy.github_issue_comment_request",
      'fkst:github-devloop:pr-delegation:v1 proposal="' .. stale_proposal_id .. '"'
    )
    local child_start = find_step_raise(
      stale_step,
      "github-proxy.github_pr_comment_request",
      'state="pr-open"'
    )
    t.is_true(published ~= nil)
    t.is_true(delegation ~= nil)
    t.is_true(child_start ~= nil)
    t.eq(find_step_raise(stale_step, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"'), nil)
    t.eq(h.count_calls("gh pr create"), 1)
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

    local codex_count, codex_worktree = codex_dispatch_worktrees()
    t.eq(codex_count, 2)
    t.is_true(codex_worktree:find("devloop-owner-repo-42", 1, true) ~= nil)
    t.is_true(codex_worktree:find("devloop-owner-repo-43", 1, true) ~= nil)

    local recovered_comments = dead_worker_issue_comments()
    table.insert(recovered_comments, trusted_comment(published.payload.body, "2026-06-03T02:10:00Z"))
    table.insert(recovered_comments, trusted_comment(delegation.payload.body, "2026-06-03T02:10:01Z"))
    mock_issue(stale_issue_number, "Recovered implementation", {
      "fkst-dev:enabled",
      "fkst-dev:implementing",
    }, recovered_comments, 4)
    mock_stale_implementation_progress()

    local recovery_trace = graph.require_quiescent(graph.run({
      queue = "devloop_ready",
      payload = stale_redrive.payload,
      source_ref = {
        kind = "external",
        reference = issue_source_ref(stale_issue_number).ref,
      },
    }, { max_steps = 16 }))
    local recovery_step = graph.require_delivery(recovery_trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
      predicate = function(step)
        return find_step_raise(step, "github-proxy.github_issue_comment_request", 'state="awaiting-pr"') ~= nil
      end,
    })
    local successor = find_step_raise(
      recovery_step,
      "github-proxy.github_issue_comment_request",
      'state="awaiting-pr"'
    )
    t.is_true(successor ~= nil)
    t.is_true(tostring(successor.payload.body):find(
      'fkst:github-devloop:pr-delegation:v1 proposal="' .. stale_proposal_id .. '"',
      1,
      true
    ) ~= nil)
    t.eq(find_step_raise(recovery_step, "github-proxy.github_issue_comment_request", 'state="impl-failed"'), nil)
    t.eq(find_step_raise(recovery_step, "github-proxy.github_issue_comment_request", 'state="blocked"'), nil)
    t.eq(h.count_calls("gh pr create"), 1)
    local recovered_codex_count = codex_dispatch_worktrees()
    t.eq(recovered_codex_count, 2)
  end,

  test_run_graph_divergent_delivery_remains_nonfatal = function()
    local stale_comments = divergent_issue_comments()

    mock_runtime_and_config("")
    mock_issue(stale_issue_number, "Divergent implementation delivery", {
      "fkst-dev:enabled",
      "fkst-dev:implementing",
    }, stale_comments)

    local stale_trace = graph.require_quiescent(graph.run(divergent_ready_event(), { max_steps = 4 }))
    local stale_step = graph.require_delivery(stale_trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
      predicate = function(step)
        return find_step_raise(
          step,
          "github-proxy.github_issue_comment_request",
          'fkst:github-devloop:implement-version-mismatch:v1 proposal="' .. stale_proposal_id .. '"'
        ) ~= nil
      end,
    })
    t.eq(stale_step.status, "accepted")
    t.eq(stale_step.exit_code, 0)
    local mismatch = find_step_raise(
      stale_step,
      "github-proxy.github_issue_comment_request",
      'fkst:github-devloop:implement-version-mismatch:v1 proposal="' .. stale_proposal_id .. '"'
    )
    t.eq(core.implement_version_mismatch_attempt_count(
      { mismatch.payload.body },
      stale_proposal_id,
      core.implementation_attempt_version(stale_version, 2),
      stale_version
    ), 1)
    t.eq(stale_trace.final.pending, 0)
    t.eq(stale_trace.final.deliveries, 0)
    t.eq(stale_trace.final.dead_letters, 0)
  end,
}
