local core = require("core")

local M = {}

local function proposal_title(issue)
  return core.bounded_text("Draft maintainer reply for issue #" .. tostring(issue.issue_number), 240)
end

local function fetch_sources(fields)
  return {
    {
      kind = "issue",
      source_ref = fields.source_ref,
      url = tostring(fields.url),
    },
  }
end

function M.build_proposal(issue)
  local fields = core.require_issue_fields(issue)
  local proposal_id = core.proposal_id(fields.repo, fields.issue_number)

  return {
    schema = "consensus.proposal.v1",
    proposal_id = proposal_id,
    dedup_key = core.proposal_dedup_key(fields.repo, fields.issue_number, fields.updated_at),
    title = proposal_title(fields),
    source_ref = fields.source_ref,
    fetch_sources = fetch_sources(fields),
  }
end

return M
