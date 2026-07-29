local caps = require("import_issue_caps")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local env = require("workflow.env")

local spec = {
  consumes = { "github-proxy.github_issue_changed", "github-proxy.github_issue_observed" },
  produces = {
    "radar_config_imported",
    "radar_signal_imported",
    "radar_brief_created",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_create_request",
  },
  fanout = { "github-proxy.github_issue_changed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function status_for(item)
  if item.kind == "radar-config" then
    return "radar config imported"
  end
  if item.kind == "radar-signal" then
    return "radar signal imported"
  end
  if item.calendar_ref ~= nil then
    return "radar schedule issue requested"
  end
  return "radar brief created"
end

local function issue_source_ref(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return nil
  end
  local ref = source_ref.ref or source_ref.reference
  if type(ref) ~= "string" or ref:match("^[^#]+#issue/%d+$") == nil then
    return nil
  end
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function fetched_issue(github, payload)
  if type(payload) ~= "table" or payload.body ~= nil or payload.controls ~= nil then
    return nil
  end
  local source_ref = issue_source_ref(payload.source_ref)
  if source_ref == nil then
    return nil
  end
  local ok, issue = pcall(function()
    return github.read_issue(source_ref, {
      updated_at = payload.updated_at,
      consumer = "marketing-radar",
    })
  end)
  if not ok then
    log.warn("marketing-radar dept=import_issue tag=FETCH_SKIP reason=github issue read failed")
    return nil
  end
  return issue
end

local function observed_event(event)
  return tostring(event and event.queue or "") == "github-proxy.github_issue_observed"
end

local function classify_event(payload, current_issue)
  local opts = {
    issue_body = nil,
    issue_labels = nil,
  }
  if current_issue ~= nil then
    opts.issue_body = current_issue.body
    opts.issue_labels = current_issue.labels
  end
  return caps.classify_issue(payload, opts)
end

local function raise_radar_run_outputs(item)
  raise("radar_brief_created", caps.radar_brief_created(item))
  if item.calendar_ref ~= nil then
    raise("github-proxy.github_issue_create_request", caps.schedule_issue_request(item))
  else
    raise("github-proxy.github_issue_create_request", caps.weekly_content_issue_request(item))
  end
end

local function make_department(ports)
  local handles = ports or {}
  local github = handles.github

  local function act(event)
    local payload = event.payload or {}
    local current_issue = nil
    if github ~= nil then
      current_issue = fetched_issue(github, payload)
    end

    local item, why = classify_event(payload, current_issue)
    if item == nil then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=" .. tostring(why))
      return
    end
    if observed_event(event) and item.kind ~= "radar-run" then
      log.info("marketing-radar dept=import_issue tag=SKIP reason=observed non-run")
      return
    end

    if item.kind == "radar-config" then
      raise("radar_config_imported", caps.radar_config_imported(item))
    elseif item.kind == "radar-signal" then
      raise("radar_signal_imported", caps.radar_signal_imported(item))
    elseif item.kind == "radar-run" then
      raise_radar_run_outputs(item)
    else
      error("marketing-radar: unknown-kind: " .. tostring(item.kind), 0)
    end

    raise("github-proxy.github_issue_comment_request", caps.status_comment(item, status_for(item)))
  end

  return saga.department(spec, {
    done = done,
    act = act,
    name = "import_issue",
  })
end

local function read_env_command(name)
  if name ~= "FKST_GITHUB_BOT_LOGIN"
    and name ~= "FKST_DEVLOOP_MANAGED_BOT_LOGINS"
    and name ~= "FKST_GITHUB_AUTHORIZED_LOGINS" then
    error("marketing-radar: invalid-env-name: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local read_env = env.read_env(read_env_command, { propagate_exec_errors = true })
local github_author_policy_env = {
  bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  extra_login_envs = {
    "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
    "FKST_GITHUB_AUTHORIZED_LOGINS",
  },
}

return ports_lib.install(
  make_department,
  ports_lib.github_author_options(read_env, "marketing-radar", github_author_policy_env)
)
