local config = require("devloop.config")
local context_bundle = require("devloop.context_bundle")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local m_builders = require("devloop.markers.builders")
local m_claims = require("devloop.claims")
local m_mq = require("devloop.merge_queue")
local substrate_pin = require("departments.implement.substrate_pin")
local transitions = require("departments.implement.transitions")
local worktree = require("departments.implement.worktree")
local entity_reads = require("tests.entity_read_mock_helpers")
local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local h = require("tests.devloop_helpers")
local obs = require("testkit_internal.old_behavior_observation_support")
local sinks = require("core.restart.sink_inventory")
local testing = require("testkit_internal.testing")
local workflow_codex = require("workflow_internal.codex")
local production = require("departments.implement.main")

local t = h.t
local core = h.core
local NULL = obs.JSON_NULL
local INVENTORY = "migration/restart-lifecycle.inventory.json"
local PROPOSAL = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local EQUAL_CURRENT = VERSION .. "/loop/01"
local EQUAL_INCOMING = VERSION .. "/loop/1"
local BLOCKED_VERSION = VERSION .. "/review-loop/3"
local SITE = {
  path = "packages/github-devloop/departments/implement/transitions.lua",
  symbol = "M.implementation_transition_status",
  ordinal = "implementation_transition_status:*->implementing",
}
local PREFIX = "writer:github-devloop:implement-enter/"
local START_EFFECTS = obs.json_array({
  "comment:issue:implementation-start",
  "label:issue:implementation-start",
})

local FIXTURES = obs.json_array({
  { name = "versioned-apply", dispatch = "versioned", transition = "apply", status = "apply",
    reason = "source-ready", cas = "applied", version = VERSION,
    views = { { state = "ready", version = VERSION }, { state = "ready", version = VERSION } },
    effects = START_EFFECTS },
  { name = "versioned-defer", dispatch = "versioned", transition = "pending", status = "defer",
    reason = "source-marker-not-visible", cas = "retry-pending(from-state marker not yet visible)",
    version = VERSION, views = { { state = "thinking", version = VERSION } },
    expected_error = "state-marker-pending", effects = obs.json_array() },
  { name = "versioned-skip-idempotent", dispatch = "versioned", transition = "idempotent",
    status = "skip-idempotent", reason = "already-at-implementing",
    cas = "skip-idempotent(already at to_state)", version = EQUAL_INCOMING,
    views = { { state = "ready", version = EQUAL_INCOMING },
      { state = "implementing", version = EQUAL_CURRENT } }, effects = obs.json_array() },
  { name = "versioned-skip-stale", dispatch = "versioned", transition = "stale",
    status = "skip-stale", reason = "state-advanced", cas = "skip-advanced-or-diverged",
    version = VERSION, views = { { state = "blocked", version = VERSION } }, effects = obs.json_array() },
  { name = "cyclic-apply", dispatch = "cyclic", transition = "apply", status = "apply",
    reason = "operator-reentry", cas = "applied", version = VERSION, retry = 2, blocked_reentry = true,
    views = { { state = "blocked", version = BLOCKED_VERSION },
      { state = "blocked", version = BLOCKED_VERSION } }, effects = START_EFFECTS },
})

local function replace(target, key, value, undo)
  table.insert(undo, { target = target, key = key, value = target[key] })
  target[key] = value
end

local function restore(undo)
  for index = #undo, 1, -1 do
    local item = undo[index]
    item.target[item.key] = item.value
  end
end

local function trusted(body)
  return { body = body, author_login = "fkst-test-bot", created_at = "2026-06-03T01:00:00Z" }
end

local function event_for(fixture)
  local payload = h.ready({ dedup_key = fixture.version })
  payload.impl_retry_attempt = fixture.retry
  if fixture.blocked_reentry then
    payload.operator_reentry = { command = "reimplement", from_state = "blocked", pr_number = 7,
      state_version = BLOCKED_VERSION, impl_version = payload.dedup_key }
  end
  return { queue = "devloop_ready", payload = payload, ts = "2026-06-03T02:03:04Z" }
end

local function comments_for(fixture, view, event)
  local comments = obs.json_array({ trusted(core.state_marker(PROPOSAL, view.state, view.version)) })
  if fixture.blocked_reentry then
    table.insert(comments, trusted(m_builders.pr_link_marker(PROPOSAL, 7,
      "devloop-owner-repo-42-01HY", event.payload.dedup_key, "dev")))
  end
  return comments
end

