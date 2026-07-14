local M = {}

local content = require("content_logic")

-- chrono-marketing's [conformance] entrypoint (fkst.toml function =
-- "core.conformance_errors"). The content logic lives in `content_logic.lua`,
-- which the department requires directly; `core.lua` only carries the conformance
-- hook so no department reaches through the ambient `core` table.
--
-- Contract: a canonical open fkst-marketing request + drafted artifact round-trip
-- into a well-formed github-proxy comment request. Empty = pass.
function M.conformance_errors()
  local errors = {}
  local entity = {
    schema = "github-proxy.v1",
    type = "issue",
    state = "OPEN",
    repo = "owner/repo",
    number = 42,
    title = "Announce the dashboard",
    body = "Draft a launch post for the new dashboard.",
    labels = { "fkst-company", "fkst-marketing" },
  }
  local ok_request, request = pcall(content.request_from_entity, entity)
  if not ok_request then
    errors[#errors + 1] = "chrono-marketing: conformance: sample entity did not normalize: " .. tostring(request)
    return errors
  end
  local drafted = {
    title = "Introducing the dashboard",
    channel = "social",
    body_markdown = "The new dashboard ships today.",
    image_prompt = "a clean product dashboard",
  }
  local ok_comment, comment = pcall(content.comment_request, request, drafted)
  if not ok_comment then
    errors[#errors + 1] = "chrono-marketing: conformance: sample content did not map: " .. tostring(comment)
    return errors
  end
  if comment.schema ~= "github-proxy.v1" then
    errors[#errors + 1] = "chrono-marketing: conformance: wrong comment schema"
  end
  if comment.issue_number ~= 42 then
    errors[#errors + 1] = "chrono-marketing: conformance: comment lost the issue number"
  end
  return errors
end

return M
