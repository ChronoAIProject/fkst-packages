local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
    FKST_DEVLOOP_INTEGRATION_BRANCH = "integration/dev",
    FKST_DEVLOOP_ROLLUP_MERGE = "auto",
    FKST_GITHUB_WRITE = "",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end

local function mock_env(write_mode, rollup_merge, integration)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = integration or "integration/dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = write_mode or "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = integration or "integration/dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = rollup_merge or "auto", stderr = "", exit_code = 0 })
end

local function run_scan(run_opts)
  return t.run_department("departments/rollup_scan/main.lua", {
    queue = "devloop_branch_tick",
    payload = { schema = "github-devloop.branch-tick.v1" },
  }, run_opts or opts("rollup-scan"))
end

local function mock_fetches()
  t.mock_command("git fetch 'origin' '+refs/heads/dev:refs/remotes/origin/dev'", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git fetch 'origin' '+refs/heads/integration/dev:refs/remotes/origin/integration/dev'", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_branch_snapshot(upstream_sha, integration_sha)
  mock_fetches()
  t.mock_command("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = (upstream_sha or "aaaa1111") .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'integration/dev'^{commit}", {
    stdout = (integration_sha or "def456") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_ahead(upstream_sha, integration_sha, count)
  t.mock_command(
    "git rev-list --count '" .. tostring(upstream_sha or "aaaa1111") .. ".." .. tostring(integration_sha or "def456") .. "'",
    {
    stdout = tostring(count) .. "\n",
    stderr = "",
    exit_code = 0,
    }
  )
end

local function mock_content_diff(upstream_sha, integration_sha, has_diff)
  t.mock_command("git diff --quiet '" .. tostring(upstream_sha or "aaaa1111") .. "' '" .. tostring(integration_sha or "def456") .. "'", {
    stdout = "",
    stderr = "",
    exit_code = has_diff and 1 or 0,
  })
end

local function mock_pr_list(pr)
  local stdout = "[]\n"
  if pr ~= nil then
    stdout = string.format(
      '[{"number":%d,"headRefOid":"%s","headRefName":"integration/dev","baseRefName":"dev","state":"OPEN"}]\n',
      pr.number or 9,
      h.json_string(pr.head_sha or "def456")
    )
  end
  t.mock_command("gh pr list", { stdout = stdout, stderr = "", exit_code = 0 })
end

local function mock_rollup_state(upstream_sha, integration_sha, ahead, has_diff)
  mock_branch_snapshot(upstream_sha, integration_sha)
  mock_ahead(upstream_sha, integration_sha, ahead)
  if ahead > 0 then
    mock_content_diff(upstream_sha, integration_sha, has_diff)
  end
end

return {
  test_rollup_scan_integration_equal_upstream_noops = function()
    mock_env("", "auto", "dev")
    local result = run_scan(opts("rollup-same", { FKST_DEVLOOP_INTEGRATION_BRANCH = "dev" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("git fetch"), 0)
  end,

  test_rollup_scan_not_ahead_noops = function()
    mock_env()
    mock_rollup_state("aaaa1111", "def456", 0, false)
    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr list"), 0)
  end,

  test_rollup_scan_ahead_no_open_pr_real_creates_with_head_and_base = function()
    mock_env("1")
    mock_rollup_state("aaaa1111", "def456", 3, true)
    mock_pr_list(nil)
    mock_rollup_state("aaaa1111", "def456", 3, true)
    t.mock_command("gh pr create", { stdout = "https://github.example/owner/repo/pull/9\n", stderr = "", exit_code = 0 })
    mock_pr_list({ number = 9 })
    mock_rollup_state("aaaa1111", "def456", 3, true)
    local result = run_scan(opts("rollup-create", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr create"), 1)
    t.is_true(h.has_call("--head 'integration/dev'"))
    t.is_true(h.has_call("--base 'dev'"))
  end,

  test_rollup_scan_ahead_without_content_diff_skips_pr = function()
    mock_env("1")
    mock_rollup_state("aaaa1111", "def456", 1, false)
    local result = run_scan(opts("rollup-empty-diff", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr list"), 0)
    t.eq(h.count_calls("gh pr create"), 0)
  end,

  test_rollup_scan_existing_pr_never_duplicates_create = function()
    mock_env("1")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list({ number = 9 })
    mock_rollup_state("aaaa1111", "def456", 2, true)
    local result = run_scan(opts("rollup-existing", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr create"), 0)
  end,

  test_rollup_scan_manual_posture_no_ready_event = function()
    mock_env("1", "manual")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list({ number = 9 })
    mock_rollup_state("aaaa1111", "def456", 2, true)
    local result = run_scan(opts("rollup-manual", { FKST_GITHUB_WRITE = "1", FKST_DEVLOOP_ROLLUP_MERGE = "manual" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_rollup_scan_auto_raises_ready_payload = function()
    mock_env("1", "auto")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list({ number = 9 })
    mock_rollup_state("aaaa1111", "def456", 2, true)
    local result = run_scan(opts("rollup-auto", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local raised = h.find_raise(result.raises, "devloop_rollup_ready")
    t.eq(raised.payload.schema, "github-devloop.v1")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.pr_number, 9)
    t.eq(raised.payload.upstream_branch, "dev")
    t.eq(raised.payload.integration_branch, "integration/dev")
    t.eq(raised.payload.head_sha, "def456")
    t.eq(raised.payload.source_ref.ref, "owner/repo#pr/9")
    t.eq(raised.payload.dedup_key, core.rollup_dedup_key("owner/repo", "dev", "integration/dev", 9, "def456"))
  end,

  test_rollup_scan_dry_run_never_creates_pr = function()
    mock_env("")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list(nil)
    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr create"), 0)
  end,

  test_rollup_scan_rechecks_empty_diff_before_create = function()
    mock_env("1")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list(nil)
    mock_rollup_state("cccc3333", "dddd4444", 1, false)
    local result = run_scan(opts("rollup-create-recheck-empty", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr create"), 0)
  end,

  test_rollup_scan_existing_pr_rechecks_empty_diff_before_ready = function()
    mock_env("1")
    mock_rollup_state("aaaa1111", "def456", 2, true)
    mock_pr_list({ number = 9 })
    mock_rollup_state("cccc3333", "dddd4444", 1, false)
    local result = run_scan(opts("rollup-ready-recheck-empty", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(h.count_calls("gh pr create"), 0)
  end,
}
