local config = require("devloop.config")
local core = require("core")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local github_fake = require("forge.github_fake")
local h = require("tests.devloop_helpers")
local forks = require("devloop.forks")
local m_claims = require("devloop.claims")
local m_mq = require("devloop.merge_queue")
local observation_support = require("testkit.old_behavior_observation_support")
local replayer = require("devloop.replayer")
local sink_inventory = require("core.restart.sink_inventory")
local testing = require("testkit.testing")
local devloop_commands = require("devloop.commands")
local implement_department = require("departments.implement.main")
local observe_issue_department = require("departments.observe_issue.main")

local t = h.t
local JSON_NULL = observation_support.JSON_NULL
local JSON_ARRAY_TAG = observation_support.JSON_ARRAY_TAG
local JSON_OBJECT_TAG = observation_support.JSON_OBJECT_TAG
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local nullable = observation_support.nullable
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local UPDATED_AT = "2026-06-03T01:02:03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local SLICE_ENTRY_KEY = string.rep("1", 64)
local SLICE_LEDGER_REF = "refs/fkst/migration-slices/" .. SLICE_ENTRY_KEY
local SLICE_LEDGER_SHA = string.rep("a", 40)
local CANONICAL_ISSUE_NUMBER = 41
local FORK_BACKING_ISSUE_NUMBER = 618

local SITES = {
  observe_issue = {
    path = "packages/github-devloop/departments/observe_issue/main.lua",
    symbol = "pipeline",
    ordinal = "consumes:devloop_observe_issue",
  },
  implement = {
    path = "packages/github-devloop/departments/implement/main.lua",
    symbol = "pipeline",
    ordinal = "consumes:devloop_ready",
  },
}

local PREFIXES = {
  observe_issue = "receiver-activation-observe-issue-",
  implement = "receiver-activation-implement-",
}

local EFFECT_ROUTES = {
  ["comment:issue:dependency-canonicalization"] = {
    queue = "github-proxy.github_issue_comment_request",
  },
  ["label:issue:dependency-canonicalization"] = {
    queue = "github-proxy.github_issue_label_request",
  },
  ["comment:issue:duplicate-slice"] = {
    queue = "github-proxy.github_issue_comment_request",
  },
  ["label:issue:duplicate-slice"] = {
    queue = "github-proxy.github_issue_label_request",
  },
  ["adapter:github.issue-close-duplicate-slice"] = {
    adapter_context = "gh issue close",
  },
  ["comment:issue:duplicate-fork"] = {
    queue = "github-proxy.github_issue_comment_request",
  },
  ["label:issue:duplicate-fork"] = {
    queue = "github-proxy.github_issue_label_request",
  },
  ["adapter:github.issue-close-duplicate-fork"] = {
    adapter_context = "gh issue close",
  },
}

local function inventory_effect(effect_id)
  local selected = nil
  for _, effect in ipairs(sink_inventory) do
    if effect.id == effect_id and effect.callsite and effect.callsite.department == "implement" then
      if selected ~= nil then
        error("duplicate implement sink inventory effect: " .. tostring(effect_id), 0)
      end
      selected = effect
    end
  end
  if selected == nil then
    error("missing implement sink inventory effect: " .. tostring(effect_id), 0)
  end
  return selected
end

