local M = {}

local scan = require("scan_logic")

-- chrono-security's [conformance] entrypoint (fkst.toml function =
-- "core.conformance_errors"). The scan logic itself lives in `scan_logic.lua`,
-- which the departments require directly; `core.lua` only carries the conformance
-- hook so no department reaches through the ambient `core` table.
--
-- Contract: a canonical finding must round-trip into a well-formed github-proxy
-- create request carrying BOTH the umbrella and department labels. Empty = pass.
function M.conformance_errors()
  local errors = {}
  local sample = {
    file = "src/app.lua",
    line = 12,
    severity = "high",
    title = "unbounded input reaches shell",
    remediation = "validate and quote the argument",
  }
  local ok, request = pcall(scan.issue_create_request, "owner/repo", sample)
  if not ok then
    errors[#errors + 1] = "chrono-security: conformance: sample finding did not map: " .. tostring(request)
    return errors
  end
  if request.schema ~= "github-proxy.issue-create.v1" then
    errors[#errors + 1] = "chrono-security: conformance: wrong request schema"
  end
  local seen = {}
  for _, label in ipairs(request.labels or {}) do
    seen[label] = true
  end
  if not seen["fkst-company"] then
    errors[#errors + 1] = "chrono-security: conformance: request missing fkst-company label"
  end
  if not seen["fkst-security"] then
    errors[#errors + 1] = "chrono-security: conformance: request missing fkst-security label"
  end
  return errors
end

return M
