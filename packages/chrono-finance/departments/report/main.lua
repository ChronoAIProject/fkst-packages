local report = require("report_logic")
local codex = require("workflow.codex")
local saga = require("workflow.saga")
local env_port = require("env_port")

-- Thin cost/usage-report department: a `finance_tick` (from the package's cron
-- raiser) drives one bounded codex usage summary for the tick's window and files
-- exactly ONE deduped report issue through github-proxy's create seam. No gh/git;
-- the pure logic lives in `report_logic`, required directly (not via ambient core).
local spec = {
  consumes = { "finance_tick" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "10m",
  retry = false,
}

local codex_timeout_seconds = 30 * 60

local allowed_env = {
  FKST_GITHUB_REPO = true,
  FKST_FINANCE_BUDGET_MAX_UNITS = true,
}

local read_env = env_port.read_env(allowed_env)

local function trimmed(name)
  local value = read_env(name) or ""
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function repo_from_env()
  local repo = trimmed("FKST_GITHUB_REPO")
  if repo == "" then
    error("chrono-finance: missing-repo: missing FKST_GITHUB_REPO", 0)
  end
  return repo
end

local function budget_max()
  return tonumber(trimmed(report.budget_env_name()))
end

local function window_label(event)
  local payload = event.payload or {}
  local slot = payload.slot or payload.detected_at
  if type(slot) ~= "string" or slot == "" then
    error("chrono-finance: missing-window: finance tick has no slot/detected_at", 0)
  end
  -- Day bucket: the date portion of the ISO slot keeps one report per 24h window.
  return slot:sub(1, 10)
end

local function run_usage(repo, label)
  local opts = codex.judgment_codex_opts(report.build_prompt(repo, label), ".")
  opts.timeout = codex_timeout_seconds
  local result = spawn_codex_sync(opts)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local code = type(result) == "table" and tonumber(result.exit_code) or nil
    if code == 124 then
      error("chrono-finance: codex-timeout: codex timeout", 0)
    end
    error("chrono-finance: codex-nonzero: codex nonzero exit", 0)
  end
  return report.parse_usage(result.stdout)
end

local function report_done(_event)
  return false
end

local function report_act(event)
  local repo = repo_from_env()
  local label = window_label(event)
  local usage = run_usage(repo, label)
  raise("github-proxy.github_issue_create_request", report.report_issue_request(repo, usage, label, budget_max()))
end

return saga.department(spec, {
  done = report_done,
  act = report_act,
  name = "report",
})
