local github_author_policy = require("devloop.github_author_policy")
local devloop_base = require("devloop.base")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local stale_branch = "feature/previous"
local stale_base_branch = "main"

local function comment(author_login, body)
  return {
    author = { login = author_login },
    body = body,
    createdAt = "2026-08-02T18:00:00Z",
  }
end

local function production_pr(author_login)
  return {
    number = 7,
    headRefName = "feature/current",
    baseRefName = "dev",
    state = "OPEN",
    author = { login = "contributor" },
    comments = {
      comment(author_login, m_builders.pr_origin_marker(
        proposal_id,
        42,
        stale_branch,
        "ready/github-devloop/issue/owner/repo/42/intake/0000000001",
        stale_base_branch
      )),
    },
  }
end

local function with_trusted_bot(login, fn)
  local previous = devloop_base.configured_trusted_bot_login()
  devloop_base.configure_trusted_bot_login(login)
  local ok, result = pcall(fn)
  devloop_base.configure_trusted_bot_login(previous)
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_pr_origin_fact_accepts_stale_values_from_mixed_case_trusted_bot = function()
    with_trusted_bot("Trusted-Bot[bot]", function()
      t.eq(devloop_base.strip_bot_login_suffix("Trusted-Bot[bot]"), "trusted-bot")

      local pr = production_pr("tRuStEd-BoT[bot]")
      local origin = m_facts.pr_origin_fact(pr.comments)

      t.eq(origin.proposal_id, proposal_id)
      t.eq(origin.issue_number, "42")
      t.eq(origin.branch, stale_branch)
      t.eq(origin.base_branch, stale_base_branch)
      t.eq(pr.headRefName, "feature/current")
      t.eq(pr.baseRefName, "dev")
    end)
  end,

  test_pr_origin_fact_ignores_an_otherwise_managed_peer_bot = function()
    local managed = github_author_policy.managed_bot_logins(function(command)
      t.eq(command, 'printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"')
      return { stdout = "Peer-Bot[bot]", stderr = "", exit_code = 0 }
    end)
    t.eq(managed["peer-bot"], true)

    with_trusted_bot("trusted-bot", function()
      local pr = production_pr("Peer-Bot[bot]")
      t.is_nil(m_facts.pr_origin_fact(pr.comments))
    end)
  end,
}
