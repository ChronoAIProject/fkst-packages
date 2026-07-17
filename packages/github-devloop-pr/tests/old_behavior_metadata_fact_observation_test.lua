local ra = require("tests.receiver_activation_observation_helpers")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local testing = require("testkit_internal.testing")
local review_pr_department = require("departments.review_pr.main")
local review_loop_department = require("departments.review_loop.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local BRANCH = "devloop-owner-repo-42-01HY"
local HEAD_SHA = "def456"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local LATER_VERSION = VERSION .. "/review-meta/1"

local SITES = {
  current_entity = {
    path = "packages/github-devloop-pr/departments/review_pr/main.lua",
    symbol = "pipeline",
    ordinal = "devloop.entity.current_entity_state",
  },
  review_loop = {
    path = "packages/github-devloop-pr/departments/review_loop/main.lua",
    symbol = "reviewing_segment_transition_status",
    ordinal = "reviewing-segment-state-read",
  },
  sink_catalog = {
    path = "packages/github-devloop-pr/core/restart/sink_inventory.lua",
    symbol = "records",
    ordinal = "sink-inventory",
  },
  grantless = {
    path = "packages/github-devloop-pr/core/restart/sink_inventory.lua",
    symbol = "records",
    ordinal = "grantless-classified-sinks",
  },
}

local function sorted_keys(set)
  local values = json_array()
  for key, enabled in pairs(set or {}) do if enabled == true then table.insert(values, key) end end
  table.sort(values)
  return values
end

local function base_record(observation_id, site, boundary, kind, target, current_fact, outcome, evidence)
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = observation_id,
    owner = "github-devloop-pr",
    site = copy_value(site),
    boundary = boundary,
    typed_intent = {
      kind = kind,
      source_state = JSON_NULL,
      source_boundary = "source-module",
      target = target,
      cause_schema_id = "restart-metadata-observation.v1",
      generation_epoch = { snapshot_basis = "OLD source module at test dispatch" },
      lineage = { owner = "github-devloop-pr", observation_id = observation_id },
    },
    old_inputs = {
      current_fact = copy_value(current_fact),
      caller_from_states = json_array(),
      incoming_version = "source-snapshot:v1",
      target_version = JSON_NULL,
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = outcome.status,
      reason_code = outcome.reason_code,
      cas_outcome = "not-applicable",
      emitted_effects = json_array(),
      observable_writes = copy_value(outcome.observable_writes or json_array()),
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = copy_value(evidence),
  }
end

local function catalog_rows(records, grantless_only)
  local rows = json_array()
  for _, record in ipairs(records or {}) do
    if not grantless_only or tostring(record.authority_class):match("^grantless%-") then
      table.insert(rows, {
        effect_id = record.id,
        department = record.callsite.department,
        sink_kind = record.effect_kind,
        authority_class = record.authority_class,
        family = record.dedup_marker_family,
      })
    end
  end
  table.sort(rows, function(left, right) return canonical_json(left) < canonical_json(right) end)
  return rows
end

local function trusted(body, id)
  return { id = id, body = body, author_login = "fkst-test-bot", created_at = "2026-06-03T01:00:00Z" }
end

local function state_comments()
  return json_array({
    trusted(m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, "dev"), "IC_origin"),
    trusted(core.state_marker(PROPOSAL_ID, "reviewing", VERSION), "IC_reviewing"),
    trusted(core.state_marker(PROPOSAL_ID, "merged", LATER_VERSION), "IC_merged"),
    trusted(core.state_marker("github-devloop/issue/owner/repo/99", "blocked", LATER_VERSION .. "/loop/9"), "IC_foreign"),
    { id = "IC_untrusted", body = core.state_marker(PROPOSAL_ID, "blocked", LATER_VERSION .. "/loop/10"),
      author_login = "untrusted-user", created_at = "2026-06-03T01:02:00Z" },
  })
end

