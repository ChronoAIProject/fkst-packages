local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local head_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local head_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_WRITE = "",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end

local function mock_env(write_mode)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git rev-parse --abbrev-ref HEAD", { stdout = "dev\n", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = write_mode or "", stderr = "", exit_code = 0 })
end

local function run_scan(run_opts)
  return t.run_department("departments/release_scan/main.lua", {
    queue = "devloop_release_tick",
    payload = { schema = "github-devloop.release-tick.v1" },
  }, run_opts or opts("release-scan"))
end

local function release_reached(tag, head_sha, body, source_repo)
  local repo = source_repo or "owner/repo"
  return {
    schema = "consensus.consensus_reached.v1",
    proposal_id = core.release_proposal_id(repo, tag, head_sha),
    decision = "approve",
    body = body or "minimal:\napprove\n",
    dedup_key = "consensus:" .. core.release_dedup_key(repo, tag, head_sha),
    source_ref = core.release_source_ref(repo),
  }
end

local function run_publish(payload, run_opts)
  return t.run_department("departments/release_publish/main.lua", {
    queue = "consensus.consensus_reached",
    payload = payload,
  }, run_opts or opts("release-publish"))
end

local function mock_fetch_dev()
  t.mock_command("git fetch 'origin' 'dev'", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_dev_head(head)
  t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = tostring(head or head_a) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_latest_tag(tag)
  if tag == nil then
    t.mock_command("git describe --tags --match 'v*' --abbrev=0 refs/remotes/origin/'dev'", {
      stdout = "",
      stderr = "fatal: No names found",
      exit_code = 128,
    })
    return
  end
  t.mock_command("git describe --tags --match 'v*' --abbrev=0 refs/remotes/origin/'dev'", {
    stdout = tostring(tag) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_latest_tag_failure(stderr)
  t.mock_command("git describe --tags --match 'v*' --abbrev=0 refs/remotes/origin/'dev'", {
    stdout = "",
    stderr = stderr or "fatal: bad object refs/remotes/origin/dev",
    exit_code = 128,
  })
end

local function mock_delta(base_ref, head_sha, count)
  t.mock_command("git rev-list --count '" .. tostring(base_ref) .. ".." .. tostring(head_sha) .. "'", {
    stdout = tostring(count) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_first_release_delta(head_sha, count)
  t.mock_command("git rev-list --count '" .. tostring(head_sha) .. "'", {
    stdout = tostring(count) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function marker_issue(tag, head_sha, status)
  local dedup = core.release_dedup_key("owner/repo", tag, head_sha)
  return '[{"author":{"login":"fkst-test-bot"},"body":'
    .. '"' .. h.json_string(core.release_marker("owner/repo", tag, head_sha, status or "pending", dedup)) .. '"'
    .. ',"comments":[]}]\n'
end

local function mock_marker_list(stdout)
  t.mock_command("gh issue list --repo 'owner/repo' --state all --search 'fkst:github-devloop:release:v1' --limit 1000 --json author,body,comments", {
    stdout = stdout or "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_release_result_validator_accepts_compact_release_ids = function()
    local payload = release_reached("v0.2.0", head_a)
    local repo_segment, base_ref, tag, parsed_head = core.parse_release_proposal_id(payload.proposal_id)
    t.eq(repo_segment, core.safe_pr_review_repo_segment("owner/repo"))
    t.eq(base_ref, "v0.1.0")
    t.eq(tag, "v0.2.0")
    t.eq(parsed_head, head_a)
    t.eq(core.is_supported_release_result(payload), true)
  end,

  test_release_scan_no_tag_baseline_raises_v0_1_0 = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    mock_latest_tag(nil)
    mock_first_release_delta(head_a, 3)
    mock_marker_list("[]\n")

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local proposal = h.find_raise(result.raises, "consensus.proposal").payload
    t.eq(proposal.proposal_id, core.release_proposal_id("owner/repo", "v0.1.0", head_a))
    t.eq(proposal.dedup_key, core.release_dedup_key("owner/repo", "v0.1.0", head_a))
    t.eq(proposal.source_ref.ref, "owner/repo#repo")
    t.is_true(proposal.body:find("release v0.1.0", 1, true) ~= nil)
    t.is_true(proposal.content_fetch:find("git log --oneline --decorate '" .. head_a .. "'", 1, true) ~= nil)
    t.eq(h.count_calls("git rev-list --count 'v0.0.0.." .. head_a .. "'"), 0)
    local marker = h.find_raise(result.raises, "github-proxy.github_issue_create_request").payload
    t.eq(marker.title, "Release proposal v0.1.0")
    t.is_true(marker.body:find('status="pending"', 1, true) ~= nil)
  end,

  test_release_scan_existing_tag_bumps_minor = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    mock_latest_tag("v0.7.0")
    mock_delta("v0.7.0", head_a, 1)
    mock_marker_list("[]\n")

    local result = run_scan()
    t.eq(result.exit_code, 0)
    local proposal = h.find_raise(result.raises, "consensus.proposal").payload
    t.eq(proposal.title, "Release v0.8.0")
    t.is_true(proposal.content_fetch:find("v0.7.0.." .. head_a, 1, true) ~= nil)
  end,

  test_release_scan_git_describe_failure_fails_closed = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    mock_latest_tag_failure("fatal: bad object refs/remotes/origin/dev")

    local result = run_scan()
    t.is_true(result.exit_code ~= 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("git rev-list --count"), 0)
    t.eq(h.count_calls("gh issue list"), 0)
  end,

  test_release_scan_pending_marker_skips_rescan = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    mock_latest_tag("v0.1.0")
    mock_delta("v0.1.0", head_a, 2)
    mock_marker_list(marker_issue("v0.2.0", head_a))

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_release_scan_same_tag_marker_reproposes_after_dev_moves = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_b)
    mock_latest_tag("v0.1.0")
    mock_delta("v0.1.0", head_b, 2)
    mock_marker_list(marker_issue("v0.2.0", head_a))

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local proposal = h.find_raise(result.raises, "consensus.proposal").payload
    t.eq(proposal.proposal_id, core.release_proposal_id("owner/repo", "v0.2.0", head_b))
    t.eq(proposal.dedup_key, core.release_dedup_key("owner/repo", "v0.2.0", head_b))
    t.eq(core.release_fact(core.parse_release_marker_issue_list(marker_issue("v0.2.0", head_a)), "owner/repo", "v0.2.0", head_b), nil)
  end,

  test_release_scan_published_marker_skips_rescan = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    mock_latest_tag("v0.1.0")
    mock_delta("v0.1.0", head_a, 2)
    mock_marker_list(marker_issue("v0.2.0", head_a, "published"))

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(core.release_fact(core.parse_release_marker_issue_list(marker_issue("v0.2.0", head_a, "published")), "owner/repo", "v0.2.0", head_a).status, "published")
    t.eq(core.release_tag_fact(core.parse_release_marker_issue_list(marker_issue("v0.2.0", head_a, "published")), "owner/repo", "v0.2.0").status, "published")
  end,

  test_release_fact_prefers_published_over_pending = function()
    local dedup = core.release_dedup_key("owner/repo", "v0.2.0", head_a)
    local comments = {
      {
        author_login = "fkst-test-bot",
        body = core.release_marker("owner/repo", "v0.2.0", head_a, "pending", dedup),
      },
      {
        author_login = "fkst-test-bot",
        body = core.release_marker("owner/repo", "v0.2.0", head_a, "published", dedup),
      },
    }
    t.eq(core.release_fact(comments, "owner/repo", "v0.2.0", head_a).status, "published")
  end,

  test_release_publish_dry_run_writes_nothing = function()
    mock_env("")
    mock_fetch_dev()
    mock_dev_head(head_a)
    local result = run_publish(release_reached("v0.2.0", head_a))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("git tag -a"), 0)
    t.eq(h.count_calls("gh release create"), 0)
    t.eq(h.count_calls("codex"), 0)
  end,

  test_release_publish_real_write_tags_pushes_and_creates_release = function()
    mock_env("1")
    mock_fetch_dev()
    mock_dev_head(head_a)
    t.mock_command("git rev-parse --verify --quiet refs/tags/'v0.2.0'", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("gh release view 'v0.2.0' --repo 'owner/repo'", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("codex exec", {
      stdout = "## English\n- Ship release automation.\n\n## Chinese\n- Ship release automation.\n\n⟦AI:FKST⟧\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git tag -a", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git push origin 'v0.2.0'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("gh release create 'v0.2.0'", { stdout = "", stderr = "", exit_code = 0 })

    local result = run_publish(release_reached("v0.2.0", head_a), opts("release-publish-real", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("git tag -a"), 1)
    t.is_true(h.has_call("git tag -a 'v0.2.0' '" .. head_a .. "' -m "))
    t.eq(h.count_calls("git push origin 'v0.2.0'"), 1)
    t.eq(h.count_calls("gh release create 'v0.2.0'"), 1)
    t.is_true(h.has_call("--notes "))
    local marker = h.find_raise(result.raises, "github-proxy.github_issue_create_request").payload
    t.eq(marker.title, "Release published v0.2.0")
    t.is_true(marker.body:find('status="published"', 1, true) ~= nil)
  end,

  test_release_publish_existing_tag_must_match_approved_head = function()
    mock_env("1")
    mock_fetch_dev()
    mock_dev_head(head_a)
    t.mock_command("git rev-parse --verify --quiet refs/tags/'v0.2.0'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git rev-list -n 1 'v0.2.0'", { stdout = head_b .. "\n", stderr = "", exit_code = 0 })

    local result = run_publish(release_reached("v0.2.0", head_a), opts("release-publish-stale-tag", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    }))
    t.is_true(result.exit_code ~= 0)
    t.eq(h.count_calls("codex"), 0)
    t.eq(h.count_calls("git tag -a"), 0)
    t.eq(h.count_calls("gh release create"), 0)
  end,

  test_release_publish_existing_tag_and_release_are_idempotent_only_at_head = function()
    mock_env("1")
    mock_fetch_dev()
    mock_dev_head(head_a)
    t.mock_command("git rev-parse --verify --quiet refs/tags/'v0.2.0'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git rev-list -n 1 'v0.2.0'", { stdout = head_a .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("gh release view 'v0.2.0' --repo 'owner/repo'", { stdout = "v0.2.0\n", stderr = "", exit_code = 0 })

    local result = run_publish(release_reached("v0.2.0", head_a), opts("release-publish-existing", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("codex"), 0)
    t.eq(h.count_calls("git tag -a"), 0)
    t.eq(h.count_calls("gh release create"), 0)
    local marker = h.find_raise(result.raises, "github-proxy.github_issue_create_request").payload
    t.eq(marker.title, "Release published v0.2.0")
  end,

  test_release_publish_moved_head_aborts_before_writes = function()
    mock_env("1")
    mock_fetch_dev()
    mock_dev_head(head_b)
    local result = run_publish(release_reached("v0.2.0", head_a), opts("release-publish-moved", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("git tag -a"), 0)
    t.eq(h.count_calls("gh release create"), 0)
    t.eq(h.count_calls("codex"), 0)
  end,
}
