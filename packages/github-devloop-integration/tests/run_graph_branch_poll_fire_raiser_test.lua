local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")

local t = h.t
local repo = "raiser-owner/raiser-repo"

local function mock_repeated(command, result, times)
  for _ = 1, times or 1 do
    t.mock_command(command, result)
  end
end

local function mock_env()
  local ok = { stderr = "", exit_code = 0 }
  mock_repeated(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
    stdout = "dev", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 6)
  mock_repeated(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
    stdout = "integration/fire-raiser", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 6)
  mock_repeated(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo, stderr = ok.stderr, exit_code = ok.exit_code,
  }, 6)
  mock_repeated(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
    stdout = "fkst-test-bot", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 6)
  mock_repeated(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
    stdout = "", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 6)
  mock_repeated(devloop_base.read_env_command("FKST_DEVLOOP_ROLLUP_MERGE"), {
    stdout = "auto", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 3)
  mock_repeated(devloop_base.read_env_command("FKST_DEVLOOP_ROLLUP_RED_WINDOW_MINUTES"), {
    stdout = "", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 3)
  mock_repeated(devloop_base.read_env_command("FKST_DEVLOOP_RELEASE_NOTES_FALLBACK"), {
    stdout = "", stderr = ok.stderr, exit_code = ok.exit_code,
  }, 3)
end

local function mock_branch_state()
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  mock_repeated("git fetch 'origin' 'dev'", ok, 4)
  mock_repeated("git fetch 'origin' 'integration/fire-raiser'", ok, 4)
  mock_repeated("refs/remotes/'origin'/'dev'^{commit}", {
    stdout = "aaaaaaaa\n", stderr = "", exit_code = 0,
  }, 3)
  mock_repeated("refs/remotes/'origin'/'integration/fire-raiser'^{commit}", {
    stdout = "bbbbbbbb\n", stderr = "", exit_code = 0,
  }, 3)
  mock_repeated("merge-base --is-ancestor", {
    stdout = "", stderr = "", exit_code = 1,
  }, 2)
  t.mock_command("git diff --quiet aaaaaaaa bbbbbbbb", {
    stdout = "", stderr = "", exit_code = 1,
  })
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-branch-poll-fire-raiser", stderr = "", exit_code = 0,
  })
  t.mock_command("mkdir -p", ok)
  t.mock_command("git worktree add --detach", ok)
  t.mock_command("merge --no-ff --no-commit", {
    stdout = "", stderr = "conflict", exit_code = 1,
  })
  t.mock_command("ls-files -u", {
    stdout = "100644 abc 1\tcore.lua\n", stderr = "", exit_code = 0,
  })
  t.mock_command("git worktree remove --force", ok)
  t.mock_command("git rev-list --count refs/remotes/origin/'dev'..refs/remotes/origin/'integration/fire-raiser'", {
    stdout = "0\n", stderr = "", exit_code = 0,
  })
  t.mock_command("repos/" .. repo .. "/pulls?state=open", {
    stdout = "[[]]\n", stderr = "", exit_code = 0,
  })
end

local function routed_set(trace)
  local result = {}
  for _, department in ipairs(trace.routed_to or {}) do
    result[department] = true
  end
  return result
end

return {
  test_fire_raiser_branch_poll_routes_fanout_and_raises_sync_conflict = function()
    mock_env()
    mock_branch_state()

    local trace = t.fire_raiser("branch_poll")

    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "github-devloop-integration.branch_poll")
    local routed = routed_set(trace)
    t.eq(routed["github-devloop-integration.sync_scan"], true)
    t.eq(routed["github-devloop-integration.rollup_scan"], true)
    t.eq(routed["github-devloop-integration.pr_freshness_scan"], true)
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    local conflict = nil
    for _, raised in ipairs(trace.raised) do
      if raised.queue == "github-devloop-integration.devloop_sync_conflict"
        and raised.payload.repo == repo then
        conflict = raised
      end
    end
    t.is_true(conflict ~= nil)
    t.eq(conflict.payload.schema, "github-devloop.v1")
    t.eq(conflict.payload.upstream_branch, "dev")
    t.eq(conflict.payload.integration_branch, "integration/fire-raiser")
    t.eq(conflict.payload.upstream_sha, "aaaaaaaa")
    t.eq(conflict.payload.integration_sha, "bbbbbbbb")
    t.eq(conflict.payload.source_ref.ref, repo .. "#branch-sync/dev/integration/fire-raiser")
  end,
}
