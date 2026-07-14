local M = {}

local strings = require("contract.strings")

-- Pure cost/usage-report logic for chrono-finance. Kept in a dedicated module
-- (not the ambient package `core`) so departments require it DIRECTLY, per the
-- devloop-decouple / service-locator conventions. All helpers are file-local and
-- exported on M at the bottom (no `M.x(` / `core.x(` self-calls).
--
-- Codex returns ONE usage OBJECT per window:
--   {"summary": "...", "total_units": 1234,
--    "line_items": [{"area": "PR #42", "units": 300}, ...]}
-- which becomes exactly ONE deduped cost/usage report issue.

local company_label = "fkst-company"
local department_label = "fkst-finance"

local limits = {
  repo = 200,
  title = 240,
  body = 12000,
  dedup_key = 512,
  summary = 4000,
  area = 160,
}

local default_interval = "60m"
local tick_name = "finance_tick"
local max_line_items = 50
local budget_env = "FKST_FINANCE_BUDGET_MAX_UNITS"

local function tick_queue()
  return tick_name
end

local function department_labels()
  return { company_label, department_label }
end

local function poll_interval()
  return default_interval
end

local function budget_env_name()
  return budget_env
end

-- Prompt: attribute recent engine/codex spend to merged PRs and closed features,
-- returning a single bounded usage object (deliberately distinct from a scan).
local function build_prompt(repo, window_label)
  return table.concat({
    "You are a cost/usage accountant for repository " .. tostring(repo) .. ".",
    "Read the local checkout (git log, merged PRs, closed issues) yourself.",
    "Do not edit files, run gh, or run git mutations.",
    "Attribute recent development effort to merged PRs and closed features for the",
    "window " .. tostring(window_label) .. ", estimating relative work units per area.",
    "Units are a relative effort proxy (integer >= 0), NOT real billing figures.",
    "Return strict JSON only: a single object, not an array.",
    'Object schema: {"summary":"...","total_units":123,"line_items":[{"area":"PR #42","units":30}]}',
  }, "\n")
end

local function non_negative_integer(value)
  return type(value) == "number" and value >= 0 and math.floor(value) == value
end

local function valid_line_item(item)
  return type(item) == "table"
    and strings.is_bounded_string(item.area, limits.area)
    and non_negative_integer(item.units)
end

-- Parse codex stdout into a validated usage object.
local function parse_usage(stdout)
  local raw = strings.trim(stdout or "")
  if raw:sub(1, 1) ~= "{" or raw:sub(-1) ~= "}" then
    error("chrono-finance: malformed-json: codex output is not a JSON object")
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    error("chrono-finance: malformed-json: codex output is malformed JSON")
  end
  if not strings.is_bounded_string(decoded.summary, limits.summary) then
    error("chrono-finance: invalid-summary: usage summary missing or too long")
  end
  if not non_negative_integer(decoded.total_units) then
    error("chrono-finance: invalid-total: total_units must be a non-negative integer")
  end
  local raw_items = decoded.line_items
  if type(raw_items) ~= "table" then
    error("chrono-finance: invalid-line-items: line_items must be an array")
  end
  local items = {}
  for index, item in ipairs(raw_items) do
    if index > max_line_items then
      break
    end
    if not valid_line_item(item) then
      error("chrono-finance: invalid-line-item: index=" .. tostring(index))
    end
    items[index] = { area = item.area, units = item.units }
  end
  return {
    summary = decoded.summary,
    total_units = decoded.total_units,
    line_items = items,
  }
end

-- One report per window: bucket = calendar-day index derived from the window label.
local function window_dedup_key(repo, window_label)
  local seed = tostring(repo) .. "|" .. tostring(window_label)
  local readable = table.concat({
    "chrono-finance-report",
    strings.sanitize_key(repo, 120),
    strings.sanitize_key(window_label, 80),
    strings.decimal_checksum(seed),
  }, "/")
  return readable:sub(1, limits.dedup_key)
end

local function over_budget(total_units, budget_max)
  if type(budget_max) ~= "number" or budget_max < 1 then
    return false
  end
  return total_units > budget_max
end

local function report_body(usage, window_label, dedup_key, budget_max)
  local lines = {
    "Automated cost/usage report from the fkst company finance department.",
    "",
    "- **Window:** " .. tostring(window_label),
    "- **Total effort units (relative proxy):** " .. tostring(usage.total_units),
  }
  if over_budget(usage.total_units, budget_max) then
    lines[#lines + 1] = "- **Budget:** OVER threshold of " .. tostring(budget_max) .. " units"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**Summary:** " .. tostring(usage.summary)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "**By area:**"
  for _, item in ipairs(usage.line_items) do
    lines[#lines + 1] = "- `" .. tostring(item.area) .. "` — " .. tostring(item.units) .. " units"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<!-- fkst:chrono-finance:report:v1 " .. dedup_key .. " -->"
  return table.concat(lines, "\n")
end

-- Map a validated usage object to a single github-proxy `issue-create.v1` report
-- request carrying the umbrella + department labels. budget_max is optional.
local function report_issue_request(repo, usage, window_label, budget_max)
  if not strings.is_bounded_string(repo, limits.repo) then
    error("chrono-finance: invalid-repo: repo out of bounds")
  end
  local dedup_key = window_dedup_key(repo, window_label)
  local alert = over_budget(usage.total_units, budget_max)
  local prefix = alert and "Finance budget alert: " or "Finance report: "
  local title = (prefix .. tostring(window_label) .. " ("
    .. tostring(usage.total_units) .. " units)"):sub(1, limits.title)
  local body = report_body(usage, window_label, dedup_key, budget_max)
  if not strings.is_bounded_string(body, limits.body) then
    error("chrono-finance: invalid-body: body out of bounds")
  end
  return {
    schema = "github-proxy.issue-create.v1",
    repo = tostring(repo),
    title = title,
    body = body,
    labels = department_labels(),
    dedup_key = dedup_key,
    source_ref = {
      kind = "repo-site",
      ref = (tostring(repo) .. "#chrono-finance/" .. strings.decimal_checksum(dedup_key)):sub(1, limits.repo),
    },
  }
end

M.tick_queue = tick_queue
M.department_labels = department_labels
M.poll_interval = poll_interval
M.budget_env_name = budget_env_name
M.build_prompt = build_prompt
M.parse_usage = parse_usage
M.over_budget = over_budget
M.window_dedup_key = window_dedup_key
M.report_issue_request = report_issue_request

return M
