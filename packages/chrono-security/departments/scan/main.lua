local scan = require("scan_logic")
local codex = require("workflow.codex")
local saga = require("workflow.saga")
local env_port = require("env_port")

-- Thin security-scan department: a `security_tick` (from the package's cron
-- raiser) drives one codex security scan of the local checkout, and every
-- validated finding is filed through github-proxy's create seam. No gh/git here;
-- the pure logic lives in `scan_logic`, required directly (not via ambient core).
local spec = {
  consumes = { "security_tick" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "10m",
  retry = false,
}

-- Match the engine's default codex wall-clock cap for long repository scans.
local codex_timeout_seconds = 60 * 60

local allowed_env = {
  FKST_GITHUB_REPO = true,
}

local read_env = env_port.read_env(allowed_env)

local function repo_from_env()
  local repo = read_env("FKST_GITHUB_REPO") or ""
  repo = repo:gsub("^%s+", ""):gsub("%s+$", "")
  if repo == "" then
    error("chrono-security: missing-repo: missing FKST_GITHUB_REPO", 0)
  end
  return repo
end

local function run_scan(repo, max_count)
  local opts = codex.judgment_codex_opts(scan.build_prompt(repo, max_count), ".")
  opts.timeout = codex_timeout_seconds
  local result = spawn_codex_sync(opts)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local code = type(result) == "table" and tonumber(result.exit_code) or nil
    if code == 124 then
      error("chrono-security: codex-timeout: codex timeout", 0)
    end
    error("chrono-security: codex-nonzero: codex nonzero exit", 0)
  end
  return scan.parse_findings(result.stdout)
end

local function scan_done(_event)
  return false
end

local function scan_act(_event)
  local repo = repo_from_env()
  local max_count = scan.max_findings()
  local findings = run_scan(repo, max_count)
  local filed = 0
  for _, finding in ipairs(findings) do
    if filed >= max_count then
      break
    end
    raise("github-proxy.github_issue_create_request", scan.issue_create_request(repo, finding))
    filed = filed + 1
  end
end

return saga.department(spec, {
  done = scan_done,
  act = scan_act,
  name = "scan",
})
