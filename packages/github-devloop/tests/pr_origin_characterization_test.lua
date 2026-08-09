local github_author_policy = require("devloop.github_author_policy")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local forge_strings = require("forge.strings")
local m_facts = require("devloop.markers.facts")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local implementation_version = "ready/github-devloop/issue/owner/repo/42/intake/0000000001"
local stale_branch = "feature/previous"
local stale_base_branch = "main"
local pr_origin_marker = '<!-- fkst:github-devloop:pr-origin:v1 proposal="github-devloop/issue/owner/repo/42"'
  .. ' issue="42" branch="feature/previous"'
  .. ' impl_version="ready/github-devloop/issue/owner/repo/42/intake/0000000001"'
  .. ' base_branch="main" -->'

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
      comment(author_login, pr_origin_marker),
    },
  }
end

local function with_trusted_bot(login, fn)
  local previous = parsers_misc.configured_trusted_bot_login()
  parsers_misc.configure_trusted_bot_login(login)
  local ok, result = pcall(fn)
  parsers_misc.configure_trusted_bot_login(previous)
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_pr_origin_fact_accepts_stale_values_from_mixed_case_trusted_signer = function()
    with_trusted_bot("Trusted-Bot[bot]", function()
      t.eq(parsers_misc.configured_trusted_bot_login(), "Trusted-Bot[bot]")
      t.eq(forge_strings.canonical_login("Trusted-Bot[bot]"), "trusted-bot")
      t.eq(forge_strings.canonical_login("tRuStEd-BoT[bot]"), "trusted-bot")

      local pr = production_pr("tRuStEd-BoT[bot]")
      -- Characterize the parser's current comment-only contract, not a freshness policy.
      local origin = m_facts.pr_origin_fact(pr.comments)

      t.eq(origin.proposal_id, proposal_id)
      t.eq(origin.repo, "owner/repo")
      t.eq(origin.issue_number, "42")
      t.is_nil(origin.pr_number)
      t.eq(origin.branch, stale_branch)
      t.eq(origin.impl_version, implementation_version)
      t.eq(origin.base_branch, stale_base_branch)
      t.eq(pr.headRefName, "feature/current")
      t.eq(pr.baseRefName, "dev")
      t.eq(origin.branch == pr.headRefName, false)
      t.eq(origin.base_branch == pr.baseRefName, false)
    end)
  end,

  test_pr_origin_fact_ignores_an_otherwise_managed_peer_bot = function()
    local managed = github_author_policy.managed_bot_logins(function(command)
      t.eq(command, 'printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"')
      return { stdout = "Peer-Bot[bot]", stderr = "", exit_code = 0 }
    end)
    t.eq(managed["peer-bot"], true)
    t.eq(github_author_policy.is_managed_bot_login("pEeR-BoT[bot]", managed), true)

    with_trusted_bot("trusted-bot", function()
      local pr = production_pr("pEeR-BoT[bot]")
      t.eq(pr.comments[1].author.login, "pEeR-BoT[bot]")
      t.eq(pr.comments[1].body, pr_origin_marker)
      t.is_nil(m_facts.pr_origin_fact(pr.comments))
    end)
  end,
}
