local m_claims = require("devloop.claims")
local owner_fact = require("devloop.sync_conflict_owner")

local M = {}

function M.detect(current, repo, managed)
  local body = current and current.body
  if not owner_fact.has_marker(body) then
    return nil
  end
  if not m_claims.is_trusted_issue_author_login(m_claims.issue_author_login(current), managed) then
    error("github-devloop: sync-conflict-owner-untrusted: exact owner issue body marker was not authored by a trusted bot")
  end
  local fact = owner_fact.find_marker(body)
  if fact == nil then
    error("github-devloop: sync-conflict-owner-invalid: exact owner issue body marker could not be parsed")
  end
  if tostring(fact.repo or "") ~= tostring(repo or "") then
    error("github-devloop: sync-conflict-owner-mismatch: exact owner repo does not match implementation repo")
  end
  return {
    repo = fact.repo,
    issue_number = fact.issue_number,
    proposal_id = fact.proposal_id,
    branch = fact.branch,
    checkpoint = {
      branch = fact.branch,
      head_sha = fact.head_sha,
    },
  }
end

return M
