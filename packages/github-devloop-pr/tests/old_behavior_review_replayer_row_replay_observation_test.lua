local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local github_factory = require("devloop.github_factory")

local active_ports = nil
local production_github_handle = github_factory.production_handle
local github_port_proxy = setmetatable({}, {
  __index = function(_, key)
    return function(...)
      local handle = active_ports and active_ports.github or production_github_handle()
      local operation = handle[key]
      if type(operation) ~= "function" then
        error("review replayer row replay: missing GitHub port operation " .. tostring(key), 0)
      end
      return operation(...)
    end
  end,
})
github_factory.production_handle = function() return github_port_proxy end

local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local replayer = require("devloop.replayer")
local testing = require("testkit_internal.testing")
local transition_version = require("contract.transition_version")
local observe_pr_department = require("departments.observe_pr.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local nullable = observation_support.nullable
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local OBSERVATION_PREFIX = "row-replay:github-devloop-pr:review-replayer/"
local SITE = {
  path = "packages/github-devloop-pr/core/pr_review_replayer.lua",
  symbol = "review_converge_fact",
  ordinal = "row-replay/pr-review",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7101
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local BRANCH = "devloop-owner-repo-42-01HY"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"
local BASE_SHA = "abc123"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#pr/7101" }
local REVIEW_PROPOSAL = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, VERSION, HEAD_SHA)

local FIXTURES = json_array({
  { name = "absent-round-reraise", expected_status = "re-raised", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay" }) },
  { name = "round-zero-reraise", rounds = 0, expected_status = "re-raised", expected_decision = "applied(replay)", expected_target = "reviewing", expected_effect_ids = json_array({ "comment:pr:row-replay" }) },
  { name = "terminal-evidence-budget", rounds = 1, terminal_cause = "evidence-continuation-budget-exhausted", expected_status = "route-to-transition", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_review_reconcile" }) },
  { name = "terminal-external-evidence", rounds = 0, essence_stall = true, terminal_cause = "external-evidence-required", expected_status = "route-to-transition", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_review_reconcile" }) },
  { name = "terminal-no-semantic-progress", rounds = 3, same_verdicts = true, terminal_cause = "no-semantic-progress", expected_status = "route-to-transition", expected_decision = "applied(replay)", expected_target = "blocked", expected_effect_ids = json_array({ "queue:github-devloop-pr.devloop_review_reconcile" }) },
})
local function fixture_updated_at(fixture)
  for index, value in ipairs(FIXTURES) do if value == fixture then return string.format("2026-06-04T01:03:%02dZ", 10 + index) end end
  error("review replayer row replay: fixture is outside the production lattice", 0)
end

local function trusted_comment(body, created_at)
  return { body = body, author_login = "fkst-test-bot", created_at = created_at or "2026-06-03T01:00:00Z" }
end

local function angle_digests(round, same)
  return {
    { perspective = "one", verdict = "comment", digest = same and "stable-a" or ("a-" .. tostring(round)) },
    { perspective = "two", verdict = "abstain", digest = same and "stable-b" or ("b-" .. tostring(round)) },
    { perspective = "three", verdict = "abstain", digest = same and "stable-c" or ("c-" .. tostring(round)) },
  }
end

local function comments_for(fixture)
  local comments = json_array({
    trusted_comment(m_builders.pr_origin_marker(PROPOSAL_ID, tostring(ISSUE_NUMBER), BRANCH, VERSION, BASE_BRANCH)),
    trusted_comment(core.state_marker(PROPOSAL_ID, "reviewing", VERSION), "2026-06-03T01:00:01Z"),
  })
  if fixture.rounds ~= nil then
    local first_round = fixture.rounds == 0 and 0 or 1
    for round = first_round, fixture.rounds do
      local marker = conv_rounds.review_converge_round_marker(
        core,
        REVIEW_PROPOSAL,
        PROPOSAL_ID,
        VERSION,
        HEAD_SHA,
        convergence_shared.source_ref_digest(SOURCE_REF),
        round,
        transition_version.review_loop_at(VERSION, round),
        fixture.same_verdicts and "Same review question" or ("Review question " .. tostring(round)),
        angle_digests(round, fixture.same_verdicts),
        nil,
        fixture.essence_stall == true
      )
      table.insert(comments, trusted_comment(marker, "2026-06-03T01:00:1" .. tostring(round) .. "Z"))
    end
  end
  return comments
end

local function pr_event(fixture)
  local updated_at = fixture_updated_at(fixture)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1", type = "pr", repo = REPO, number = PR_NUMBER,
      state = "OPEN", updated_at = updated_at,
      dedup_key = "owner/repo#pr#7101@" .. updated_at .. "/" .. fixture.name,
      source_ref = copy_value(SOURCE_REF),
    },
    now_seconds = 1784048400,
  }
end

local function rest_comment_json(comment, index)
  local rendered = entity_read_mocks.view_comment_json(comment):gsub('"author"', '"user"'):gsub('"createdAt"', '"created_at"')
  if not rendered:find('"id"', 1, true) then rendered = rendered:gsub("^{", '{"id":' .. tostring(index) .. ",", 1) end
  return rendered
end

local function comments_stdout(comments)
  local rendered = {}; for index, comment in ipairs(comments) do table.insert(rendered, rest_comment_json(comment, index)) end; return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function pr_rest_stdout(fixture)
  return string.format('{"number":%d,"state":"open","updated_at":"%s","draft":false,"labels":[],"user":{"login":"fkst-test-bot"},"mergeable":true,"mergeable_state":"clean","head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s","owner":{"login":"owner"}}},"base":{"ref":"%s","sha":"%s","repo":{"full_name":"%s","owner":{"login":"owner"}}}}\n', PR_NUMBER, fixture_updated_at(fixture), BRANCH, HEAD_SHA, REPO, BASE_BRANCH, BASE_SHA, REPO)
end

local function record(model, kind, fields) local value = fields or {}; value.kind = kind; table.insert(model.writes, value) end
local function write_count(model, kind) local count = 0; for _, entry in ipairs(model.writes) do if entry.kind == kind then count = count + 1 end end; return count end

local function make_github_fake(fixture)
  local model = github_fake.model(); local github = github_fake.new(model); local comments = comments_for(fixture)
  local pr_view = entity_read_mocks.pr_view_stdout({ repo = REPO, number = PR_NUMBER, comments = comments, head = BRANCH, head_sha = HEAD_SHA, state = "OPEN", updated_at = fixture_updated_at(fixture), base_branch = BASE_BRANCH, base_sha = BASE_SHA, labels = { "fkst-dev:reviewing" } })
  function github._exec(argv) error("review replayer row replay: unexpected GitHub adapter call " .. canonical_json(argv), 0) end
  function github.pr_rest_view(repo, number, timeout) record(model, "pr_rest_view", { repo = repo, number = number, timeout = timeout }); return { stdout = pr_rest_stdout(fixture), stderr = "", exit_code = 0 } end
  function github.pr_comments(repo, number, timeout) record(model, "pr_comments", { repo = repo, number = number, timeout = timeout }); return { stdout = comments_stdout(comments), stderr = "", exit_code = 0 } end
  function github.pr_updated_at(repo, number, timeout) record(model, "pr_updated_at", { repo = repo, number = number, timeout = timeout }); return { stdout = fixture_updated_at(fixture) .. "\n", stderr = "", exit_code = 0 } end
  function github.pr_cli_view(repo, number, fields, timeout) record(model, "pr_cli_view", { repo = repo, number = number, fields = fields, timeout = timeout }); return { stdout = pr_view, stderr = "", exit_code = 0 } end
  function github.issue_view(repo, number, fields, timeout) record(model, "issue_view", { repo = repo, number = number, fields = fields, timeout = timeout }); return { stdout = entity_read_mocks.issue_view_stdout({ repo = repo, number = number, assignees = { "fkst-test-bot" }, author_login = "fkst-test-bot", comments = {} }), stderr = "", exit_code = 0 } end
  return github, model
end

local function make_git_fake()
  local model = git_fake.model(); local git = git_fake.new(model)
  function git._exec(argv) error("review replayer row replay: unexpected Git adapter call " .. canonical_json(argv), 0) end
  return git, model
end

local function make_department(fixture)
  local github, github_model = make_github_fake(fixture); local git, git_model = make_git_fake(); local ports = { github = github, git = git }
  return { spec = observe_pr_department.spec, github_model = github_model, git_model = git_model, pipeline = function(event) local previous_ports, previous_git = active_ports, core.git; active_ports, core.git = ports, ports.git; local ok, result = pcall(observe_pr_department.pipeline, event); core.git, active_ports = previous_git, previous_ports; if not ok then error(result, 0) end; return result end }
end

local EFFECTS = {
  ["github-proxy.github_pr_comment_request"] = { effect_id = "comment:pr:row-replay", sink_kind = "comment", authority_class = "lifecycle-authoritative" },
  ["devloop_review_reconcile"] = { effect_id = "queue:github-devloop-pr.devloop_review_reconcile", sink_kind = "queue", authority_class = "lifecycle-authoritative" },
}

local function effect_observations(raises)
  local emitted, writes = json_array(), json_array()
  for ordinal, raised in ipairs(raises) do local shape = EFFECTS[raised.queue]; if shape == nil then error("unclassified review replayer row replay raise: " .. tostring(raised.queue), 0) end; table.insert(emitted, { effect_id = shape.effect_id, sink_kind = shape.sink_kind, authority_class = shape.authority_class, ordinal = ordinal }); table.insert(writes, { effect_id = shape.effect_id, queue = raised.queue }) end
  return emitted, writes
end
local function effect_ids(effects) local ids = json_array(); for _, effect in ipairs(effects or {}) do table.insert(ids, tostring(effect.effect_id)) end; return ids end

local function capture_runtime(fixture)
  h.mock_bot_env()
  local event, department = pr_event(fixture), make_department(fixture)
  local original, calls = replayer.replay_from_table, json_array()
  replayer.replay_from_table = function(M, dept, issue, state, row, facts)
    local call = { dept = dept, state = state.state, version = state.version, row_from_state = row and row.from_state, decisions = json_array(), raises = json_array(), applies = json_array() }
    local old_decision, old_raise, old_apply = devloop_logging.log_cas_decision, devloop_logging.log_raise, devloop_logging.log_apply
    devloop_logging.log_cas_decision = function(log_dept, proposal_id, current, from_state, to_state, outcome, reason) table.insert(call.decisions, { proposal_id = proposal_id, from_state = from_state, to_state = to_state, outcome = outcome, reason = reason }); return old_decision(log_dept, proposal_id, current, from_state, to_state, outcome, reason) end
    devloop_logging.log_raise = function(log_dept, proposal_id, queue, payload) table.insert(call.raises, { proposal_id = proposal_id, queue = queue, payload = copy_value(payload) }); return old_raise(log_dept, proposal_id, queue, payload) end
    devloop_logging.log_apply = function(log_dept, proposal_id, to_state, version, labels, queues) table.insert(call.applies, { proposal_id = proposal_id, to_state = to_state, version = version, labels = copy_value(labels), queues = copy_value(queues) }); return old_apply(log_dept, proposal_id, to_state, version, labels, queues) end
    local ok, issued = pcall(original, M, dept, issue, state, row, facts)
    devloop_logging.log_apply, devloop_logging.log_raise, devloop_logging.log_cas_decision = old_apply, old_raise, old_decision
    if not ok then error(issued, 0) end
    call.issued = issued == true; table.insert(calls, call); return issued
  end
  local ok, result, captured = pcall(function() return observation_support.observe_department({ config = config, devloop_logging = devloop_logging, devloop_state = devloop_state, dept = "observe_pr", from_state = "reviewing", transition_kind = "versioned_transition_status", run = function() return testing.run_fake(department, event) end, codex_runs_for_read = json_array(), write_mode = "real" }) end)
  replayer.replay_from_table = original
  if not ok then error(result, 0) end
  t.eq(#calls, 1, fixture.name .. ": real observe_pr dispatch reaches review replayer once")
  local call = calls[1]
  t.eq(call.dept, "observe_pr", fixture.name .. ": replay department")
  t.eq(call.state, "reviewing", fixture.name .. ": production-derived reviewing state")
  t.eq(call.version, VERSION, fixture.name .. ": production-derived version")
  t.eq(call.row_from_state, "reviewing", fixture.name .. ": production reviewing row")
  t.eq(#call.decisions, 1, fixture.name .. ": one review row disposition")
  t.eq(call.decisions[1].outcome, fixture.expected_decision, fixture.name .. ": exact decision")
  t.eq(call.decisions[1].to_state, fixture.expected_target, fixture.name .. ": exact target")
  t.is_true(write_count(department.github_model, "pr_rest_view") > 0, fixture.name .. ": PR read uses GitHub fake")
  t.is_true(write_count(department.github_model, "pr_comments") > 0, fixture.name .. ": PR comments use GitHub fake")
  t.is_true(write_count(department.github_model, "issue_view") > 0, fixture.name .. ": claim read uses GitHub fake")
  if fixture.terminal_cause ~= nil then t.eq(call.raises[1].payload.terminal_cause, fixture.terminal_cause, fixture.name .. ": exact terminal cause") end
  return event, captured, call
end

local function build_record(fixture)
  local event, captured, call = capture_runtime(fixture); local emitted, writes = effect_observations(call.raises)
  t.eq(canonical_json(effect_ids(emitted)), canonical_json(fixture.expected_effect_ids), fixture.name .. ": exact row effects")
  local replay_version = call.applies[1] and call.applies[1].version or nil
  return {
    schema = "restart-old-behavior-observation.v2", observation_id = OBSERVATION_PREFIX .. fixture.name, owner = "github-devloop-pr", site = copy_value(SITE), boundary = "row_replay",
    typed_intent = { kind = "row_replay", source_state = "reviewing", source_boundary = event.queue, target = fixture.expected_target, cause_schema_id = event.payload.schema, generation_epoch = { state_version = VERSION, replay_version = nullable(replay_version), converge_round = nullable(fixture.rounds), terminal_cause = nullable(fixture.terminal_cause) }, lineage = { proposal_id = PROPOSAL_ID, issue_number = ISSUE_NUMBER, pr_number = PR_NUMBER, head_sha = HEAD_SHA, source_ref = copy_value(SOURCE_REF), state_version = VERSION } },
    old_inputs = { current_fact = { state = "reviewing", version = VERSION, stage_rank = devloop_state.stage_rank("reviewing") }, caller_from_states = json_array({ "reviewing" }), incoming_version = VERSION, target_version = nullable(replay_version), handoff_reference = JSON_NULL },
    old_outcome = { status = fixture.expected_status, reason_code = fixture.terminal_cause or fixture.expected_decision, cas_outcome = call.decisions[1].outcome, emitted_effects = emitted, observable_writes = writes, handoff_direct_lookup_count = captured.handoff_direct_lookup_count, timeout_evidence_source = JSON_NULL },
    evidence_refs = json_array({ { kind = "runtime-review-converge-fact", ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:215-238" }, { kind = "runtime-review-converge-disposition", ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:241-254" }, { kind = "runtime-review-replay-dispatch", ref = "packages/github-devloop-pr/core/pr_review_replayer.lua:770-831" }, { kind = "runtime-event-source", ref = SOURCE_REF.ref } }),
  }
end

local function tuple(variant, status, reason, target, effects) return table.concat({ variant, status, reason, target, table.concat(effects, ",") }, "|") end
local function fixture_tuples() local values = {}; for _, fixture in ipairs(FIXTURES) do local value = tuple(fixture.name, fixture.expected_status, fixture.terminal_cause or fixture.expected_decision, fixture.expected_target, fixture.expected_effect_ids); if values[value] then error("duplicate production fixture tuple: " .. value, 0) end; values[value] = true end; return values end
local function record_tuples(records, label) local values = {}; for _, record in ipairs(records) do local id = tostring(record.observation_id or ""); if id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then error(label .. " has unexpected observation_id " .. id, 0) end; local value = tuple(id:sub(#OBSERVATION_PREFIX + 1), record.old_outcome.status, record.old_outcome.reason_code, record.typed_intent.target, effect_ids(record.old_outcome.emitted_effects)); if values[value] then error(label .. " contains duplicate tuple: " .. value, 0) end; values[value] = true end; return values end
local function assert_bidirectional(actual, expected, actual_label, expected_label, records) for value in pairs(actual) do if not expected[value] then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end; for value in pairs(expected) do if not actual[value] then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end end
local function capture_records() local records = json_array(); for _, fixture in ipairs(FIXTURES) do table.insert(records, build_record(fixture)) end; table.sort(records, function(a, b) return a.observation_id < b.observation_id end); return records end
local function committed_records() local selected = json_array(); local inventory = json.decode(file.read(INVENTORY_PATH)); for _, record in ipairs(inventory.old_behavior_observations or {}) do local site = record.site; if type(site) == "table" and site.path == SITE.path and site.symbol == SITE.symbol and site.ordinal == SITE.ordinal then table.insert(selected, record) end end; table.sort(selected, function(a, b) return a.observation_id < b.observation_id end); return selected end

return {
  test_review_replayer_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    t.is_true(core.restart_completeness_audit_for_state("reviewing") ~= nil, "reviewing is a production-declared replay row")
    local fixtures, first, second = fixture_tuples(), capture_records(), capture_records()
    t.eq(#first, 5, "complete production-reachable review converge replay disposition count")
    local repeat_difference = first_difference(second, first, "old_behavior_observations[review-replayer-row-replay][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then error("second OLD review replayer row replay capture differs at " .. tostring(repeat_difference or "canonical-json"), 0) end
    local runtime = record_tuples(first, "runtime records")
    assert_bidirectional(runtime, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    assert_bidirectional(runtime, record_tuples(expected, "inventory records"), "runtime records", "inventory records", first)
    local difference = first_difference(first, expected, "old_behavior_observations[review-replayer-row-replay]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then error("runtime-bound OLD review replayer row replay observation differs at " .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0) end
  end,
}
