local core = require("core")

local M = {}

local function proposal_title(issue)
  return core.bounded_text("Draft maintainer reply for issue #" .. tostring(issue.issue_number), 240)
end

local function fetch_context(fields)
  return "Fetch or inspect the full current issue from the source system before judging.\n"
    .. "Source issue: " .. tostring(fields.repo) .. "#issue/" .. tostring(fields.issue_number) .. "\n"
    .. "URL: " .. tostring(fields.url)
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
    fetch_context = fetch_context(fields),
  }
end

return M
