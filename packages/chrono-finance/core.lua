local M = {}

local report = require("report_logic")

-- chrono-finance's [conformance] entrypoint (fkst.toml function =
-- "core.conformance_errors"). The report logic lives in `report_logic.lua`, which
-- the departments require directly; `core.lua` only carries the conformance hook
-- so no department reaches through the ambient `core` table.
--
-- Contract: a canonical usage object round-trips into a well-formed github-proxy
-- report request carrying BOTH the umbrella and department labels. Empty = pass.
function M.conformance_errors()
  local errors = {}
  local usage = {
    summary = "Two merged PRs implementing the dashboard.",
    total_units = 90,
    line_items = { { area = "PR #42", units = 60 }, { area = "PR #43", units = 30 } },
  }
  local ok, request = pcall(report.report_issue_request, "owner/repo", usage, "2026-06-19", nil)
  if not ok then
    errors[#errors + 1] = "chrono-finance: conformance: sample usage did not map: " .. tostring(request)
    return errors
  end
  if request.schema ~= "github-proxy.issue-create.v1" then
    errors[#errors + 1] = "chrono-finance: conformance: wrong request schema"
  end
  local seen = {}
  for _, label in ipairs(request.labels or {}) do
    seen[label] = true
  end
  if not seen["fkst-company"] then
    errors[#errors + 1] = "chrono-finance: conformance: request missing fkst-company label"
  end
  if not seen["fkst-finance"] then
    errors[#errors + 1] = "chrono-finance: conformance: request missing fkst-finance label"
  end
  return errors
end

return M