local OBSERVE_FIXTURES = json_array({
  {
    disposition = "skip-foreign-payload",
    payload = {
      schema = "unsupported.issue.v1",
      type = "issue",
      repo = REPO,
      number = ISSUE_NUMBER,
      title = "Unsupported activation",
      updated_at = UPDATED_AT,
      dedup_key = "owner/repo#issue#42@" .. UPDATED_AT,
      source_ref = copy_value(SOURCE_REF),
    },
    status = "rejected",
    reason = "skip-foreign(payload)",
    cas = "skip-foreign(proposal_id)",
    target = "reject",
    source_line = 570,
  },
  {
    disposition = "skip-closed",
    issue_state = "CLOSED",
    labels = { "fkst-dev:enabled", "fkst-dev:ready" },
    status = "rejected",
    reason = "skip-closed",
    cas = "skip-advanced-or-diverged",
    target = "reject",
    source_line = 592,
  },
  {
    disposition = "skip-not-opted-in",
    labels = { "fkst-dev:ready" },
    status = "rejected",
    reason = "skip-not-opted-in",
    cas = "skip-not-opted-in",
    target = "reject",
    source_line = 596,
  },
  {
    disposition = "skip-held",
    labels = { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:hold" },
    status = "rejected",
    reason = "skip-held",
    cas = "skip-held",
    target = "reject",
    source_line = 603,
  },
  {
    disposition = "claim-not-acquired",
    labels = { "fkst-dev:enabled", "fkst-dev:ready" },
    assignees = { "other-login" },
    status = "rejected",
    reason = "claim-not-acquired",
    cas = "skip-claim-lost",
    target = "reject",
    source_line = 658,
  },
  {
    disposition = "admitted-replay-dispatched",
    labels = { "fkst-dev:enabled", "fkst-dev:ready" },
    status = "admitted",
    reason = "admitted-replay-dispatched",
    cas = "dispatched(replay_from_table)",
    target = "replay",
    source_line = 779,
    replay = true,
  },
})

local IMPLEMENT_FIXTURES = json_array({
  {
    disposition = "skip-foreign-payload",
    payload = {
      schema = "unsupported.ready.v1",
      proposal_id = PROPOSAL_ID,
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      source_ref = copy_value(SOURCE_REF),
    },
    status = "rejected",
    reason = "skip-foreign(payload)",
    cas = "skip-foreign(proposal_id)",
    target = "reject",
    source_line = 552,
  },
  {
    disposition = "skip-closed",
    issue_state = "CLOSED",
    status = "rejected",
    reason = "skip-closed",
    cas = "skip-stale(original-closed)",
    target = "reject",
    source_line = 596,
  },
  {
    disposition = "skip-noncanonical-slice",
    noncanonical_slice = true,
    status = "rejected",
    reason = "skip-noncanonical-slice",
    cas = "skip-stale(noncanonical-slice)",
    target = "reject",
    source_line = 600,
    expected_effect_ids = json_array({
      "comment:issue:duplicate-slice",
      "label:issue:duplicate-slice",
      "adapter:github.issue-close-duplicate-slice",
    }),
    adapter_effect_id = "adapter:github.issue-close-duplicate-slice",
  },
  {
    disposition = "skip-fork-backing-closed",
    fork_backing_state = "CLOSED",
    status = "rejected",
    reason = "skip-closed",
    cas = "skip-stale(original-closed)",
    target = "reject",
    source_line = 604,
  },
  {
    disposition = "skip-noncanonical-fork",
    fork_backing_state = "OPEN",
    fork_canonical_issue_number = CANONICAL_ISSUE_NUMBER,
    status = "rejected",
    reason = "skip-noncanonical-fork",
    cas = "skip-stale(noncanonical-fork)",
    target = "reject",
    source_line = 608,
    expected_effect_ids = json_array({
      "comment:issue:duplicate-fork",
      "label:issue:duplicate-fork",
      "adapter:github.issue-close-duplicate-fork",
    }),
    adapter_effect_id = "adapter:github.issue-close-duplicate-fork",
  },
  {
    disposition = "dependency-gate-held",
    dependency_held = true,
    status = "rejected",
    reason = "dependency-gate-held",
    cas = "hold-dependency-backstop",
    target = "dependency_wait",
    source_line = 617,
    expected_effect_ids = json_array({
      "comment:issue:dependency-canonicalization",
      "label:issue:dependency-canonicalization",
    }),
  },
  {
    disposition = "wip-cap-held",
    wip_held = true,
    status = "rejected",
    reason = "wip-cap-held",
    cas = "hold-wip-cap",
    target = "hold",
    source_line = 770,
  },
  {
    disposition = "admitted-proceed",
    status = "admitted",
    reason = "admitted-proceed",
    cas = "applied",
    target = "proceed",
    source_line = 783,
    proceed = true,
  },
})

local function observe_payload(extra)
  return h.issue(extra or {})
end

local function implement_payload(extra)
  return h.ready(extra or {})
end

local function event_for(dept, payload)
  return {
    queue = "github-devloop." .. (dept == "observe_issue" and "devloop_observe_issue" or "devloop_ready"),
    ts = "2026-06-03T01:02:04Z",
    payload = payload,
  }
end

local function replace(target, key, value, restorations)
  table.insert(restorations, { target = target, key = key, value = target[key] })
  target[key] = value
end

local function restore_all(restorations)
  for index = #restorations, 1, -1 do
    local item = restorations[index]
    item.target[item.key] = item.value
  end
end

local function prepare_observe_fixture(fixture, payload)
  h.mock_bot_env()
  if fixture.disposition == "skip-foreign-payload" then
    return
  end
  local labels = fixture.labels or { "fkst-dev:enabled", "fkst-dev:ready" }
  local rest_labels = {}
  for _, label in ipairs(labels) do
    table.insert(rest_labels, '{"name":"' .. tostring(label) .. '"}')
  end
  local assignees = fixture.assignees or { "fkst-test-bot" }
  local rest_assignees = {}
  for _, login in ipairs(assignees) do
    table.insert(rest_assignees, '{"login":"' .. tostring(login) .. '"}')
  end
  t.mock_command("gh api repos/owner/repo/issues/42", {
    stdout = '{"number":42,"title":"Capture receiver activation","body":"Receiver activation boundary fixture","state":"'
      .. tostring(fixture.issue_state or "OPEN"):lower()
      .. '","created_at":"2026-06-01T00:00:00Z","updated_at":"' .. UPDATED_AT
      .. '","labels":[' .. table.concat(rest_labels, ",") .. '],"user":{"login":"fkst-test-bot"},"assignees":['
      .. table.concat(rest_assignees, ",") .. ']}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues/42/comments?per_page=100'", {
    stdout = '[{"id":"IC_receiver_activation_ready","body":"'
      .. h.json_string(core.state_marker(PROPOSAL_ID, "ready", payload.dedup_key))
      .. '","user":{"login":"fkst-test-bot"},"created_at":"2099-01-01T00:00:00Z"}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function prepare_implement_fixture(fixture, payload)
  h.mock_bot_env()
  if fixture.disposition == "skip-foreign-payload" then
    return
  end
  local comments = {
    core.state_marker(PROPOSAL_ID, "ready", payload.dedup_key),
  }
  if fixture.fork_backing_state ~= nil then
    table.insert(comments, forks.fork_origin_marker(
      REPO,
      FORK_BACKING_ISSUE_NUMBER,
      "human",
      { kind = "external", ref = REPO .. "#issue/" .. tostring(FORK_BACKING_ISSUE_NUMBER) }
    ))
  end
  local body = "Receiver activation boundary fixture"
  if fixture.noncanonical_slice then
    body = body .. "\n\n<!-- fkst:ratchet-slice:v1 entry_key=\"" .. SLICE_ENTRY_KEY .. "\" -->"
  end
  h.mock_issue_implement_raw({ "fkst-dev:ready" }, comments, {
    state = fixture.issue_state or "OPEN",
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    title = "Capture implement receiver activation",
    body = body,
  })
  if fixture.noncanonical_slice then
    t.mock_command("git ls-remote origin " .. SLICE_LEDGER_REF, {
      stdout = SLICE_LEDGER_SHA .. "\t" .. SLICE_LEDGER_REF .. "\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git fetch origin " .. SLICE_LEDGER_REF, {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git cat-file -p " .. SLICE_LEDGER_SHA, {
      stdout = "tree 0000000000000000000000000000000000000000\n\n"
        .. '{"schema":"fkst.ratchet-migration-slice-ledger.v1","state":"issue-created","entry_key":"'
        .. SLICE_ENTRY_KEY .. '","allowlist_path":"migration/saga-handler.allowlist","generation":1,'
        .. '"claim_owner":"fkst-test-bot","claimed_at":"2026-06-19T00:00:00Z","issue_number":'
        .. tostring(CANONICAL_ISSUE_NUMBER) .. ',"updated_at":"2026-06-19T00:00:00Z"}\n',
      stderr = "",
      exit_code = 0,
    })
  end
  if fixture.fork_backing_state ~= nil then
    local original_comments = ""
    if fixture.fork_canonical_issue_number ~= nil then
      local dedup_key = forks.fork_issue_dedup_key(REPO, FORK_BACKING_ISSUE_NUMBER)
      original_comments = ',"comments":[{"body":"<!-- fkst:github-proxy:issue-created:v1 dedup=\\\"'
        .. dedup_key .. '\\\" issue=\\\"' .. tostring(fixture.fork_canonical_issue_number)
        .. '\\\" -->","author":{"login":"fkst-test-bot"}}]'
    else
      original_comments = ',"comments":[]'
    end
    t.mock_command(core.gh_issue_view_state_cmd(REPO, FORK_BACKING_ISSUE_NUMBER), {
      stdout = '{"title":"Original","state":"' .. fixture.fork_backing_state
        .. '","labels":[],"assignees":[],"author":{"login":"human"}' .. original_comments .. '}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function captured_effects(raises, captured, dept, fixture)
  local emitted = json_array()
  local writes = json_array()
  local raise_index = 0
  local adapter_index = 0
  local sequence = captured.effect_sequence or json_array()
  local adapter_writes = captured.adapter_writes or json_array()
  for ordinal, effect in ipairs(sequence) do
    local effect_id = fixture.expected_effect_ids and fixture.expected_effect_ids[ordinal]
    local route = effect_id and EFFECT_ROUTES[effect_id]
    local inventory = effect_id and inventory_effect(effect_id)
    if dept ~= "implement" or route == nil or inventory == nil then
      error("unclassified " .. tostring(dept) .. " receiver activation OLD effect", 0)
    end
    table.insert(emitted, {
      effect_id = inventory.id,
      sink_kind = inventory.effect_kind,
      authority_class = inventory.authority_class,
      ordinal = ordinal,
    })
    if effect.kind == "raise" then
      raise_index = raise_index + 1
      local raised = raises[raise_index]
      if route.queue == nil or raised == nil or route.queue ~= raised.queue or effect.queue ~= raised.queue then
        error("unclassified " .. tostring(dept) .. " receiver activation OLD raise: " .. tostring(raised and raised.queue), 0)
      end
      table.insert(writes, {
        effect_id = inventory.id,
        queue = raised.queue,
        payload = copy_value(raised.payload),
      })
    elseif effect.kind == "adapter" then
      adapter_index = adapter_index + 1
      local adapter_write = adapter_writes[adapter_index]
      if effect.effect_id ~= effect_id or route.adapter_context == nil or adapter_write == nil
        or adapter_write.kind ~= "exec" or adapter_write.context ~= route.adapter_context then
        error("unclassified " .. tostring(dept) .. " receiver activation OLD adapter effect", 0)
      end
      table.insert(writes, {
        effect_id = inventory.id,
        adapter_call = copy_value(adapter_write),
      })
    else
      error("unknown receiver activation OLD effect kind: " .. tostring(effect.kind), 0)
    end
  end
  t.eq(raise_index, #(raises or {}), fixture.disposition .. ": all raises classified")
  t.eq(adapter_index, #adapter_writes, fixture.disposition .. ": all adapter writes classified")
  return emitted, writes
end

local function effect_ids(effects)
  local ids = json_array()
  for _, effect in ipairs(effects or {}) do
    table.insert(ids, effect.effect_id)
  end
  return ids
end

local function capture_observe(fixture)
  local payload = fixture.payload and copy_value(fixture.payload) or observe_payload()
  local event = event_for("observe_issue", payload)
  prepare_observe_fixture(fixture, payload)
  local restorations = {}
  local replay_calls = json_array()
  local lock_calls = json_array()
  local decisions = json_array()
  replace(core, "linked_pr_surface_snapshot", function() return { prs = {}, absent_prs = {} } end, restorations)
  replace(core, "dependency_gate", function()
    return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
  end, restorations)
  replace(replayer, "replay_from_table", function(_, dept, issue, state, row)
    table.insert(replay_calls, { dept = dept, issue = copy_value(issue), state = copy_value(state), row = row and row.from_state })
    return true
  end, restorations)
  replace(devloop_logging, "log_cas_decision", function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if dept == "observe_issue" then
      table.insert(decisions, { proposal_id = proposal_id, current = copy_value(current), from_state = from_state, to_state = to_state, outcome = outcome, reason = reason })
    end
  end, restorations)
  replace(_G, "with_lock", function(key, fn)
    table.insert(lock_calls, key)
    return fn()
  end, restorations)
  local ok, result = pcall(testing.run_fake, observe_issue_department, event)
  restore_all(restorations)
  if not ok then error(fixture.disposition .. ": " .. tostring(result), 0) end
  t.eq(#lock_calls, fixture.disposition == "skip-foreign-payload" and 0 or 1, fixture.disposition .. ": observe lock admission count")
  t.eq(#replay_calls, fixture.replay and 1 or 0, fixture.disposition .. ": replay dispatch count")
  t.eq(#result.raises, 0, fixture.disposition .. ": no row replay or claim-helper effects recaptured")
  local selected = decisions[#decisions]
  if fixture.replay then
    t.is_true(selected == nil or selected.outcome ~= fixture.cas, fixture.disposition .. ": admitted disposition is derived from real replay dispatch, not a manufactured CAS log")
  else
    t.is_true(selected ~= nil, fixture.disposition .. ": rejection decision is observable")
    t.eq(selected.outcome, fixture.cas, fixture.disposition .. ": exact rejection mapping")
  end
  return event, result, {
    decisions = decisions,
    replay_calls = replay_calls,
    lock_calls = lock_calls,
  }
end

local function capture_implement(fixture)
  local payload = fixture.payload and copy_value(fixture.payload) or implement_payload()
  local event = event_for("implement", payload)
  prepare_implement_fixture(fixture, payload)
  local restorations = {}
  local decisions = json_array()
  local lock_calls = json_array()
  local effect_sequence = json_array()
  local github_model = github_fake.model()
  local github = github_fake.new(github_model)
  local original_read_env = config.read_env
  local original_log_raise = devloop_logging.log_raise
  replace(config, "branch_config", function()
    return { upstream = "dev", integration = "integration-test" }
  end, restorations)
  replace(config, "read_env", function(name, ...)
    if name == "FKST_GITHUB_WRITE" then
      return fixture.adapter_effect_id and "1" or nil
    end
    return original_read_env(name, ...)
  end, restorations)
  replace(m_claims, "managed_bot_logins", function() return { "fkst-test-bot" } end, restorations)
  replace(devloop_logging, "log_raise", function(dept, proposal_id, raised_queue, raised_payload)
    if dept == "implement" then
      table.insert(effect_sequence, { kind = "raise", queue = raised_queue })
    end
    return original_log_raise(dept, proposal_id, raised_queue, raised_payload)
  end, restorations)
  replace(devloop_commands, "gh_issue_close", function(repo, issue_number, timeout)
    local result = github.issue_close(repo, issue_number, timeout)
    table.insert(effect_sequence, { kind = "adapter", effect_id = fixture.adapter_effect_id })
    return result
  end, restorations)
  replace(core, "dependency_gate", function()
    if fixture.dependency_held then
      return { ok = false, kind = "waiting", reason = "waiting-on-dependency", unmet = { 53 }, notes = {} }
    end
    return { ok = true, kind = "satisfied", reason = "no-open-blockers", unmet = {}, notes = {} }
  end, restorations)
  replace(m_mq, "wip_capacity_allows_start", function()
    if fixture.wip_held then return false, "wip-cap-reached", 1, 1 end
    return true, "capacity-available", 0, 1
  end, restorations)
  replace(devloop_logging, "log_cas_decision", function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if dept == "implement" then
      table.insert(decisions, { proposal_id = proposal_id, current = copy_value(current), from_state = from_state, to_state = to_state, outcome = outcome, reason = reason })
    end
  end, restorations)
  replace(_G, "with_lock", function(key, fn)
    table.insert(lock_calls, key)
    if #lock_calls == 1 then return fn() end
    return nil
  end, restorations)
  local ok, result = pcall(testing.run_fake, implement_department, event)
  restore_all(restorations)
  if not ok then error(result, 0) end
  local expected_locks = fixture.disposition == "skip-foreign-payload" and 0 or (fixture.proceed and 2 or 1)
  t.eq(#lock_calls, expected_locks, fixture.disposition .. ": exact implementation lock progression")
  local selected = decisions[#decisions]
  t.is_true(selected ~= nil, fixture.disposition .. ": admission decision is observable")
  t.eq(selected.outcome, fixture.cas, fixture.disposition .. ": exact admission mapping")
  return event, result, {
    decisions = decisions,
    lock_calls = lock_calls,
    effect_sequence = effect_sequence,
    adapter_writes = copy_value(github_model.writes),
  }
end

local function build_record(dept, fixture)
  local event, result, captured
  if dept == "observe_issue" then
    event, result, captured = capture_observe(fixture)
  else
    event, result, captured = capture_implement(fixture)
  end
  local emitted_effects, observable_writes = captured_effects(result.raises, captured, dept, fixture)
  local expected_effect_ids = fixture.expected_effect_ids or json_array()
  t.eq(canonical_json(effect_ids(emitted_effects)), canonical_json(expected_effect_ids), fixture.disposition .. ": exact effect set")
  local current_version = nil
  if (dept == "observe_issue" and (fixture.disposition == "claim-not-acquired" or fixture.replay))
    or (dept == "implement" and (fixture.dependency_held or fixture.wip_held or fixture.proceed)) then
    current_version = event.payload.dedup_key
  end
  local target_version = nil
  if fixture.target == "dependency_wait" then
    target_version = core.ready_split_version(core.ready_payload_inner_version(event.payload.dedup_key))
  end
  local current_labels = fixture.disposition == "skip-foreign-payload" and {}
    or fixture.labels
    or (dept == "observe_issue" and { "fkst-dev:enabled", "fkst-dev:ready" } or { "fkst-dev:ready" })
  local current_fact = {
    issue_state = fixture.issue_state or (fixture.disposition == "skip-foreign-payload" and JSON_NULL or "OPEN"),
    labels = json_array(current_labels),
    assignees = json_array(fixture.assignees or (fixture.disposition == "skip-foreign-payload" and {} or { "fkst-test-bot" })),
  }
  if fixture.noncanonical_slice then
    current_fact.slice = {
      entry_key = SLICE_ENTRY_KEY,
      canonical_issue_number = CANONICAL_ISSUE_NUMBER,
    }
  end
  if fixture.fork_backing_state ~= nil then
    current_fact.fork_backing = {
      repo = REPO,
      issue_number = FORK_BACKING_ISSUE_NUMBER,
      issue_state = fixture.fork_backing_state,
      canonical_issue_number = nullable(fixture.fork_canonical_issue_number),
    }
  end
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = PREFIXES[dept] .. fixture.disposition,
    owner = "github-devloop",
    site = copy_value(SITES[dept]),
    boundary = "receiver_activation",
    typed_intent = {
      kind = "receiver_activation",
      source_state = dept == "implement" and "ready" or "observed-issue",
      source_boundary = event.queue,
      target = fixture.target,
      cause_schema_id = tostring(event.payload.schema or "missing-schema"),
      generation_epoch = {
        current_version = nullable(current_version),
        request_version = nullable(event.payload.dedup_key),
        effect_version = nullable(target_version),
      },
      lineage = {
        proposal_id = nullable(event.payload.proposal_id or PROPOSAL_ID),
        issue_number = ISSUE_NUMBER,
        source_ref = nullable(copy_value(event.payload.source_ref)),
      },
    },
    old_inputs = {
      current_fact = current_fact,
      caller_from_states = json_array({ dept == "implement" and "ready" or "observed-issue" }),
      incoming_version = tostring(event.payload.dedup_key),
      target_version = nullable(target_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = fixture.status,
      reason_code = fixture.reason,
      cas_outcome = fixture.cas,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      { kind = "runtime-receiver-activation", ref = SITES[dept].path .. ":" .. tostring(fixture.source_line) },
      { kind = "runtime-event-source", ref = event.queue },
    }),
  }
end

local function fixture_tuple(fixture)
  return table.concat({
    fixture.disposition,
    fixture.status,
    fixture.reason,
    fixture.cas,
    fixture.target,
    table.concat(fixture.expected_effect_ids or {}, ","),
  }, "|")
end

local function record_tuple(record, prefix, label)
  local observation_id = tostring(record.observation_id or "")
  if observation_id:sub(1, #prefix) ~= prefix then
    error(label .. " has unexpected observation_id " .. observation_id, 0)
  end
  return table.concat({
    observation_id:sub(#prefix + 1),
    tostring(record.old_outcome and record.old_outcome.status or ""),
    tostring(record.old_outcome and record.old_outcome.reason_code or ""),
    tostring(record.old_outcome and record.old_outcome.cas_outcome or ""),
    tostring(record.typed_intent and record.typed_intent.target or ""),
    table.concat(effect_ids(record.old_outcome and record.old_outcome.emitted_effects), ","),
  }, "|")
end

local function tuple_set(records, tuple, label)
  local values = {}
  for index, record in ipairs(records) do
    local value = tuple(record, label .. "[" .. tostring(index) .. "]")
    if values[value] then error(label .. " contains duplicate tuple: " .. value, 0) end
    values[value] = true
  end
  return values
end

local function assert_bidirectional(actual, expected, actual_label, expected_label, records)
  local detail = records and "; actual_records=" .. canonical_json(records) or ""
  for value in pairs(actual) do
    if not expected[value] then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value .. detail, 0) end
  end
  for value in pairs(expected) do
    if not actual[value] then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value .. detail, 0) end
  end
end

local function capture_records(dept, fixtures)
  local records = json_array()
  for _, fixture in ipairs(fixtures) do table.insert(records, build_record(dept, fixture)) end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

local function committed_records(dept)
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local selected = json_array()
  local site = SITES[dept]
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local actual = record.site or {}
    if actual.path == site.path and actual.symbol == site.symbol and actual.ordinal == site.ordinal then
      table.insert(selected, record)
    end
  end
  table.sort(selected, function(left, right) return left.observation_id < right.observation_id end)
  return selected
end

local function assert_site(dept, fixtures, expected_count)
  local fixture_tuples = tuple_set(fixtures, function(fixture) return fixture_tuple(fixture) end, dept .. " fixture lattice")
  local first = capture_records(dept, fixtures)
  local second = capture_records(dept, fixtures)
  t.eq(#first, expected_count, dept .. ": complete receiver activation disposition count")
  local repeat_difference = first_difference(second, first, "old_behavior_observations[" .. dept .. "][repeat]")
  if repeat_difference or canonical_json(second) ~= canonical_json(first) then
    error("second OLD " .. dept .. " receiver activation capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
  end
  local runtime_tuples = tuple_set(first, function(record, label)
    return record_tuple(record, PREFIXES[dept], label)
  end, dept .. " runtime records")
  assert_bidirectional(runtime_tuples, fixture_tuples, "runtime records", "production fixture lattice", first)
  local expected = committed_records(dept)
  local inventory_tuples = tuple_set(expected, function(record, label)
    return record_tuple(record, PREFIXES[dept], label)
  end, dept .. " inventory records")
  assert_bidirectional(runtime_tuples, inventory_tuples, "runtime records", "inventory records", first)
  local inventory_difference = first_difference(first, expected, "old_behavior_observations[" .. dept .. "]")
  if inventory_difference or canonical_json(first) ~= canonical_json(expected) then
    error("runtime-bound OLD " .. dept .. " receiver activation observation differs at "
      .. tostring(inventory_difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0)
  end
end

local function assert_validator_collapses()
  local invalid_issue_ref = observe_payload({ source_ref = { kind = "external", ref = "" } })
  local observe_result = testing.run_fake(observe_issue_department, event_for("observe_issue", invalid_issue_ref))
  t.eq(#observe_result.raises, 0, "invalid observe source_ref collapses into unsupported payload")

  local invalid_ready_ref = implement_payload({ source_ref = { kind = "external", ref = "" } })
  local implement_result = testing.run_fake(implement_department, event_for("implement", invalid_ready_ref))
  t.eq(#implement_result.raises, 0, "invalid implement source_ref collapses into unsupported payload")

  local invalid_proposal = implement_payload({ proposal_id = "outside/github-devloop" })
  local proposal_result = testing.run_fake(implement_department, event_for("implement", invalid_proposal))
  t.eq(#proposal_result.raises, 0, "invalid proposal and lock identity collapse into unsupported payload")
  t.is_true(entity_lib.implement_lock_key(PROPOSAL_ID) ~= nil, "accepted implement proposal always has a lock key")
end

return {
  test_receiver_activation_acceptors_empty_array_object_negative_control = function()
    t.is_true(JSON_ARRAY_TAG ~= JSON_OBJECT_TAG, "json.decode preserves array versus object shape")
    local expected = { emitted_effects = json_array() }
    local drifted = copy_value(expected)
    drifted.emitted_effects = {}
    local difference = first_difference(drifted, expected, "receiver-activation[negative-control]")
    t.eq(canonical_json(expected.emitted_effects), "[]")
    t.is_true(difference ~= nil and difference:find("emitted_effects", 1, true) ~= nil)
  end,

  test_observe_issue_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_validator_collapses()
    assert_site("observe_issue", OBSERVE_FIXTURES, 6)
  end,

  test_implement_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_site("implement", IMPLEMENT_FIXTURES, 8)
  end,
}