local function install_ports(ports, fixture, event, captured, undo)
  local view_index = 0
  function ports.github.issue_view(repo, number, fields, timeout)
    view_index = view_index + 1
    local view = fixture.views[view_index] or fixture.views[#fixture.views]
    table.insert(ports.github._model.writes, { kind = "issue_view", repo = repo, number = number,
      fields = fields, timeout = timeout, view_index = view_index })
    return { stdout = entity_reads.issue_view_stdout({ number = number, title = "Implement enter observation",
      body = "", state = "OPEN", labels = { "fkst-dev:" .. view.state },
      comments = comments_for(fixture, view, event), assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  replace(devloop_commands, "gh_issue_view_implement", function(repo, number, timeout)
    return ports.github.issue_view(repo, number, "title,body,labels,comments,state,author", timeout)
  end, undo)
  replace(_G, "with_lock", function(_, fn) return fn() end, undo)
  replace(_G, "now", function() return 1784396944 end, undo)
  replace(m_claims, "managed_bot_logins", function() return { ["fkst-test-bot"] = true } end, undo)
  replace(core, "dependency_gate", function()
    return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
  end, undo)
  replace(config, "branch_config", function() return { upstream = "dev", integration = "dev" } end, undo)
  replace(m_mq, "wip_capacity_allows_start", function() return true, "wip-cap-disabled", 0, nil end, undo)
  replace(worktree, "prepare_base", function() return "1111111111111111111111111111111111111111" end, undo)
  replace(worktree, "prepare_worktree", function()
    return "/tmp/fkst-packages-test/github-devloop/implement-enter"
  end, undo)
  replace(devloop_commands, "git_worktree_merge_no_edit", function()
    table.insert(ports.git._model.writes, { kind = "merge_no_edit" })
    return { stdout = "", stderr = "", exit_code = 0 }
  end, undo)
  replace(substrate_pin, "refresh", function()
    table.insert(ports.git._model.writes, { kind = "substrate_pin_refresh" })
  end, undo)
  replace(context_bundle, "context_fetch_from_bundle", function()
    return { kind = "external", ref = "owner/repo#issue/42" }
  end, undo)
  replace(workflow_codex, "dispatch", function()
    return { deferred = true, reason = "observation-stop-after-implementation-start" }
  end, undo)

  local original = transitions.implementation_transition_status
  replace(transitions, "implementation_transition_status", function(state, expected, marker_version)
    local outcome = original(state, expected, marker_version)
    local call = { current = obs.copy_value(state), from_states = obs.json_array(),
      incoming_version = marker_version, target_version = NULL, dispatch = "versioned", outcome = outcome }
    for _, source_state in ipairs(expected or {}) do
      if type(source_state) == "table" then
        table.insert(call.from_states, source_state.state)
        call.incoming_version = source_state.version or call.incoming_version
        if source_state.target_version ~= nil then
          call.target_version = source_state.target_version
          call.dispatch = "cyclic"
        end
      else
        table.insert(call.from_states, source_state)
      end
    end
    table.insert(captured.calls, call)
    table.insert(captured.sequence, { kind = "call", index = #captured.calls })
    call.sequence = #captured.sequence
    return outcome
  end, undo)

  local original_decision = devloop_logging.log_cas_decision
  replace(devloop_logging, "log_cas_decision", function(dept, proposal_id, current, from_state, to_state,
      outcome, reason)
    if dept == "implement" then
      table.insert(captured.decisions, { proposal_id = proposal_id, current = obs.copy_value(current),
        from_state = from_state, to_state = to_state, outcome = outcome, reason = reason })
      table.insert(captured.sequence, { kind = "decision", index = #captured.decisions })
      captured.decisions[#captured.decisions].sequence = #captured.sequence
    end
    return original_decision(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end, undo)

  local original_apply = devloop_logging.log_apply
  replace(devloop_logging, "log_apply", function(dept, proposal_id, to_state, version, labels, queues)
    if dept == "implement" then
      table.insert(captured.applies, { proposal_id = proposal_id, to_state = to_state, version = version,
        labels = obs.copy_value(labels), queues = obs.copy_value(queues) })
    end
    return original_apply(dept, proposal_id, to_state, version, labels, queues)
  end, undo)
end

local function make_department(ports, fixture, event, captured, undo)
  install_ports(ports, fixture, event, captured, undo)
  return { spec = production.spec, ports = ports, pipeline = production.pipeline }
end


local function selected_call(fixture, captured)
  local selected
  for _, call in ipairs(captured.calls) do
    if call.dispatch == fixture.dispatch and call.outcome == fixture.transition then
      if selected ~= nil then
        local left = obs.copy_value(selected)
        local right = obs.copy_value(call)
        left.sequence = nil
        right.sequence = nil
        if obs.canonical_json(left) ~= obs.canonical_json(right) then
          error(fixture.name .. ": decision class has divergent delegated probes", 0)
        end
      end
      selected = selected or call
    end
  end
  if selected == nil then
    error(fixture.name .. ": missing wrapper decision " .. fixture.dispatch .. ":" .. fixture.transition, 0)
  end
  return selected
end

local function decision_for_call(fixture, call, captured)
  local next_call = math.huge
  for _, candidate in ipairs(captured.calls) do
    if candidate.sequence > call.sequence and candidate.sequence < next_call then
      next_call = candidate.sequence
    end
  end
  for _, decision in ipairs(captured.decisions) do
    if decision.sequence > call.sequence and decision.sequence < next_call
      and decision.to_state == "implementing" and decision.outcome == fixture.cas then
      return decision
    end
  end
  error(fixture.name .. ": missing observable decision after selected wrapper call", 0)
end

local function inventory_effect(effect_id)
  local selected
  for _, effect in ipairs(sinks) do
    if effect.id == effect_id and effect.callsite and effect.callsite.department == "implement" then
      if selected ~= nil then error("duplicate implement sink " .. effect_id, 0) end
      selected = effect
    end
  end
  if selected == nil then error("missing implement sink " .. tostring(effect_id), 0) end
  return selected
end

local function effects_for(fixture, result)
  local effects = obs.json_array()
  local writes = obs.json_array()
  t.eq(#result.raises, #fixture.effects, fixture.name .. ": exact writer effect count")
  for ordinal, effect_id in ipairs(fixture.effects) do
    local shape = inventory_effect(effect_id)
    local raised = result.raises[ordinal]
    table.insert(effects, { effect_id = shape.id, sink_kind = shape.effect_kind,
      authority_class = shape.authority_class, ordinal = ordinal })
    table.insert(writes, { effect_id = shape.id, queue = raised.queue, payload = obs.copy_value(raised.payload) })
  end
  return effects, writes
end

local function run_department(fixture, event, captured, github_model, git_model)
  local undo = {}
  local department = make_department({
    github = github_fake.new(github_model),
    git = git_fake.new(git_model),
  }, fixture, event, captured, undo)
  local ok, result = pcall(function()
    if fixture.expected_error then
      local failed = testing.run_fake_expecting_failure(department, event)
      t.is_true(tostring(failed.failure.error):find(fixture.expected_error, 1, true) ~= nil,
        fixture.name .. ": exact defer failure")
      return failed
    end
    return testing.run_fake(department, event)
  end)
  restore(undo)
  if not ok then error(result, 0) end
  return result
end

local function capture_fixture(fixture)
  devloop_base.configure_trusted_bot_login("fkst-test-bot")
  local event = event_for(fixture)
  local captured = {
    calls = obs.json_array(),
    decisions = obs.json_array(),
    applies = obs.json_array(),
    sequence = obs.json_array(),
  }
  local github_model = github_fake.model({
    author_policy = { mode = "whitelist", logins = { "fkst-test-bot" } },
  })
  local git_model = git_fake.model({})
  local result = run_department(fixture, event, captured, github_model, git_model)
  local call = selected_call(fixture, captured)
  local decision = decision_for_call(fixture, call, captured)
  local effects, writes = effects_for(fixture, result)
  table.insert(writes, 1, { kind = "cas-decision", outcome = decision.outcome, reason = decision.reason })
  if #captured.applies > 0 then
    table.insert(writes, 2, { kind = "apply", value = obs.copy_value(captured.applies[1]) })
  end

  t.eq(call.outcome, fixture.transition, fixture.name .. ": delegated transition enum")
  t.eq(decision.outcome, fixture.cas, fixture.name .. ": observable writer decision")
  t.eq(#github_model.writes, #fixture.views, fixture.name .. ": production read count")
  t.eq(call.dispatch, fixture.dispatch, fixture.name .. ": wrapper dispatch")

  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = PREFIX .. fixture.name,
    owner = "github-devloop",
    site = obs.copy_value(SITE),
    boundary = "writer",
    typed_intent = {
      kind = "implementation_transition_status:" .. fixture.dispatch,
      source_state = call.from_states[1],
      source_boundary = fixture.dispatch,
      target = "implementing",
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = obs.nullable(call.current.version),
        incoming_version = call.incoming_version,
        target_version = call.target_version,
      },
      lineage = {
        proposal_id = event.payload.proposal_id,
        dedup_key = event.payload.dedup_key,
        source_ref = obs.copy_value(event.payload.source_ref),
        collapsed_decision_class = fixture.dispatch .. ":" .. fixture.transition,
      },
    },
    old_inputs = {
      current_fact = {
        state = obs.nullable(call.current.state),
        version = obs.nullable(call.current.version),
        stage_rank = obs.nullable(call.current.stage_rank),
      },
      caller_from_states = obs.copy_value(call.from_states),
      incoming_version = call.incoming_version,
      target_version = call.target_version,
      handoff_reference = NULL,
    },
    old_outcome = {
      status = fixture.status,
      reason_code = fixture.reason,
      cas_outcome = decision.outcome,
      emitted_effects = effects,
      observable_writes = writes,
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = NULL,
    },
    evidence_refs = obs.json_array({
      { kind = "runtime-cas-probe",
        ref = "departments.implement.transitions.implementation_transition_status:"
          .. fixture.dispatch .. ":" .. fixture.transition },
      { kind = "runtime-event-source", ref = "devloop_ready:" .. tostring(event.payload.source_ref.ref) },
    }),
  }
end

local function effect_ids(record)
  local ids = {}
  for _, effect in ipairs(record.old_outcome.emitted_effects) do table.insert(ids, effect.effect_id) end
  return ids
end

local function fixture_tuple(fixture)
  return table.concat({ fixture.dispatch, fixture.transition, fixture.status, fixture.reason, fixture.cas,
    table.concat(fixture.effects, ",") }, "|")
end

local function record_tuple(record)
  local decision = record.typed_intent.lineage.collapsed_decision_class:match(":([^:]+)$")
  return table.concat({ record.typed_intent.source_boundary, decision, record.old_outcome.status,
    record.old_outcome.reason_code, record.old_outcome.cas_outcome, table.concat(effect_ids(record), ",") }, "|")
end

local function tuple_set(records, converter, label)
  local set = {}
  for _, record in ipairs(records) do
    local value = converter(record)
    if set[value] then error(label .. ": duplicate decision tuple " .. value, 0) end
    set[value] = true
  end
  return set
end

local function assert_same_set(left, right, left_label, right_label)
  for value in pairs(left) do
    if not right[value] then error(left_label .. " absent from " .. right_label .. ": " .. value, 0) end
  end
  for value in pairs(right) do
    if not left[value] then error(right_label .. " absent from " .. left_label .. ": " .. value, 0) end
  end
end

local function runtime_records()
  local records = obs.json_array()
  for _, fixture in ipairs(FIXTURES) do table.insert(records, capture_fixture(fixture)) end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

local function committed_records()
  local inventory = json.decode(file.read(INVENTORY))
  local records = obs.json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local site = record.site or {}
    if site.path == SITE.path and site.symbol == SITE.symbol and site.ordinal == SITE.ordinal then
      table.insert(records, record)
    end
  end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

return {
  test_implement_enter_old_behavior_is_driven_collapsed_and_bidirectional = function()
    local first = runtime_records()
    local second = runtime_records()
    local repeated = obs.first_difference(second, first, "old_behavior_observations[implement-enter][repeat]")
    if repeated or obs.canonical_json(second) ~= obs.canonical_json(first) then
      error("second implement-enter capture differs at " .. tostring(repeated or "canonical-json"), 0)
    end

    local fixtures = tuple_set(FIXTURES, fixture_tuple, "implement-enter fixtures")
    local runtime = tuple_set(first, record_tuple, "implement-enter runtime")
    assert_same_set(runtime, fixtures, "runtime", "fixture lattice")

    local expected = committed_records()
    local inventory_records = tuple_set(expected, record_tuple, "implement-enter inventory")
    assert_same_set(runtime, inventory_records, "runtime", "inventory")
    local difference = obs.first_difference(first, expected, "old_behavior_observations[implement-enter]")
    if difference or obs.canonical_json(first) ~= obs.canonical_json(expected) then
      error("runtime-bound OLD implement-enter observation differs at "
        .. tostring(difference or "canonical-json") .. "; runtime_records=" .. obs.canonical_json(first), 0)
    end
    t.eq(#first, 5, "implement-enter captures the bounded decision enum, not the input product")
  end,
}
