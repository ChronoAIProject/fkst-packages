local github_fake = require("forge.github_fake")
local github_factory = require("devloop.github_factory")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local testing = require("testkit_internal.testing")
local observe_issue_department = require("departments.observe_issue.main")

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
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local OLDER_VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local CURRENT_VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-04Z"

local SITES = {
  current_state = {
    path = "packages/github-devloop/departments/observe_issue/main.lua",
    symbol = "process_issue_event",
    ordinal = "devloop_state.current_state",
  },
  sink_catalog = {
    path = "packages/github-devloop/core/restart/sink_inventory.lua",
    symbol = "records",
    ordinal = "sink-inventory",
  },
  state_fields = {
    path = "packages/github-devloop/core/restart/marker_fields/state.lua",
    symbol = 'family = "state"',
    ordinal = "shared-row-export/state",
  },
  dependency_wait_fields = {
    path = "packages/github-devloop/core/restart/marker_fields/dependency_wait.lua",
    symbol = 'family = "dependency-wait"',
    ordinal = "shared-row-export/dependency-wait",
  },
  grantless = {
    path = "packages/github-devloop/core/restart/sink_inventory.lua",
    symbol = "records",
    ordinal = "grantless-classified-sinks",
  },
}

local function sorted_keys(set)
  local values = json_array()
  for key, enabled in pairs(set or {}) do
    if enabled == true then table.insert(values, key) end
  end
  table.sort(values)
  return values
end

