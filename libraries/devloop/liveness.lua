local S = {}
local contract_time = require("contract.time")
local devloop_state = require("devloop.state")
local workflow_ports = require("devloop.adapters.workflow_ports")

local function copy_map(map)
  local out = {}
  for key, value in pairs(map or {}) do
    if type(value) == "table" then
      out[key] = copy_map(value)
    else
      out[key] = value
    end
  end
  return out
end

local function devloop_liveness_policy()
  return {
    liveness_resolver_families = {
      ["converge-round"] = {
        ["converge-round"] = true,
      },
      ["dependency-hold"] = {
        ["dependency-wait"] = true,
        ["dependency-cycle"] = true,
        ["dependency-unresolvable"] = true,
      },
      ["merge-gate-wait"] = {
        ["merge-gate-wait"] = true,
      },
      ["review-converge-round"] = {
        ["review-converge-round"] = true,
      },
      ["child-state"] = {
        state = true,
      },
    },
    allowed_signal_surfaces = {
      ["issue-comment-stream"] = true,
      ["pr-comment-stream"] = true,
    },
    signal_max_age_optional_resolvers = {},
  }
end

local function devloop_restart_liveness_policy()
  return {
    codex_run = {
      primitive = "fkst.codex_runs",
      status = "running",
      on_error = "defer",
      indeterminate_timeout = "row-budget",
    },
    child_workflow_wait = {
      live_marker = "state:v1",
      delegation_marker = "pr-delegation:v1",
      signal_family = "state",
      signal_resolver = "child-state",
      surface = "pr-comment-stream",
    },
  }
end

function S.policy()
  return copy_map(devloop_liveness_policy())
end

function S.restart_policy()
  return copy_map(devloop_restart_liveness_policy())
end

function S.with_restart_policy(resolved)
  local out = copy_map(resolved or {})
  local policy = devloop_restart_liveness_policy()
  for key, value in pairs(policy) do
    out[key] = copy_map(value)
  end
  return out
end

function S.stall_suspect_age_minutes(version, now_seconds)
  local marker_updated_at = devloop_state.version_updated_at(version)
  if marker_updated_at == "" then
    return nil
  end
  local marker_seconds = contract_time.iso_timestamp_epoch_seconds(marker_updated_at)
  local current_seconds = tonumber(now_seconds)
  if marker_seconds == nil or current_seconds == nil then
    return nil
  end
  local age_seconds = current_seconds - marker_seconds
  if age_seconds < 0 then
    return nil
  end
  return math.floor(age_seconds / 60)
end

function S.new(policy, resolved)
  assert(type(policy) == "table", "devloop.liveness: missing restart policy")
  local config = devloop_liveness_policy()
  for key, value in pairs(resolved or {}) do
    config[key] = value
  end
  config.restart_package_name = policy.restart_package_name
  config.restart_source_root = policy.restart_source_root
  local shared = require("workflow_internal.liveness.shared").install(policy, config)
  require("workflow_internal.liveness.contract").install(policy, shared, {
    workflow_ports = workflow_ports.from_devloop(policy),
    pr_recovery = {
      allowed = {
        not_mergeable = {
          to_state = "fixing",
          queue = "devloop_fixing",
        },
      },
    },
  })
  for key, value in pairs(require("devloop.liveness.signal").new(policy, shared)) do
    policy[key] = value
  end
  for key, value in pairs(require("devloop.liveness.timeout").new(policy, shared, {
    replayer = assert(config.replayer),
  })) do
    policy[key] = value
  end
  return policy
end

return S
