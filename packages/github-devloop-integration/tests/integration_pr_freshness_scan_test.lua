local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local command_support = require("devloop.commands.support")
local github_factory = require("devloop.github_factory")
local pr_freshness_scan_department = require("departments.pr_freshness_scan.main")

local branch = "devloop/issue/owner/repo/42/ready-1234567890"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local branch_sha = "bbbb2222"
local integration_sha = "aaaa1111"
local merge_sha = "cccc3333"
local production_bot = "production-bot"
local review_proposal = devloop_base.pr_review_proposal_id("owner/repo", 7, version, branch_sha)
local review_dedup = "consensus:" .. review_proposal .. "/review"
local pr_updated_at = "2026-06-03T02:03:04Z"
local issue_updated_at = "2026-06-03T01:02:03Z"
local unparseable_updated_at = "not-a-timestamp"

local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
    FKST_DEVLOOP_INTEGRATION_BRANCH = "integration/dev",
    FKST_DEVLOOP_ROLLUP_MERGE = "auto",
    FKST_GITHUB_WRITE = "",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end

local function mock_env(write_mode, integration, repo)
  local target_repo = repo or "owner/repo"
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = integration or "integration/dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = target_repo, stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = write_mode or "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = integration or "integration/dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "auto", stderr = "", exit_code = 0 })
end

local function run_scan(run_opts)
  return h.run_department("departments/pr_freshness_scan/main.lua", {
    queue = "devloop_branch_tick",
    payload = { schema = "github-devloop.branch-tick.v1" },
  }, run_opts or opts("pr-freshness-scan"))
end

local function encode_json_string(value)
  return h.encode_json_string(value)
end

