local W = {}
local registry = require("workflow_internal.registry")
local pr_review_replay_facts = require("devloop.restart.pr_review_replay_facts")
local devloop_prompts = require("devloop.prompts")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local restart_metadata = require("devloop.restart_metadata")
local workflow_ports = require("devloop.adapters.workflow_ports")

local package_name = "github-devloop-pr"

local function index_module(base)
  return base .. ".index"
end

local function pr_entry_name(index_entry)
  if type(index_entry) == "string" then
    return index_entry
  end
  return index_entry.module
end

local function load_entries(base, index)
  local entries = {}
  for _, index_entry in ipairs(index) do
    local module_name = pr_entry_name(index_entry)
    table.insert(entries, require(base .. "." .. module_name))
  end
  return entries
end

local function pr_registry_map(base, key_field, M)
  local index = require(index_module(base))
  local entries = load_entries(base, index)
  return registry.build_indexed_map(index_module(base), index, entries, key_field, M, nil, package_name)
end

function W.restart_policy(runtime)
  local policy = {
    _max_blocking_gap_len = devloop_base._max_blocking_gap_len,
    _max_dedup_len = devloop_base._max_dedup_len,
    _max_key_len = devloop_base._max_key_len,
    _strip_latest_fix_version_suffix = restart_metadata._strip_latest_fix_version_suffix,
    decompose_package_queue = function() return "github-devloop-decompose.devloop_decompose" end,
    is_state = restart_metadata.is_state,
    restart_consumer_sources = {
      "packages/github-devloop-pr/departments/observe_pr/main.lua",
      "packages/github-devloop-pr/departments/merge/main.lua",
      "packages/github-devloop-pr/departments/merge_queue/main.lua",
    },
    restart_lifecycle_states = {
      "pr-open", "reviewing", "fixing", "review-meta", "merge-ready",
      "merging", "blocked", "closed-unmerged", "merged",
    },
    restart_package_name = package_name,
    restart_source_root = "packages/github-devloop-pr/",
    stage_rank = restart_metadata.stage_rank,
    timeout_lineage_matches_current = devloop_state.timeout_lineage_matches_current,
    version_fix_round = restart_metadata.version_fix_round,
    version_loop_round = restart_metadata.version_loop_round,
    version_timeout_round = restart_metadata.version_timeout_round,
  }
  local transitions_base = "core.restart.transitions"
  local transitions_index = require(index_module(transitions_base))
  local replay_ops = pr_review_replay_facts.new(policy)
  for key, value in pairs(replay_ops) do policy[key] = value end
  replay_ops.decompose_package_queue = policy.decompose_package_queue
  replay_ops.stage_rank = policy.stage_rank
  replay_ops.version_fix_round = policy.version_fix_round
  local restart = require("devloop.restart").new({
    _max_blocking_gap_len = policy._max_blocking_gap_len,
    _max_dedup_len = policy._max_dedup_len,
    _max_key_len = policy._max_key_len,
    ops = replay_ops,
    restart_consumer_sources = policy.restart_consumer_sources,
    restart_package_name = policy.restart_package_name,
    marker_fields = pr_registry_map("core.restart.marker_fields", "family", policy),
    replay_payload_fields = pr_registry_map("core.restart.required_replay_payload_fields", "state", policy),
    transitions_index = transitions_index,
    transitions = load_entries(transitions_base, transitions_index),
    transitions_label = index_module(transitions_base),
  })
  for key, value in pairs(restart) do policy[key] = value end
  policy.actionable_epoch_resolve = function(...)
    return require("devloop.restart_actionable_epoch").actionable_epoch_resolve(policy, ...)
  end
  local responsibility = require("devloop.restart_responsibility_contract")
  policy.restart_responsibility_inventory_errors = function(...)
    return responsibility.restart_responsibility_inventory_errors(policy, ...)
  end
  policy.strict_restart_responsibility_contract_errors = function(...)
    return responsibility.strict_restart_responsibility_contract_errors(policy, ...)
  end
  local restart_liveness = require("devloop.liveness").with_restart_policy({
    runtime_provenance = {
      proposal_id = "github-devloop/issue/provenance/repo/1",
      version = "restart-liveness-provenance",
      marker_created_at = "2026-06-03T00:00:00Z",
    },
    durable_hold_resolver = runtime.durable_hold_resolver,
  })
  restart_liveness.workflow_ports = workflow_ports.from_devloop(policy)
  require("workflow_internal.restart_liveness_contract").install(policy, restart_liveness)
  return policy
end

function W.liveness(policy, runtime)
  local producers = pr_registry_map("core.restart.liveness_signal_producers", "family", policy)
  return {
    liveness_signal_producers = producers,
    replayer = {
      replay_from_table_classified = runtime.replay_from_table_classified,
    },
  }
end

function W.prompts()
  return devloop_prompts.new({
    prompts = {
      fix = require("prompts.fix"),
      fix_reflection = require("prompts.fix_reflection"),
      review_meta = require("prompts.review_meta"),
    },
  }, {
    fix = true,
    review_meta = true,
    review_meta_parser = true,
  })
end

return W
