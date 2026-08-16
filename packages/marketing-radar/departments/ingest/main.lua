local core = require("core")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = {
    "github-proxy.github_issue_create_request",
    "radar_weekly_content_generated",
  },
  fanout = { "github-proxy.github_entity_changed" },
  retry = {},
  stall_window = "30s",
}

local function is_issue_event(event)
  local queue = tostring(event and event.queue or "")
  if queue ~= "github-proxy.github_entity_changed" then
    error("marketing-radar: unknown-queue: " .. queue)
  end
  local payload = event.payload or {}
  return payload.type == "issue"
end

local function source_ref_from_event(event)
  local payload = event.payload or {}
  local source_ref = payload.source_ref
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" or type(source_ref.ref) ~= "string" then
    error("marketing-radar: missing-source-ref: github_entity_changed issue event missing source_ref")
  end
  return source_ref
end

local function read_issue(github, source_ref, consumer)
  local ok, issue_or_err = pcall(function()
    return github.read_issue(source_ref, {
      force_fresh = true,
      timeout = 30,
      consumer = consumer,
    })
  end)
  if not ok then
    error("marketing-radar: source-read-failed: " .. tostring(issue_or_err), 0)
  end
  if type(issue_or_err) ~= "table" then
    error("marketing-radar: source-read-malformed: GitHub read_issue returned non-table", 0)
  end
  return issue_or_err
end

local function make_department(ports)
  ports = ports or {}
  local github = ports.github
  if type(github) ~= "table" then
    error("marketing-radar: github-port-unavailable: GitHub port is required")
  end

  local function ingest_done(event)
    return not is_issue_event(event)
  end

  local function act_ingest(event)
    local run_source_ref = source_ref_from_event(event)
    local run_issue = read_issue(github, run_source_ref, "marketing-radar.run")
    local parsed = core.parse_radar_run_contract(run_issue.body)
    if parsed == nil then
      return
    end
    local config_issue = read_issue(github, parsed.config_source_ref, "marketing-radar.config")
    local signal_issue = read_issue(github, parsed.signal_source_ref, "marketing-radar.signal")
    local outputs = core.build_weekly_content_outputs(run_issue, config_issue, signal_issue)
    if outputs == nil then
      return
    end
    raise("github-proxy.github_issue_create_request", outputs.request)
    raise("radar_weekly_content_generated", outputs.receipt)
  end

  return saga.department(spec, {
    done = ingest_done,
    act = act_ingest,
    name = "ingest",
  })
end

return ports_lib.install(make_department, {
  trusted_author_policy = require("forge.github.content_filter").test_disabled_author_policy(),
})