local function render_comments(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, h.render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function mock_issue_freshness_list(updated_at)
  t.mock_command("gh api graphql", {
    stdout = string.format(
      '{"data":{"repository":{"i42":{"number":42,"updatedAt":"%s"}}}}\n',
      encode_json_string(updated_at or unparseable_updated_at)
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_list(is_draft, managed_branch, repo, extra)
  local fields = extra or {}
  t.mock_command("repos/" .. (repo or "owner/repo") .. "/pulls?state=open", {
    stdout = string.format(
      '[[{"number":7,"headRefOid":"%s","headRefName":"%s","baseRefName":"integration/dev","state":"open","draft":%s,"updated_at":"%s"}]]\n',
      branch_sha,
      encode_json_string(managed_branch or branch),
      is_draft and "true" or "false",
      encode_json_string(fields.pr_updated_at or unparseable_updated_at)
    ),
    stderr = "",
    exit_code = 0,
  })
  mock_issue_freshness_list(fields.issue_updated_at)
end

local function pr_comments(state, author_login)
  local author = author_login or core._test_bot_login
  return {
    { body = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", 42, branch, version, "integration/dev"), author_login = author },
    { body = core.state_marker("github-devloop/issue/owner/repo/42", state or "merge-ready", version), author_login = author },
    { body = m_builders.review_result_marker(review_proposal, "github-devloop/issue/owner/repo/42", "approve", review_dedup), author_login = author },
    { body = m_builders.merge_ready_marker("github-devloop/issue/owner/repo/42", 7, version, review_proposal, review_dedup, branch_sha), author_login = author },
  }
end

local function mock_pr_view(state, comments, extra)
  local fields = extra or {}
  local head_repo = fields.head_repo or "owner/repo"
  t.mock_command("gh pr view '7'", {
    stdout = string.format(
      '{"headRefName":"%s","headRefOid":"%s","baseRefName":"integration/dev","state":"%s","updatedAt":"2026-06-03T02:03:04Z","isDraft":%s,"headRepository":{"nameWithOwner":"%s"},"isCrossRepository":%s,"mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"comments":[%s]}\n',
      encode_json_string(fields.head or branch),
      encode_json_string(fields.head_sha or branch_sha),
      encode_json_string(fields.state or "OPEN"),
      fields.is_draft and "true" or "false",
      encode_json_string(head_repo),
      fields.cross_repo and "true" or "false",
      encode_json_string(fields.mergeable or "MERGEABLE"),
      encode_json_string(fields.merge_state_status or "CLEAN"),
      render_comments(comments or pr_comments(state))
    ):gsub(
      '"updatedAt":"2026%-06%-03T02:03:04Z"',
      '"updatedAt":"' .. encode_json_string(fields.updated_at or pr_updated_at) .. '"'
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view(labels, comments, owner_login, repo, extra)
  local target_repo = repo or "owner/repo"
  local fields = extra or {}
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = target_repo,
    labels = labels,
    comments = comments,
    assignees = owner_login ~= nil and { owner_login } or nil,
    author_login = owner_login,
    updated_at = fields.updated_at or issue_updated_at,
  }, "title,createdAt,updatedAt,labels,state,comments,assignees,author")
end

local function mock_issue_view_other_owned()
  entity_read_mocks.mock_issue_view_raw_selector(t, {}, "title,createdAt,updatedAt,labels,state,comments,assignees,author", {
    stdout = '{"updatedAt":"' .. issue_updated_at .. '","labels":[],"comments":[],"assignees":[{"login":"human"}],"author":{"login":"fkst-test-bot"}}\n',
  })
end

local function mock_fetch_and_heads(current_branch_sha, managed_branch)
  local target_branch = managed_branch or branch
  t.mock_command("git fetch 'origin' 'integration/dev'", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git fetch 'origin' '" .. target_branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("refs/remotes/'origin'/'integration/dev'^{commit}", { stdout = integration_sha .. "\n", stderr = "", exit_code = 0 })
  t.mock_command("refs/remotes/'origin'/'" .. target_branch .. "'^{commit}", { stdout = (current_branch_sha or branch_sha) .. "\n", stderr = "", exit_code = 0 })
end

local function mock_missing_integration_fetch()
  t.mock_command("git fetch 'origin' 'integration/dev'", {
    stdout = "",
    stderr = "fatal: couldn't find remote ref integration/dev\n",
    exit_code = 128,
  })
end

local function mock_worktree_merge(exit_code, unmerged_stdout)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-rt", stderr = "", exit_code = 0 })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git worktree add --detach", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("merge --no-ff --no-commit", { stdout = "", stderr = exit_code == 0 and "" or "conflict", exit_code = exit_code })
  if exit_code ~= 0 then
    t.mock_command("ls-files -u", { stdout = unmerged_stdout or "100644 abc 1\tcore.lua\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("git worktree remove --force", { stdout = "", stderr = "", exit_code = 0 })
end

return {
  test_overlapping_ticks_skip_second_unchanged_deep_view_through_scan_pipeline = function()
    local checkpoint_cache = {}
    local deep_views = 0
    local overlap_started = false
    local nested_result = nil
    local held_locks = {}
    local lock_waiters = {}
    local run_direct_tick
    local original_cache_get = cache_get
    local original_cache_set = cache_set
    local original_with_lock = with_lock
    local original_github = command_support.github

    local function serialized_lock(key, fn)
      if held_locks[key] then
        lock_waiters[key] = lock_waiters[key] or {}
        table.insert(lock_waiters[key], fn)
        return nil
      end

      held_locks[key] = true
      local result = table.pack(pcall(fn))
      held_locks[key] = nil
      local waiting = lock_waiters[key] or {}
      lock_waiters[key] = nil
      for _, waiter in ipairs(waiting) do
        serialized_lock(key, waiter)
      end
      if not result[1] then
        error(result[2], 0)
      end
      return table.unpack(result, 2, result.n)
    end

    local test_github = github_factory.new(function(spec)
      local argv = type(spec) == "table" and spec.argv or {}
      if argv[1] == "gh" and argv[2] == "pr" and argv[3] == "view" and argv[4] == "7" then
        deep_views = deep_views + 1
        if not overlap_started then
          overlap_started = true
          nested_result = run_direct_tick()
        end
      end
      return exec_argv(spec)
    end, exec_sync)

    run_direct_tick = function()
      local ok, err = pcall(pr_freshness_scan_department.pipeline, {
        queue = "devloop_branch_tick",
        payload = { schema = "github-devloop.branch-tick.v1" },
      })
      return { exit_code = ok and 0 or 1, error = err }
    end

    for _ = 1, 2 do
      mock_env("")
      mock_pr_list(false, nil, nil, {
        issue_updated_at = issue_updated_at,
        pr_updated_at = pr_updated_at,
      })
      mock_pr_view("fixing", {})
    end

    cache_get = function(key) return checkpoint_cache[key] end
    cache_set = function(key, value) checkpoint_cache[key] = value end
    with_lock = serialized_lock
    command_support.github = function() return test_github end
    local ok, err = pcall(function()
      local outer = run_direct_tick()
      t.eq(outer.exit_code, 0, tostring(outer.error))
      t.is_true(overlap_started)
      t.eq(nested_result and nested_result.exit_code, 0, tostring(nested_result and nested_result.error))
      t.eq(h.count_calls("repos/owner/repo/pulls?state=open"), 2)
      t.eq(deep_views, 1)
    end)
    command_support.github = original_github
    with_lock = original_with_lock
    cache_set = original_cache_set
    cache_get = original_cache_get
    if not ok then
      error(err, 0)
    end
  end,

  test_pr_freshness_poll_checkpoint_skips_only_unchanged_deep_views = function()
    local run_opts = opts("pr-freshness-poll-checkpoint")

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = issue_updated_at,
      pr_updated_at = pr_updated_at,
    })
    mock_pr_view("fixing")
    mock_issue_view({}, nil, core._test_bot_login)
    local absent_mark = run_scan(run_opts)
    t.eq(absent_mark.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 1)
    t.eq(h.count_calls("gh issue view '42'"), 1)

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = issue_updated_at,
      pr_updated_at = pr_updated_at,
    })
    local unchanged = run_scan(run_opts)
    t.eq(unchanged.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 1)
    t.eq(h.count_calls("gh issue view '42'"), 1)
    t.eq(h.count_calls("i42:issue(number:42)"), 2)

    local changed_issue_at = "2026-06-03T01:02:04Z"
    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = changed_issue_at,
      pr_updated_at = pr_updated_at,
    })
    mock_issue_view({}, nil, core._test_bot_login, nil, { updated_at = changed_issue_at })
    local changed_issue = run_scan(run_opts)
    t.eq(changed_issue.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 1)
    t.eq(h.count_calls("gh issue view '42'"), 2)

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = unparseable_updated_at,
      pr_updated_at = pr_updated_at,
    })
    mock_issue_view({}, nil, core._test_bot_login, nil, { updated_at = changed_issue_at })
    local unparsable_issue = run_scan(run_opts)
    t.eq(unparsable_issue.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 1)
    t.eq(h.count_calls("gh issue view '42'"), 3)

    local changed_pr_at = "2026-06-03T02:03:05Z"
    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = changed_issue_at,
      pr_updated_at = changed_pr_at,
    })
    mock_pr_view("fixing", nil, { updated_at = changed_pr_at })
    local changed_pr = run_scan(run_opts)
    t.eq(changed_pr.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 2)
    t.eq(h.count_calls("gh issue view '42'"), 3)

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = changed_issue_at,
      pr_updated_at = unparseable_updated_at,
    })
    mock_pr_view("fixing", nil, { updated_at = changed_pr_at })
    local unparsable_pr = run_scan(run_opts)
    t.eq(unparsable_pr.exit_code, 0)
    t.eq(h.count_calls("gh pr view '7'"), 3)
    t.eq(h.count_calls("gh issue view '42'"), 3)
    t.eq(h.count_calls("repos/owner/repo/issues?state=open"), 0)
  end,

  test_pr_freshness_poll_checkpoint_advances_only_after_processing_success = function()
    local run_opts = opts("pr-freshness-poll-checkpoint-failure")

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = issue_updated_at,
      pr_updated_at = pr_updated_at,
    })
    mock_pr_view("merge-ready")
    mock_issue_view({})
    local first = run_scan(run_opts)
    t.eq(first.exit_code, 1)
    t.eq(h.count_calls("gh pr view '7'"), 1)
    t.eq(h.count_calls("gh issue view '42'"), 1)

    mock_env("")
    mock_pr_list(false, nil, nil, {
      issue_updated_at = issue_updated_at,
      pr_updated_at = pr_updated_at,
    })
    mock_pr_view("merge-ready")
    mock_issue_view({})
    local retry = run_scan(run_opts)
    t.eq(retry.exit_code, 1)
    t.eq(h.count_calls("gh pr view '7'"), 2)
    t.eq(h.count_calls("gh issue view '42'"), 2)
  end,

  test_pr_freshness_scan_accepts_maximum_length_managed_branch = function()
    local repo = "the-omega-institute/trureturing"
    local prefix = "devloop/issue/the-omega-institute/trureturing/42/ready-"
    local managed_branch = prefix .. string.rep("x", 160 - #prefix)
    local issue_proposal = "github-devloop/issue/" .. repo .. "/42"
    local scan_review_proposal = devloop_base.pr_review_proposal_id(repo, 7, version, branch_sha)
    local scan_review_dedup = "consensus:" .. scan_review_proposal .. "/review"
    local comments = {
      { body = m_builders.pr_origin_marker(issue_proposal, 42, managed_branch, version, "integration/dev"), author_login = core._test_bot_login },
      { body = core.state_marker(issue_proposal, "merge-ready", version), author_login = core._test_bot_login },
      { body = m_builders.review_result_marker(scan_review_proposal, issue_proposal, "approve", scan_review_dedup), author_login = core._test_bot_login },
      { body = m_builders.merge_ready_marker(issue_proposal, 7, version, scan_review_proposal, scan_review_dedup, branch_sha), author_login = core._test_bot_login },
    }
    t.eq(#managed_branch, 160)

    mock_env("", nil, repo)
    mock_pr_list(false, managed_branch, repo)
    mock_pr_view("merge-ready", comments, { head = managed_branch, head_repo = repo })
    mock_issue_view({}, nil, nil, repo)
    mock_fetch_and_heads(nil, managed_branch)
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 0 })

    local result = run_scan(opts("pr-freshness-maximum-branch", { FKST_GITHUB_REPO = repo }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("git fetch"), 2)
  end,

  test_pr_freshness_approved_pr_from_production_bot_merges_and_pushes = function()
    mock_env("1")
    mock_pr_list(false)
    mock_pr_view("merge-ready", pr_comments("merge-ready", production_bot))
    mock_issue_view({}, nil, production_bot)
    mock_fetch_and_heads()
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    mock_worktree_merge(0)
    t.mock_command("commit -F", { stdout = "[detached " .. merge_sha .. "] Refresh branch\n", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = production_bot, stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = production_bot, stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
    t.mock_command("git fetch 'origin' '" .. branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. branch .. "'^{commit}", { stdout = branch_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("rev-parse HEAD", { stdout = merge_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("--force-with-lease=refs/heads/" .. branch .. ":" .. branch_sha, { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git fetch 'origin' '" .. branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. branch .. "'^{commit}", { stdout = merge_sha .. "\n", stderr = "", exit_code = 0 })

    local result = run_scan(opts("pr-freshness-real", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_BOT_LOGIN = production_bot,
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("merge --no-ff --no-commit"), 1)
    t.eq(h.count_calls("--force-with-lease=refs/heads/" .. branch .. ":" .. branch_sha), 1)
  end,

  test_pr_freshness_missing_integration_branch_holds_without_dlq = function()
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("merge-ready")
    mock_issue_view({})
    mock_missing_integration_fetch()

    local result = run_scan(opts("pr-freshness-missing-integration"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("git fetch 'origin' '" .. branch .. "'"), 0)
    t.eq(h.count_calls("merge-base --is-ancestor"), 0)
    t.eq(h.count_calls("--force-with-lease"), 0)
  end,

  test_pr_freshness_skips_arbitrating_fixing_state = function()
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("fixing", {
      m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", 42, branch, version, "integration/dev"),
      core.state_marker("github-devloop/issue/owner/repo/42", "fixing", version),
      m_builders.review_result_marker(review_proposal, "github-devloop/issue/owner/repo/42", "approve", review_dedup),
    })
    mock_issue_view({})

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("git fetch"), 0)
  end,

  test_pr_freshness_skips_stale_review_approval_for_new_head = function()
    local old_head_sha = branch_sha
    local new_head_sha = "dddd4444"
    local old_review_proposal = devloop_base.pr_review_proposal_id("owner/repo", 7, version, old_head_sha)
    local old_review_dedup = "consensus:" .. old_review_proposal .. "/review"
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("reviewing", {
      m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", 42, branch, version, "integration/dev"),
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", version .. "/fix/1"),
      m_builders.review_result_marker(old_review_proposal, "github-devloop/issue/owner/repo/42", "approve", old_review_dedup),
    }, { head_sha = new_head_sha })
    mock_issue_view({})

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("git fetch"), 0)
  end,

  test_pr_freshness_conflict_raises_sync_conflict_for_pr_branch = function()
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("merge-ready")
    mock_issue_view({})
    mock_fetch_and_heads()
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    mock_worktree_merge(1)

    local result = run_scan()
    t.eq(result.exit_code, 0)
    local raised = h.find_raise(result.raises, "devloop_sync_conflict")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.upstream_branch, "integration/dev")
    t.eq(raised.payload.integration_branch, branch)
    t.eq(raised.payload.upstream_sha, integration_sha)
    t.eq(raised.payload.integration_sha, branch_sha)
    t.eq(raised.payload.dedup_key, core.pr_freshness_dedup_key("owner/repo", branch, integration_sha))
    t.eq(core.is_supported_sync_conflict(raised.payload), true)
  end,

  test_pr_freshness_skips_other_owned_pr_before_branch_work = function()
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("merge-ready")
    mock_issue_view_other_owned()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("merge-base --is-ancestor"), 0)
    t.eq(h.count_calls("git fetch"), 0)
  end,

  test_pr_freshness_dry_run_does_not_consume_same_baseline_retry = function()
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("merge-ready")
    mock_issue_view({})
    mock_fetch_and_heads()
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    mock_worktree_merge(0)
    t.mock_command("commit -F", { stdout = "[detached " .. merge_sha .. "] Refresh branch\n", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })

    local run_opts = opts("pr-freshness-once")
    local first = run_scan(run_opts)
    t.eq(first.exit_code, 0)
    mock_env("")
    mock_pr_list(false)
    mock_pr_view("merge-ready")
    mock_issue_view({})
    mock_fetch_and_heads()
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    mock_worktree_merge(0)
    t.mock_command("commit -F", { stdout = "[detached " .. merge_sha .. "] Refresh branch\n", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
    local second = run_scan(run_opts)
    t.eq(second.exit_code, 0)
    t.eq(h.count_calls("merge --no-ff --no-commit"), 2)
  end,
}