local function fake_pr_ports(comments)
  local ports = ra.fake_ports()
  function ports.github.pr_cli_view(repo, number, fields, timeout)
    ra.record_write(ports.github_model, "pr_view", { repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = require("tests.entity_read_mock_helpers").pr_view_stdout({
      repo = REPO,
      number = PR_NUMBER,
      comments = comments,
      head = BRANCH,
      head_sha = HEAD_SHA,
      base_branch = "dev",
      state = "OPEN",
    }), stderr = "", exit_code = 0 }
  end
  return ports
end

local function fact_shape(call)
  return {
    marker_family = "github-devloop:state:v1",
    trusted_author_only = true,
    proposal_id = call.proposal_id,
    source_comment_count = call.comment_count,
    candidate_fields = json_array({ "marker_created_at", "stage_rank", "state", "version" }),
    version_basis = json_array({ "transition_version.compare", "stage_rank", "marker_order_key" }),
    state_value_space = sorted_keys(devloop_state.lifecycle_state_set()),
  }
end

local function capture_review_pr_fact()
  h.mock_bot_env()
  local comments = state_comments()
  local ports = fake_pr_ports(comments)
  local restorations = {}
  local calls = json_array()
  local original = entity_lib.current_entity_state
  ra.replace(entity_lib, "current_entity_state", function(actual_comments, proposal_id)
    local fact = original(actual_comments, proposal_id)
    table.insert(calls, { proposal_id = proposal_id, comment_count = #actual_comments, derived = copy_value(fact) })
    return fact
  end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(review_pr_department, ports, core)
  local event = { queue = "devloop_reviewing", ts = "2026-06-03T02:03:04Z", payload = h.reviewing({
    version = VERSION,
    pr_number = PR_NUMBER,
    source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
  }) }
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(result, 0) end
  t.eq(#calls, 1, "real review_pr dispatch performs one current-entity-state read")
  t.eq(#result.raises, 0, "advanced-state fixture ends after the current-state read")
  local call = calls[1]
  t.eq(call.derived.state, "merged")
  return base_record(
    "fact-current-entity-state-trusted-marker-selection", SITES.current_entity,
    "owner_observation_fact", "authoritative_current_entity_state_read", "current PR lifecycle fact",
    fact_shape(call),
    { status = "read", reason_code = "trusted-proposal-state-marker-selected",
      observable_writes = { derived_fact = call.derived } },
    json_array({
      { kind = "runtime-fake-dispatch", ref = "packages/github-devloop-pr/departments/review_pr/main.lua:88" },
      { kind = "source-state-reader", ref = "libraries/devloop/entity.lua:54-56" },
    })
  )
end

local function capture_review_loop_fact()
  h.mock_bot_env()
  local comments = state_comments()
  local ports = fake_pr_ports(comments)
  local restorations = {}
  local calls = json_array()
  local original = entity_lib.current_entity_state
  ra.replace(entity_lib, "current_entity_state", function(actual_comments, proposal_id)
    local fact = original(actual_comments, proposal_id)
    table.insert(calls, { proposal_id = proposal_id, comment_count = #actual_comments, derived = copy_value(fact) })
    return fact
  end, restorations)
  ra.replace(m_claims, "verify_pr_review_issue_claim", function() return true end, restorations)
  ra.replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local department = ra.make_department(review_loop_department, ports, core)
  local review_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION, HEAD_SHA)
  local event = { queue = "consensus.consensus_converge", ts = "2026-06-03T02:03:04Z", payload = h.review_unresolved({
    proposal_id = review_id,
    source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
    dedup_key = "consensus:" .. review_id .. "/review",
    round = 0,
  }) }
  local ok, result = pcall(testing.run_fake, department, event)
  ra.restore_all(restorations)
  if not ok then error(result, 0) end
  t.eq(#calls, 1, "real review_loop dispatch performs one reviewing-segment state read")
  t.eq(#result.raises, 0, "advanced-state fixture ends after segment-state classification")
  local call = calls[1]
  t.eq(call.derived.state, "merged")
  local current_fact = fact_shape(call)
  current_fact.review_version_basis = json_array({ "safe_version_segment equality", "stage_rank after reviewing" })
  current_fact.transition_value_space = json_array({ "apply", "pending", "stale" })
  return base_record(
    "fact-review-loop-state-safe-version-segment", SITES.review_loop,
    "owner_observation_fact", "reviewing_segment_current_state_read", "review-loop state fact",
    current_fact,
    { status = "read", reason_code = "advanced-state-classified-stale",
      observable_writes = { derived_fact = call.derived, transition = "stale" } },
    json_array({
      { kind = "runtime-fake-dispatch", ref = "packages/github-devloop-pr/departments/review_loop/main.lua:42-55" },
      { kind = "runtime-state-read", ref = "packages/github-devloop-pr/departments/review_loop/main.lua:115" },
    })
  )
end

local function capture_records()
  local records = json_array({ capture_review_pr_fact(), capture_review_loop_fact() })
  local sink_inventory = require("core.restart.sink_inventory")
  local all_sinks = catalog_rows(sink_inventory, false)
  table.insert(records, base_record(
    "effect-sink-catalog-pr-exact-set", SITES.sink_catalog, "effect_sink", "effect_sink_catalog",
    "declared sink set", { record_count = #all_sinks },
    { status = "observed", reason_code = "exact-declared-sink-set", observable_writes = all_sinks },
    json_array({ { kind = "source-module-export", ref = SITES.sink_catalog.path } })
  ))
  local grantless = catalog_rows(sink_inventory, true)
  table.insert(records, base_record(
    "grantless-sink-pr-exact-set", SITES.grantless, "observation_fact_reader", "grantless_sink_catalog_read",
    "grantless-classified sink set", { authority_class_prefix = "grantless-", record_count = #grantless },
    { status = "read", reason_code = "exact-grantless-classified-sink-set", observable_writes = grantless },
    json_array({ { kind = "source-module-filter", ref = SITES.grantless.path .. ":authority_class" } })
  ))
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

local function committed_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local selected = json_array()
  local observation_ids = {
    ["effect-sink-catalog-pr-exact-set"] = true,
    ["fact-current-entity-state-trusted-marker-selection"] = true,
    ["fact-review-loop-state-safe-version-segment"] = true,
    ["grantless-sink-pr-exact-set"] = true,
  }
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if observation_ids[record.observation_id] then table.insert(selected, record) end
  end
  table.sort(selected, function(left, right) return left.observation_id < right.observation_id end)
  return selected
end

return {
  test_metadata_and_fact_old_observations_are_source_bound_deterministic_and_bidirectional = function()
    local first = capture_records()
    local second = capture_records()
    local repeat_difference = first_difference(second, first, "old_behavior_observations[metadata-pr][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second github-devloop-pr metadata capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end
    local expected = committed_records()
    local difference = first_difference(first, expected, "old_behavior_observations[metadata-pr]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error("source-bound github-devloop-pr metadata observation differs at "
        .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0)
    end
  end,
}
