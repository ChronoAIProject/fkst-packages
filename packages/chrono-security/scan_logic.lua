local M = {}

local strings = require("contract.strings")

-- Pure security-scan logic for chrono-security. Kept in a dedicated module (not
-- the ambient package `core`) so departments require it DIRECTLY
-- (`require("scan_logic").fn(...)`) rather than reaching through `core.X`, per the
-- devloop-decouple / service-locator conventions. Every helper is a file-local
-- function referenced locally (no `M.x(` self-calls), then exported on M.

local company_label = "fkst-company"
local department_label = "fkst-security"

-- github-proxy `github-proxy.issue-create.v1` field bounds (mirrors the proxy).
local limits = {
  repo = 200,
  title = 240,
  body = 12000,
  dedup_key = 512,
  source_ref_kind = 80,
  source_ref_ref = 200,
}

local finding_bounds = {
  file = 240,
  detail = 1200,
  remediation = 1200,
}

local default_interval = "30m"
local default_max_findings = 5
local tick_name = "security_tick"

local severities = {
  critical = true,
  high = true,
  medium = true,
  low = true,
}

local function tick_queue()
  return tick_name
end

local function department_labels()
  return { company_label, department_label }
end

local function poll_interval()
  return default_interval
end

local function max_findings()
  return default_max_findings
end

-- Prompt for the security scan: concrete, cited, remediable vulnerabilities only.
local function build_prompt(repo, max_count)
  return table.concat({
    "You are a security reviewer for repository " .. tostring(repo) .. ".",
    "Read the local checkout yourself. Do not edit files, run gh, or run git.",
    "Report only concrete, exploitable security or quality defects: injection,",
    "auth/authz gaps, secret handling, unsafe deserialization, path traversal,",
    "SSRF, missing input validation, or a clear resource-safety bug.",
    "Each finding must cite an exact file and line and a specific remediation.",
    "Skip vague smells, speculative risks, and anything you cannot tie to a line.",
    "Return strict JSON only: an array of at most " .. tostring(max_count) .. " objects.",
    'Object schema: {"file":"path","line":10,"severity":"high","title":"...","remediation":"..."}',
  }, "\n")
end

local function valid_finding(item)
  if type(item) ~= "table" then
    return false
  end
  if not strings.is_bounded_string(item.file, finding_bounds.file) then
    return false
  end
  if type(item.line) ~= "number" or item.line < 1 or math.floor(item.line) ~= item.line then
    return false
  end
  if type(item.severity) ~= "string" or not severities[item.severity] then
    return false
  end
  if not strings.is_bounded_string(item.title, finding_bounds.detail) then
    return false
  end
  if not strings.is_bounded_string(item.remediation, finding_bounds.remediation) then
    return false
  end
  return true
end

-- Parse codex stdout: a strict, dense JSON array of security findings.
local function parse_findings(stdout)
  local raw = strings.trim(stdout or "")
  if raw:sub(1, 1) ~= "[" or raw:sub(-1) ~= "]" then
    error("chrono-security: malformed-json: codex output is not a JSON array")
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    error("chrono-security: malformed-json: codex output is malformed JSON")
  end
  local highest = 0
  for key in pairs(decoded) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      error("chrono-security: non-array-json: codex output is not a JSON array")
    end
    if key > highest then
      highest = key
    end
  end
  if highest ~= #decoded then
    error("chrono-security: malformed-json: codex output is not a dense JSON array")
  end
  local findings = {}
  for index, item in ipairs(decoded) do
    if not valid_finding(item) then
      error("chrono-security: invalid-finding-shape: index=" .. tostring(index))
    end
    findings[index] = {
      file = item.file,
      line = item.line,
      severity = item.severity,
      title = item.title,
      remediation = item.remediation,
    }
  end
  return findings
end

local function finding_dedup_key(repo, finding)
  local seed = table.concat({
    tostring(repo),
    tostring(finding.file),
    tostring(finding.line),
    tostring(finding.severity),
  }, "|")
  local readable = table.concat({
    "chrono-security",
    strings.sanitize_key(repo, 120),
    strings.sanitize_key(finding.file, 160),
    tostring(finding.line),
    strings.decimal_checksum(seed),
  }, "/")
  return readable:sub(1, limits.dedup_key)
end

local function issue_body(finding, dedup_key)
  return table.concat({
    "Automated security finding from the fkst company security department.",
    "",
    "- **Severity:** " .. tostring(finding.severity),
    "- **Location:** `" .. tostring(finding.file) .. ":" .. tostring(finding.line) .. "`",
    "",
    "**Finding:** " .. tostring(finding.title),
    "",
    "**Suggested remediation:** " .. tostring(finding.remediation),
    "",
    "<!-- fkst:chrono-security:finding:v1 " .. dedup_key .. " -->",
  }, "\n")
end

-- Map a validated finding to a github-proxy `issue-create.v1` request. Every issue
-- carries the umbrella + department labels so the pod-liveness gate and the in-pod
-- routing both work.
local function issue_create_request(repo, finding)
  if not strings.is_bounded_string(repo, limits.repo) then
    error("chrono-security: invalid-repo: repo out of bounds")
  end
  if not valid_finding(finding) then
    error("chrono-security: invalid-finding: finding failed validation")
  end
  local dedup_key = finding_dedup_key(repo, finding)
  local title = ("Security: " .. tostring(finding.file) .. ":" .. tostring(finding.line)
    .. " " .. tostring(finding.title)):sub(1, limits.title)
  local body = issue_body(finding, dedup_key)
  local source_ref_ref = (tostring(repo) .. "#" .. tostring(finding.file) .. ":"
    .. tostring(finding.line) .. "#chrono-security"):sub(1, limits.source_ref_ref)
  if not strings.is_bounded_string(body, limits.body) then
    error("chrono-security: invalid-body: body out of bounds")
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
      ref = source_ref_ref,
    },
  }
end

M.tick_queue = tick_queue
M.department_labels = department_labels
M.poll_interval = poll_interval
M.max_findings = max_findings
M.build_prompt = build_prompt
M.valid_finding = valid_finding
M.parse_findings = parse_findings
M.dedup_key = finding_dedup_key
M.issue_create_request = issue_create_request

return M