local function base_record(observation_id, site, boundary, kind, target, current_fact, outcome, evidence)
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = observation_id,
    owner = "github-devloop",
    site = copy_value(site),
    boundary = boundary,
    typed_intent = {
      kind = kind,
      source_state = JSON_NULL,
      source_boundary = "source-module",
      target = target,
      cause_schema_id = "restart-metadata-observation.v1",
      generation_epoch = { snapshot_basis = "OLD source module at test dispatch" },
      lineage = { owner = "github-devloop", observation_id = observation_id },
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
  table.sort(rows, function(left, right)
    return canonical_json(left) < canonical_json(right)
  end)
  return rows
end

local function exported_fields(module)
  local fields = json_array()
  for key, value in pairs(module) do
    if key ~= "family" and value == true then table.insert(fields, key) end
  end
  table.sort(fields)
  return fields
end

local function trusted(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function capture_current_state_fact()
  h.mock_bot_env()
  local comments = json_array({
    trusted(core.state_marker(PROPOSAL_ID, "thinking", OLDER_VERSION), "2026-06-03T01:00:00Z"),
    trusted(core.state_marker(PROPOSAL_ID, "ready", CURRENT_VERSION), "2026-06-03T01:01:00Z"),
    trusted(core.state_marker("github-devloop/issue/owner/repo/99", "merged", CURRENT_VERSION .. "/loop/9")),
    {
      body = core.state_marker(PROPOSAL_ID, "blocked", CURRENT_VERSION .. "/loop/10"),
      author_login = "untrusted-user",
      created_at = "2026-06-03T01:02:00Z",
    },
  })
  local model = github_fake.model({ author_policy = { mode = "whitelist", logins = { "fkst-test-bot" } } })
  local github = github_fake.new(model)
  function github.issue_rest_view(repo, number, timeout)
    table.insert(model.writes, { kind = "issue_rest_view", repo = repo, number = number, timeout = timeout })
    local rest_comments = json_array()
    for _, comment in ipairs(comments) do
      table.insert(rest_comments, {
        id = comment.id,
        body = comment.body,
        user = { login = comment.author_login },
        created_at = comment.created_at,
      })
    end
    return {
      stdout = canonical_json({
        number = ISSUE_NUMBER,
        title = "Observe authoritative state fact",
        body = "Fact fixture",
        state = "open",
        created_at = "2026-06-03T01:00:00Z",
        updated_at = "2026-06-03T01:02:03Z",
        labels = json_array({ { name = "fkst-dev:enabled" }, { name = "fkst-dev:hold" } }),
        comments = rest_comments,
        assignees = json_array({ { login = "fkst-test-bot" } }),
        user = { login = "fkst-test-bot" },
      }),
      stderr = "",
      exit_code = 0,
    }
  end
  function github.issue_comments(repo, number, timeout)
    table.insert(model.writes, { kind = "issue_comments", repo = repo, number = number, timeout = timeout })
    return { stdout = '{"comments":[]}', stderr = "", exit_code = 0 }
  end
  function github.issue_view(repo, number, fields, timeout)
    table.insert(model.writes, { kind = "issue_view", repo = repo, number = number, fields = fields, timeout = timeout })
    return {
      stdout = entity_read_mocks.issue_view_stdout({
        repo = REPO,
        number = ISSUE_NUMBER,
        title = "Observe authoritative state fact",
        body = "Fact fixture",
        state = "OPEN",
        updated_at = "2026-06-03T01:02:03Z",
        labels = { "fkst-dev:enabled", "fkst-dev:hold" },
        comments = comments,
        assignees = { "fkst-test-bot" },
        author_login = "fkst-test-bot",
      }),
      stderr = "",
      exit_code = 0,
    }
  end
  local original_handle = github_factory.production_handle
  local original_fetch = github_proxy_entity_view.fetch_issue_view_state
  local original_current_state = devloop_state.current_state
  local calls = json_array()
  github_factory.production_handle = function() return github end
  github_proxy_entity_view.fetch_issue_view_state = function(repo, number, _, opts)
    return github.issue_view(repo, number, "number,title,body,state,updatedAt,labels,comments,assignees,author",
      opts and opts.timeout or 30)
  end
  devloop_state.current_state = function(actual_comments, proposal_id)
    local fact = original_current_state(actual_comments, proposal_id)
    table.insert(calls, {
      proposal_id = proposal_id,
      comment_count = #actual_comments,
      derived = copy_value(fact),
    })
    return fact
  end
  local event = {
    queue = "github-proxy.github_entity_changed",
    ts = "2026-06-03T01:02:03Z",
    payload = h.issue({
      number = ISSUE_NUMBER,
      updated_at = "2026-06-03T01:02:03Z",
      dedup_key = REPO .. "#issue#42@2026-06-03T01:02:03Z",
      source_ref = { kind = "external", ref = REPO .. "#issue/" .. ISSUE_NUMBER },
    }),
  }
  local ok, result = pcall(testing.run_fake, observe_issue_department, event)
  devloop_state.current_state = original_current_state
  github_proxy_entity_view.fetch_issue_view_state = original_fetch
  github_factory.production_handle = original_handle
  if not ok then error(result, 0) end
  t.eq(#calls, 1, "real observe_issue dispatch performs one authoritative current-state read")
  t.eq(#result.raises, 0, "held fixture ends after the current-state read")
  local call = calls[1]
  t.eq(call.derived.state, "ready")
  t.eq(call.derived.version, CURRENT_VERSION)
  return base_record(
    "fact-current-state-trusted-marker-selection",
    SITES.current_state,
    "owner_observation_fact",
    "authoritative_current_state_read",
    "current lifecycle fact",
    {
      marker_family = "github-devloop:state:v1",
      trusted_author_only = true,
      proposal_id = call.proposal_id,
      source_comment_count = call.comment_count,
      candidate_fields = json_array({ "marker_created_at", "stage_rank", "state", "version" }),
      version_basis = json_array({ "transition_version.compare", "stage_rank", "marker_order_key" }),
      state_value_space = sorted_keys(devloop_state.lifecycle_state_set()),
    },
    {
      status = "read",
      reason_code = "trusted-proposal-state-marker-selected",
      observable_writes = { derived_fact = call.derived },
    },
    json_array({
      { kind = "runtime-fake-dispatch", ref = "packages/github-devloop/departments/observe_issue/main.lua:602" },
      { kind = "source-state-reader", ref = "libraries/devloop/state.lua:300-331" },
    })
  )
end

local function capture_records()
  local records = json_array()
  table.insert(records, capture_current_state_fact())

  local sink_inventory = require("core.restart.sink_inventory")
  local all_sinks = catalog_rows(sink_inventory, false)
  table.insert(records, base_record(
    "effect-sink-catalog-gd-exact-set", SITES.sink_catalog, "effect_sink", "effect_sink_catalog",
    "declared sink set", { record_count = #all_sinks },
    { status = "observed", reason_code = "exact-declared-sink-set", observable_writes = all_sinks },
    json_array({ { kind = "source-module-export", ref = SITES.sink_catalog.path } })
  ))

  for _, spec in ipairs({
    { id = "shared-row-state-exact-fields", site = SITES.state_fields,
      module = require("core.restart.marker_fields.state"), family = "state" },
    { id = "shared-row-dependency-wait-exact-fields", site = SITES.dependency_wait_fields,
      module = require("core.restart.marker_fields.dependency_wait"), family = "dependency-wait" },
  }) do
    local fields = exported_fields(spec.module)
    t.eq(spec.module.family, spec.family)
    table.insert(records, base_record(
      spec.id, spec.site, "shared_row_export", "shared_marker_field_family_export", spec.family,
      { family = spec.module.family, exported_fields = fields },
      { status = "observed", reason_code = "exact-exported-field-set",
        observable_writes = { family = spec.module.family, fields = fields } },
      json_array({ { kind = "source-module-export", ref = spec.site.path } })
    ))
  end

  local grantless = catalog_rows(sink_inventory, true)
  table.insert(records, base_record(
    "grantless-sink-gd-exact-set", SITES.grantless, "observation_fact_reader", "grantless_sink_catalog_read",
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
    ["effect-sink-catalog-gd-exact-set"] = true,
    ["fact-current-state-trusted-marker-selection"] = true,
    ["grantless-sink-gd-exact-set"] = true,
    ["shared-row-dependency-wait-exact-fields"] = true,
    ["shared-row-state-exact-fields"] = true,
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
    local repeat_difference = first_difference(second, first, "old_behavior_observations[metadata-gd][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second github-devloop metadata capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end
    local expected = committed_records()
    local difference = first_difference(first, expected, "old_behavior_observations[metadata-gd]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error("source-bound github-devloop metadata observation differs at "
        .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0)
    end
  end,
}
