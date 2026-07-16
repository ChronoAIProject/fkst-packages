local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local github_factory = require("devloop.github_factory")

-- This observation predates department-level DI, so route the captured production
-- handle through the scoped test port and delegate normally outside the observed call.
local active_ports = nil
local production_github_handle = github_factory.production_handle
local github_port_proxy = setmetatable({}, {
  __index = function(_, key)
    return function(...)
      local handle = active_ports and active_ports.github or production_github_handle()
      local operation = handle[key]
      if type(operation) ~= "function" then
        error("merge decompose observation: missing GitHub port operation " .. tostring(key), 0)
      end
      return operation(...)
    end
  end,
})
github_factory.production_handle = function()
  return github_port_proxy
end

local config = require("devloop.config")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit.old_behavior_observation_support")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit.testing")
local merge_department = require("departments.merge.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local DECOMPOSE_QUEUE = "github-devloop-decompose.devloop_decompose"
local RECONCILE_QUEUE = "devloop_fix_reconcile"
local OBSERVATION_PREFIX = "intent:github-devloop-pr:merge-decompose/"
local SITE = {
  path = "packages/github-devloop-pr/departments/merge/main.lua",
  symbol = "merge_executor.process_merge_ready_event",
  ordinal = DECOMPOSE_QUEUE,
}

local REPO = "owner/repo"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"

local function max_fix_version(proposal_id)
  local version = "ready/consensus-" .. proposal_id .. "/2026-06-03T01-02-03Z"
  for round = 1, config.max_fix_rounds() do
    version = version .. "/fix/" .. tostring(round)
  end
  return version
end

local function fixture_for(name, issue_number, pr_number)
  local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(issue_number)
  local version = max_fix_version(proposal_id)
  local review_proposal_id = devloop_base.pr_review_proposal_id(REPO, pr_number, version, HEAD_SHA)
  local source_ref = { kind = "external", ref = REPO .. "#pr/" .. tostring(pr_number) }
  local payload = payloads_builders.build_devloop_merge_ready_payload(
    proposal_id,
    pr_number,
    version,
    {
      review_proposal_id = review_proposal_id,
      review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
      reviewed_head_sha = HEAD_SHA,
    },
    source_ref
  )
  return {
    name = name,
    issue_number = issue_number,
    pr_number = pr_number,
    proposal_id = proposal_id,
    branch = "devloop-owner-repo-" .. tostring(issue_number) .. "-01HY",
    version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = payload.review_dedup_key,
    source_ref = source_ref,
    payload = payload,
  }
end

local function production_fixtures()
  return json_array({
    fixture_for("merge-gate", 4301, 7101),
    fixture_for("own-ci", 4302, 7102),
  })
end

local function event_for(fixture)
  return {
    queue = "devloop_merge_ready",
    payload = copy_value(fixture.payload),
    now_seconds = 1784048400,
  }
end

local function merge_ready_comments(fixture)
  return json_array({
    m_builders.pr_origin_marker(
      fixture.proposal_id,
      tostring(fixture.issue_number),
      fixture.branch,
      fixture.version,
      BASE_BRANCH
    ),
    core.state_marker(fixture.proposal_id, "merge-ready", fixture.version),
    m_builders.merge_ready_marker(
      fixture.proposal_id,
      fixture.pr_number,
      fixture.version,
      fixture.review_proposal_id,
      fixture.review_dedup_key,
      HEAD_SHA
    ),
    m_builders.review_result_marker(
      fixture.review_proposal_id,
      fixture.proposal_id,
      "approve",
      fixture.review_dedup_key
    ),
  })
end

local function status_rollup(fixture)
  if fixture.name == "own-ci" then
    return '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:04:04Z","conclusion":"FAILURE","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T02:03:04Z","status":"COMPLETED","workflowName":"ci","headSha":"'
      .. HEAD_SHA .. '"}]'
  end
  return '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:04:04Z","conclusion":"SUCCESS","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T02:03:04Z","status":"COMPLETED","workflowName":"ci","headSha":"'
    .. HEAD_SHA .. '"}]'
end

local function mock_branch_config()
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = BASE_BRANCH,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function record(model, kind, fields)
  local entry = fields or {}
  entry.kind = kind
  table.insert(model.writes, entry)
end

local function write_count(model, kind)
  local count = 0
  for _, entry in ipairs(model.writes) do
    if entry.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function make_github_fake(fixture, fields)
  local model = github_fake.model()
  local github = github_fake.new(model)
  local pr_stdout = entity_read_mocks.pr_view_stdout(fields)

  function github._exec(argv)
    error("merge decompose observation: unexpected GitHub adapter call " .. canonical_json(argv), 0)
  end
  function github.issue_view(repo, issue_number, selected_fields, timeout)
    record(model, "issue_view", {
      repo = repo,
      issue_number = issue_number,
      fields = selected_fields,
      timeout = timeout,
    })
    return {
      stdout = entity_read_mocks.issue_view_stdout({
        repo = repo,
        number = issue_number,
        assignees = { "fkst-test-bot" },
        author_login = "fkst-test-bot",
      }),
      stderr = "",
      exit_code = 0,
    }
  end
  function github.pr_cli_view(repo, pr_number, selected_fields, timeout)
    record(model, "pr_view", {
      repo = repo,
      pr_number = pr_number,
      fields = selected_fields,
      timeout = timeout,
    })
    return { stdout = pr_stdout, stderr = "", exit_code = 0 }
  end
  function github.pr_list_merge_queue(repo, base, timeout)
    record(model, "pr_list_merge_queue", { repo = repo, base = base, timeout = timeout })
    return {
      stdout = string.format('[{"number":%d,"state":"open","base":{"ref":"dev"}}]\n', fixture.pr_number),
      stderr = "",
      exit_code = 0,
    }
  end
  function github.pr_diff_name_only(repo, pr_number, timeout)
    record(model, "pr_diff_name_only", { repo = repo, pr_number = pr_number, timeout = timeout })
    return { stdout = "file.lua\n", stderr = "", exit_code = 0 }
  end
  function github.gh_commit_check_runs(repo, head_sha, timeout)
    record(model, "commit_check_runs", { repo = repo, head_sha = head_sha, timeout = timeout })
    return {
      stdout = '{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"failure","head_sha":"'
        .. tostring(head_sha) .. '"}]}\n',
      stderr = "",
      exit_code = 0,
    }
  end
  return github, model
end

local function make_git_fake()
  local model = git_fake.model()
  local git = git_fake.new(model)
  function git._exec(argv)
    error("merge decompose observation: unexpected Git adapter call " .. canonical_json(argv), 0)
  end
  function git.fetch_branch(remote, branch, timeout)
    record(model, "fetch_branch", { remote = remote, branch = branch, timeout = timeout })
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function git.remote_branch_head(remote, branch, timeout)
    record(model, "remote_branch_head", { remote = remote, branch = branch, timeout = timeout })
    return {
      stdout = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
      stderr = "",
      exit_code = 0,
    }
  end
  function git.is_ancestor(ancestor_sha, descendant_sha, timeout)
    record(model, "is_ancestor", {
      ancestor_sha = ancestor_sha,
      descendant_sha = descendant_sha,
      timeout = timeout,
    })
    return { stdout = "", stderr = "", exit_code = 1 }
  end
  return git, model
end

local function make_department(ports)
  return {
    spec = merge_department.spec,
    pipeline = function(event)
      local previous_ports = active_ports
      local previous_git = core.git
      active_ports = ports
      core.git = ports.git
      local ok, result = pcall(merge_department.pipeline, event)
      core.git = previous_git
      active_ports = previous_ports
      if not ok then
        error(result, 0)
      end
      return result
    end,
  }
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  mock_branch_config()

  local fields = {
    repo = REPO,
    number = fixture.pr_number,
    comments = merge_ready_comments(fixture),
    head = fixture.branch,
    head_sha = HEAD_SHA,
    state = "OPEN",
    base_branch = BASE_BRANCH,
    base_sha = "abc123",
    labels = {},
    mergeable = "MERGEABLE",
    merge_state = fixture.name == "own-ci" and "UNSTABLE" or "DIRTY",
    status_check_rollup_json = status_rollup(fixture),
  }
  local github, github_model = make_github_fake(fixture, fields)
  local git, git_model = make_git_fake()
  local department = make_department({ github = github, git = git })
  department.github_model = github_model
  department.git_model = git_model
  return department
end

local function select_raise(raises, queue, label)
  local selected = json_array()
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      table.insert(selected, raised)
    end
  end
  t.eq(#selected, 1, label .. " contains exactly one " .. queue .. " raise")
  return selected[1]
end

local function terminal_comment_markers(fixture, reconcile)
  local reason = "fix-loop-max-rounds-after-" .. tostring(reconcile.round) .. "-rounds"
  local body = core.build_fix_reconcile_comment_request(
    REPO,
    tostring(fixture.issue_number),
    reconcile,
    "drop",
    reason
  ).body
  local state_marker = core.state_marker(fixture.proposal_id, "blocked", reconcile.issue_version)
  local reconcile_marker = conv_reconcile.fix_reconcile_marker(
    fixture.proposal_id,
    reconcile.issue_version,
    "drop"
  )
  t.is_true(body:find(state_marker, 1, true) ~= nil, fixture.name .. ": production terminal comment contains blocked state")
  t.is_true(body:find(reconcile_marker, 1, true) ~= nil, fixture.name .. ": production terminal comment contains fix-reconcile marker")
  return {
    state = "blocked",
    fix_reconcile_action = "drop",
    co_located = true,
  }
end

local function capture_runtime(fixture)
  local event = event_for(fixture)
  local department = prepare_fixture(fixture)
  local constructor_payloads = json_array()
  local original_builder = payloads_builders.build_devloop_decompose_payload

  payloads_builders.build_devloop_decompose_payload = function(...)
    local payload = original_builder(...)
    table.insert(constructor_payloads, copy_value(payload))
    return payload
  end

  local ok, result, captured = pcall(function()
    local run_result, run_capture = observation_support.observe_department({
      config = config,
      devloop_logging = devloop_logging,
      devloop_state = devloop_state,
      dept = "merge",
      from_state = "merge-ready",
      write_mode = "real",
      run = function()
        return testing.run_fake(department, event)
      end,
      codex_runs_for_read = json_array(),
    })
    return run_result, run_capture
  end)
  payloads_builders.build_devloop_decompose_payload = original_builder
  if not ok then
    error(result, 0)
  end

  t.eq(#constructor_payloads, 1, fixture.name .. ": merge cap calls the forward decompose constructor once")
  t.eq(#captured.raises, #result.raises, fixture.name .. ": raise spy and run_fake raise counts")
  t.eq(#result.raises, 2, fixture.name .. ": terminal merge emits reconcile and decompose")
  local emitted = select_raise(result.raises, DECOMPOSE_QUEUE, fixture.name .. " run_fake")
  local spied = select_raise(captured.raises, DECOMPOSE_QUEUE, fixture.name .. " raise spy")
  local reconcile = select_raise(result.raises, RECONCILE_QUEUE, fixture.name .. " run_fake").payload
  t.eq(canonical_json(spied.payload), canonical_json(emitted.payload), fixture.name .. ": raise spy captures the complete emitted payload")
  t.eq(canonical_json(spied.payload), canonical_json(constructor_payloads[1]), fixture.name .. ": published intent exactly matches the direct constructor variant")
  t.eq(#captured.decisions, 1, fixture.name .. ": capped merge records one terminal routing decision")
  t.eq(captured.decisions[1].outcome, "applied(fix-loop-max-rounds)", fixture.name .. ": merge reaches the cap termination")
  t.is_true(write_count(department.github_model, "issue_view") > 0, fixture.name .. ": claim read uses GitHub fake")
  t.is_true(write_count(department.github_model, "pr_view") > 0, fixture.name .. ": merge PR read uses GitHub fake")
  t.is_true(write_count(department.github_model, "pr_list_merge_queue") > 0, fixture.name .. ": merge queue read uses GitHub fake")
  t.is_true(write_count(department.github_model, "pr_diff_name_only") > 0, fixture.name .. ": risk read uses GitHub fake")
  if fixture.name == "own-ci" then
    t.is_true(write_count(department.github_model, "commit_check_runs") > 0, fixture.name .. ": CI classification uses GitHub fake")
  else
    t.is_true(write_count(department.git_model, "fetch_branch") > 0, fixture.name .. ": base fetch uses Git fake")
    t.is_true(write_count(department.git_model, "remote_branch_head") > 0, fixture.name .. ": base head read uses Git fake")
    t.is_true(write_count(department.git_model, "is_ancestor") > 0, fixture.name .. ": mergeability probe uses Git fake")
  end
  return event, copy_value(spied), copy_value(reconcile), captured.decisions[1], terminal_comment_markers(fixture, reconcile)
end

local function build_record(fixture)
  local event, raised, reconcile, decision, comment_markers = capture_runtime(fixture)
  local payload = raised.payload
  t.eq(payload.expected_child_count, nil, fixture.name .. ": forward intent has no replay expected count")
  t.eq(payload.completed_child_count, nil, fixture.name .. ": forward intent has no replay completed count")
  t.eq(payload.review_proposal_id, fixture.review_proposal_id, fixture.name .. ": review proposal binding")
  t.eq(payload.review_dedup_key, fixture.review_dedup_key, fixture.name .. ": review dedup binding")
  t.eq(payload.head_sha, HEAD_SHA, fixture.name .. ": reviewed head binding")
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop-pr",
    site = copy_value(SITE),
    boundary = "published_intent_producer",
    typed_intent = {
      kind = "published_intent",
      source_state = "merge-ready",
      source_boundary = event.queue,
      target = raised.queue,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = fixture.version,
        source_version = event.payload.dedup_key,
        payload_version = payload.dedup_key,
      },
      lineage = {
        terminal_family = fixture.name,
        proposal_id = payload.proposal_id,
        pr_number = payload.pr_number,
        source_ref = copy_value(payload.source_ref),
        review_binding = {
          review_proposal_id = payload.review_proposal_id,
          review_dedup_key = payload.review_dedup_key,
          head_sha = payload.head_sha,
        },
        reconcile = {
          schema = reconcile.schema,
          reason_class = reconcile.reason_class,
          dedup_key = reconcile.dedup_key,
          terminal_comment_markers = copy_value(comment_markers),
        },
      },
    },
    old_inputs = {
      current_fact = {
        state = decision.current.state,
        version = decision.current.version,
        stage_rank = decision.current.stage_rank,
      },
      caller_from_states = json_array({ "merge-ready" }),
      incoming_version = event.payload.dedup_key,
      target_version = payload.dedup_key,
      handoff_reference = {
        queue = RECONCILE_QUEUE,
        schema = reconcile.schema,
        dedup_key = reconcile.dedup_key,
      },
    },
    old_outcome = {
      status = "raised",
      reason_code = "fix-loop-max-rounds/" .. fixture.name,
      cas_outcome = decision.outcome,
      emitted_effects = json_array({
        {
          effect_id = "queue:" .. DECOMPOSE_QUEUE,
          sink_kind = "queue",
          authority_class = "grantless-published-intent",
          ordinal = 1,
        },
      }),
      observable_writes = json_array({
        {
          effect_id = "queue:" .. DECOMPOSE_QUEUE,
          queue = raised.queue,
          payload = copy_value(payload),
        },
      }),
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      {
        kind = "runtime-raise-capture",
        ref = "devloop.logging.log_raise:merge:" .. DECOMPOSE_QUEUE,
      },
      {
        kind = "production-dispatch",
        ref = "packages/github-devloop-pr/departments/merge/main.lua:19-22",
      },
      {
        kind = "production-callsite",
        ref = "packages/github-devloop-pr/core/merge_executor.lua:70-76",
      },
      {
        kind = "production-condition",
        ref = fixture.name == "own-ci"
          and "packages/github-devloop-pr/core/merge_executor.lua:550-564"
          or "packages/github-devloop-pr/core/merge_executor.lua:520-548",
      },
      {
        kind = "production-terminal",
        ref = "packages/github-devloop-pr/core/fix_rounds.lua:102-114,203-225",
      },
      {
        kind = "production-reconcile-comment",
        ref = "packages/github-devloop-pr/core/review_meta_requests.lua:178-196",
      },
      {
        kind = "sink-inventory",
        ref = "packages/github-devloop-pr/core/restart/sink_inventory.lua:43",
      },
    }),
  }
end

local function family_set_from_fixtures(fixtures)
  local families = {}
  local entities = {}
  for _, fixture in ipairs(fixtures) do
    if families[fixture.name] ~= nil then
      error("duplicate fixture family: " .. fixture.name, 0)
    end
    families[fixture.name] = true
    local identity = table.concat({ fixture.proposal_id, fixture.pr_number, fixture.source_ref.ref }, "|")
    if entities[identity] ~= nil then
      error("duplicate fixture entity lineage: " .. identity, 0)
    end
    entities[identity] = true
  end
  return families
end

local function family_set_from_records(records, label)
  local families = {}
  local entities = {}
  for index, record in ipairs(records) do
    local lineage = record.typed_intent and record.typed_intent.lineage or {}
    local family = lineage.terminal_family
    if type(family) ~= "string" or family == "" then
      error(label .. "[" .. tostring(index) .. "] has no terminal family", 0)
    end
    if families[family] ~= nil then
      error(label .. " contains duplicate family " .. family, 0)
    end
    families[family] = true
    local identity = table.concat({
      tostring(lineage.proposal_id),
      tostring(lineage.pr_number),
      tostring(lineage.source_ref and lineage.source_ref.ref),
    }, "|")
    if entities[identity] ~= nil then
      error(label .. " contains duplicate entity lineage " .. identity, 0)
    end
    entities[identity] = true
  end
  return families
end

local function assert_bidirectional_membership(actual, expected, actual_label, expected_label, records)
  local detail = records and "; actual_records=" .. canonical_json(records) or ""
  for family in pairs(actual) do
    if expected[family] == nil then
      error(actual_label .. " family is absent from " .. expected_label .. ": " .. family .. detail, 0)
    end
  end
  for family in pairs(expected) do
    if actual[family] == nil then
      error(expected_label .. " family is absent from " .. actual_label .. ": " .. family .. detail, 0)
    end
  end
end

local function is_target_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == SITE.path
    and site.symbol == SITE.symbol
    and site.ordinal == SITE.ordinal
end

local function committed_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local selected = json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_target_record(record) then
      table.insert(selected, record)
    end
  end
  table.sort(selected, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return selected
end

local function runtime_records(fixtures)
  local records = json_array()
  for _, fixture in ipairs(fixtures) do
    table.insert(records, build_record(fixture))
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return records
end

return {
  test_merge_decompose_published_intent_is_real_dispatch_and_bidirectional = function()
    local fixtures = production_fixtures()
    local fixture_families = family_set_from_fixtures(fixtures)
    local first = runtime_records(fixtures)
    local second = runtime_records(fixtures)
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[merge-decompose-intent][repeat]"
    )
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD merge published-intent runtime capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end

    local runtime_families = family_set_from_records(first, "runtime records")
    assert_bidirectional_membership(runtime_families, fixture_families, "runtime records", "production fixture families", first)
    local expected = committed_records()
    local inventory_families = family_set_from_records(expected, "inventory records")
    assert_bidirectional_membership(runtime_families, inventory_families, "runtime records", "inventory records", first)
    local inventory_difference = first_difference(
      first,
      expected,
      "old_behavior_observations[merge-decompose-intent]"
    )
    if inventory_difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error(
        "runtime-bound OLD merge published-intent observation differs at "
          .. tostring(inventory_difference or "canonical-json")
          .. "; runtime_records=" .. canonical_json(first),
        0
      )
    end
  end,
}
