local core = require("core")
local t = fkst.test

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function fetch_command_text(source)
  local parts = { source.command.tool }
  for _, arg in ipairs(source.command.args or {}) do
    table.insert(parts, arg)
  end
  return table.concat(parts, " ")
end

local function assert_no_embedded_source_content(proposal)
  t.is_nil(proposal.body)
  t.is_nil(proposal.diff)
  t.is_nil(proposal.comments)
  t.is_nil(proposal.source_bundle)
  t.is_nil(proposal.fetch_context)
end

local function assert_issue_fetch_source(source, repo, issue_number)
  t.eq(source.kind, "github_issue")
  t.eq(source.source_ref.kind, "external")
  t.eq(source.source_ref.ref, tostring(repo) .. "#issue/" .. tostring(issue_number))
  t.eq(fetch_command_text(source), "gh issue view " .. tostring(issue_number)
    .. " --repo " .. tostring(repo)
    .. " --json title,body,comments,state,labels,updatedAt")
end

local function assert_issue_proposal_fetch_sources(proposal, repo, issue_number)
  assert_no_embedded_source_content(proposal)
  t.eq(#proposal.fetch_sources, 1)
  assert_issue_fetch_source(proposal.fetch_sources[1], repo, issue_number)
end

local function assert_pr_review_fetch_sources(proposal, repo, issue_number, pr_number, head_sha)
  assert_no_embedded_source_content(proposal)
  t.eq(#proposal.fetch_sources, 2)
  assert_issue_fetch_source(proposal.fetch_sources[1], repo, issue_number)
  local diff_source = proposal.fetch_sources[2]
  t.eq(diff_source.kind, "github_pr_diff")
  t.eq(diff_source.source_ref.kind, "external")
  t.eq(diff_source.source_ref.ref, tostring(repo) .. "#pr/" .. tostring(pr_number))
  t.eq(fetch_command_text(diff_source), "gh pr diff " .. tostring(pr_number) .. " --repo " .. tostring(repo))
  t.eq(diff_source.expected_head_sha, tostring(head_sha))
  t.eq(diff_source.cwd_required, true)
  t.eq(diff_source.read_files_from_cwd, true)
end

local function issue(extra)
  local value = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Implement decision recorder",
    url = "https://github.example/owner/repo/issues/42",
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
    labels = { "fkst-dev:enabled" },
    dedup_key = "owner/repo#issue#42@2026-06-03T01:02:03Z",
    source_ref = source_ref(),
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function reached(extra)
  local value = {
    schema = "consensus.consensus_reached.v1",
    proposal_id = "github-devloop/issue/owner/repo/42",
    decision = "approve",
    body = "All angles approve.",
    dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    source_ref = source_ref(),
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function unresolved(extra)
  local value = {
    schema = "consensus.consensus_converge.v1",
    proposal_id = "github-devloop/issue/owner/repo/42",
    dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    source_ref = source_ref(),
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

return {
  core = core,
  t = t,
  has_value = has_value,
  source_ref = source_ref,
  fetch_command_text = fetch_command_text,
  assert_no_embedded_source_content = assert_no_embedded_source_content,
  assert_issue_fetch_source = assert_issue_fetch_source,
  assert_issue_proposal_fetch_sources = assert_issue_proposal_fetch_sources,
  assert_pr_review_fetch_sources = assert_pr_review_fetch_sources,
  issue = issue,
  reached = reached,
  unresolved = unresolved,
}
