local error_facts = require("contract.error_facts")
local devloop_base = require("devloop.base")
local core, saga = require("core"), require("workflow.saga")
local common = require("departments.observability.common")
local avm_scoreboard = require("departments.observability.avm_scoreboard")
local census = require("departments.observability.census")
local dashboard = require("departments.observability.dashboard")
local failure_triage_cap = require("failure_triage_cap")
local output_obligation_resolution = require("departments.observability.output_obligation_resolution")
local ports = require("forge.ports")
local queue_starvation = require("devloop.queue_starvation")
local reaper = require("departments.observability.reaper")
local terminal_retirement = require("departments.observability.terminal_retirement")
local topology = require("departments.observability.topology")
local devloop_logging = require("devloop.logging")
local queue = require("devloop.queue")

local spec = {
  consumes = {
    "devloop_observe_tick",
    "github-devloop-pr.restart_transition_anomaly",
    "github-devloop.restart_transition_anomaly",
  },
  ephemeral = {
    "github-devloop-pr.restart_transition_anomaly",
    "github-devloop.restart_transition_anomaly",
  },
  produces = {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_pr_comment_request",
    "github-proxy.github_issue_create_request",
  },
  graph_json = true,
  retry = false,
  stall_window = "2m",
}

local function ingest_restart_transition_anomaly(event)
  local anomaly = event.payload or {}
  if anomaly.schema ~= "restart-transition-anomaly.v1" then
    error("github-devloop: restart-anomaly-schema-invalid: ops received an invalid restart transition anomaly schema")
  end
  local entity = type(anomaly.entity) == "table" and anomaly.entity or {}
  log.warn("github-devloop dept=observability tag=RESTART_TRANSITION_ANOMALY"
    .. " owner=" .. tostring(anomaly.owner or "unknown")
    .. " entity_kind=" .. tostring(entity.kind or "unknown")
    .. " repo=" .. tostring(entity.repo or "unknown")
    .. " number=" .. tostring(entity.number or "unknown")
    .. " disposition=" .. tostring(anomaly.disposition or "unknown")
    .. " reason_code=" .. tostring(anomaly.reason_code or "unknown"))
end

common.install_common(core)
avm_scoreboard.install_avm_scoreboard(core)
census.install_census(core)
reaper.install_reaper(core)
dashboard.install_dashboard(core)

function core.observability_topology_mermaid()
  if type(graph_json) ~= "function" then
    return nil
  end
  local ok, result = pcall(function()
    local decoded = json.decode(graph_json())
    return topology.render_mermaid(decoded)
  end)
  if not ok then
    local reason = devloop_base._one_line and error_facts.one_line(result) or tostring(result or "")
    log.warn("github-devloop dept=observability tag=TOPOLOGY_UNAVAILABLE reason=" .. tostring(reason))
    return nil
  end
  return result
end

local function partial_observation_reason(observed)
  local deferred = type(observed) == "table" and observed.observability_deferred or nil
  if type(deferred) ~= "table" then
    return nil
  end
  return tostring(deferred.reason or "unknown")
end

local function log_control_skipped(action, reason)
  log.info("github-devloop dept=observability tag=OBSERVE_CONTROL_SKIPPED"
    .. " action=" .. tostring(action)
    .. " reason=" .. tostring(reason or "partial-observations"))
end

local function skipped_control_result(reason)
  return {
    action = "skipped",
    reason = tostring(reason or "partial-observations"),
  }
end

function core.observe_devloop_entities(event, github)
  common.require_observe_bot(core)
  local repo = common.require_observe_repo(core)
  local limits = core.observability_limits()
  local deadline = core.observability_deadline(now(), limits)
  local observed = core.collect_observability_entities(event, repo, limits, deadline)
  local recent_merged_prs = core.collect_recent_merged_prs(repo, limits, deadline)
  local recent_merged_issues = core.collect_recent_merged_issues(repo, limits, deadline)

  local partial_reason = partial_observation_reason(observed)
  local queue_starvation_result = skipped_control_result("partial-observations")
  local conflict_hotspot = { facts = 0, hotspots = 0, raised = 0, action = "skipped", reason = "partial-observations" }
  for _, entity in ipairs(observed.list or {}) do
    local retirement = terminal_retirement.reconcile(
      github,
      repo,
      entity,
      limits,
      deadline
    )
    if retirement ~= nil then
      devloop_logging.log_raise(
        "terminal_retirement",
        retirement.fact.proposal_id,
        retirement.queue,
        retirement.payload
      )
    end
    local resolution = output_obligation_resolution.reconcile(
      core,
      github,
      repo,
      entity,
      limits,
      deadline
    )
    if resolution ~= nil then
      devloop_logging.log_raise(
        "output_obligation_resolution",
        resolution.fact.proposal_id,
        resolution.queue,
        resolution.payload
      )
    end
  end
  if partial_reason == nil then
    core.reap_orphan_prs(repo, observed.list)
    queue_starvation_result = queue_starvation.observe_queue_starvation(nil, repo, observed.list, limits, deadline, observed.now_seconds)
    if recent_merged_issues ~= nil then
      for _, entity in ipairs(observed.list or {}) do
        for _, raised in ipairs(failure_triage_cap.blocked_obligation_patrol_once(entity, observed.list, recent_merged_issues)) do
          devloop_logging.log_raise("blocked_obligation_patrol", raised.fact.proposal_id, raised.queue, raised.payload)
        end
      end
    else
      log_control_skipped("blocked-obligation-patrol", "recent-merged-issues-deferred")
    end
    conflict_hotspot = core.observe_conflict_hotspots(repo, core.observability_call_timeout(limits, deadline))
  else
    log_control_skipped("snapshot-control", "partial-observations")
  end
  local rendered_dashboard = core.render_observability_dashboard({
    entities = observed.list,
    counts = observed.counts,
    stalls = observed.stalls,
    state_gap_report = observed.state_gap_report,
    observability_deferred = observed.observability_deferred,
    recent_merged_prs = recent_merged_prs,
    recent_merged_issues = recent_merged_issues,
    now_seconds = observed.now_seconds,
    topology_mermaid = core.observability_topology_mermaid(),
  })
  core.publish_observability_dashboard(repo, rendered_dashboard, limits, deadline)

  return {
    entity_count = #observed.list,
    counts = observed.counts,
    queue_starvation = queue_starvation_result,
    conflict_hotspot = conflict_hotspot,
    state_gap_report = observed.state_gap_report,
    dashboard_hash = rendered_dashboard.hash,
  }
end

local function make_department(handles)
  local department = saga.department(spec, { done = function() return false end, act = function(event)
    queue.dispatch_consumed_queue("observability", spec, event, {
      devloop_observe_tick = function(tick)
        devloop_logging.log_entry("observability", tick, "github-devloop/observability", "tick")
        core.observe_devloop_entities(tick, handles.github)
      end,
      ["github-devloop-pr.restart_transition_anomaly"] = ingest_restart_transition_anomaly,
      ["github-devloop.restart_transition_anomaly"] = ingest_restart_transition_anomaly,
    }, "github-devloop-ops")
  end, wrap = devloop_logging.wrap_pipeline_failure, name = "observability" })
  department.spec.graph_json = true
  department.ports = handles
  return department
end

return ports.install(make_department, ports.github_author_options(
  devloop_base.read_env,
  "github-devloop-ops.observability",
  { bot_login_env = "FKST_GITHUB_BOT_LOGIN" }
))
