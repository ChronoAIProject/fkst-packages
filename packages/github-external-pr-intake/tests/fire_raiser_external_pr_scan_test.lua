local t = fkst.test
local core = require("core")
local gh_argv = require("testkit_internal.gh_argv_mock")
gh_argv.install(t, core)

local repo = "owner/repo"
local pr = '{"number":7,"title":"Contributor patch","headRefName":"feature/contrib","baseRefName":"dev","state":"OPEN","createdAt":"2026-06-03T01:02:03Z","updatedAt":"2026-06-19T01:02:03Z","author":{"login":"contributor"},"comments":[],"assignees":[]}'

local function mock_env()
  local values = {
    FKST_GITHUB_REPO = repo,
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_GITHUB_WRITE = "",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
    FKST_GITHUB_AUTHORIZED_LOGINS = "",
    FKST_EXTERNAL_PR_TRUSTED_CONTRIBUTOR_LOGINS = "contributor",
  }
  for name, value in pairs(values) do
    for _ = 1, 4 do
      t.mock_command(core.read_env_command(name), {
        stdout = value,
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

return {
  test_fire_raiser_external_pr_scan_routes_and_raises_real_candidate = function()
    mock_env()
    t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'", {
      stdout = "[[" .. pr .. "]]\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr view '7' --repo 'owner/repo'", {
      stdout = pr .. "\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue list --repo 'owner/repo'", {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })

    local trace = t.fire_raiser("external_pr_scan")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser:match("([^.]+)$"), "external_pr_scan")
    t.eq(trace.routed_to[1]:match("([^.]+)$"), "external_pr_intake")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 1)
    t.eq(trace.raised[1].queue:match("([^.]+)$"), "external_pr_candidate")
    t.eq(trace.raised[1].payload.schema, "github-external-pr-intake.v1")
    t.eq(trace.raised[1].payload.repo, repo)
    t.eq(trace.raised[1].payload.number, 7)
    t.eq(trace.raised[1].payload.updated_at, "2026-06-19T01:02:03Z")
    t.eq(trace.raised[1].payload.dedup_key, "github-external-pr-intake/owner/repo/pr/7")
    t.eq(trace.raised[1].payload.source_ref.kind, "external")
    t.eq(trace.raised[1].payload.source_ref.ref, "owner/repo#pr/7")
  end,
}
