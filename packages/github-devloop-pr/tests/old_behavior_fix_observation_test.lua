local devloop_base = require("devloop.base")
local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local m_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local requests_review = require("devloop.requests.review")
local testing = require("testkit.testing")
local transition_version = require("contract.transition_version")
local ci_repair_attempts = require("core.ci_repair_attempts")
local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local fix_department = require("departments.fix.main")

local t = h.t
local core = h.core
local JSON_NULL = json.decode("null")
local JSON_ARRAY_TAG = getmetatable(json.decode("[]"))
local JSON_OBJECT_TAG = getmetatable(json.decode("{}"))
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local SITE = {
  path = "packages/github-devloop-pr/departments/fix/main.lua",
  symbol = "pipeline",
  ordinal = "cyclic_transition_status:fixing->reviewing",
}

local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"
local FIXED_HEAD = "feedface"

local function nullable(value)
  if value == nil then
    return JSON_NULL
  end
  return value
end

local function json_string(value)
  return '"' .. tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
    :gsub("[%z\1-\31]", function(char)
      return string.format("\\u%04x", string.byte(char))
    end)
    .. '"'
end

local function array_length(value)
  local count = 0
  local maximum = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil
    end
    count = count + 1
    if key > maximum then
      maximum = key
    end
  end
  if maximum ~= count then
    return nil
  end
  return maximum
end

local function json_array(values)
  local array = json.decode("[]")
  for index, value in ipairs(values or {}) do
    array[index] = value
  end
  return array
end

local function is_json_array(value)
  return type(value) == "table" and getmetatable(value) == JSON_ARRAY_TAG
end

local function json_container_kind(value)
  if is_json_array(value) then
    return "array"
  end
  local length = array_length(value)
  if length ~= nil and length > 0 then
    return "array"
  end
  return "object"
end

local function copy_value(value)
  if type(value) ~= "table" or value == JSON_NULL then
    return value
  end
  local length = array_length(value)
  local copy = {}
  if is_json_array(value) or (length ~= nil and length > 0) then
    copy = json_array()
  end
  for key, field in pairs(value) do
    copy[copy_value(key)] = copy_value(field)
  end
  return copy
end

local function canonical_json(value)
  if value == JSON_NULL then
    return "null"
  end
  local kind = type(value)
  if kind == "string" then
    return json_string(value)
  end
  if kind == "number" or kind == "boolean" then
    return tostring(value)
  end
  if kind ~= "table" then
    error("OLD observation canonical JSON cannot encode " .. kind)
  end

  if json_container_kind(value) == "array" then
    local length = array_length(value)
    if length == nil then
      error("OLD observation canonical JSON array must be a contiguous sequence")
    end
    local items = {}
    for index = 1, length do
      items[index] = canonical_json(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    if type(key) ~= "string" then
      error("OLD observation canonical JSON object key must be a string")
    end
    table.insert(keys, key)
  end
  table.sort(keys)
  local fields = {}
  for _, key in ipairs(keys) do
    table.insert(fields, json_string(key) .. ":" .. canonical_json(value[key]))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function first_difference(actual, expected, path)
  if actual == expected then
    return nil
  end
  if actual == JSON_NULL or expected == JSON_NULL then
    return path .. " (actual=" .. canonical_json(actual) .. ", expected=" .. canonical_json(expected) .. ")"
  end
  if type(actual) ~= type(expected) then
    return path .. " (actual type=" .. type(actual) .. ", expected type=" .. type(expected) .. ")"
  end
  if type(actual) ~= "table" then
    return path .. " (actual=" .. canonical_json(actual) .. ", expected=" .. canonical_json(expected) .. ")"
  end
  local actual_container = json_container_kind(actual)
  local expected_container = json_container_kind(expected)
  if actual_container ~= expected_container then
    return path .. " (actual container=" .. actual_container
      .. ", expected container=" .. expected_container .. ")"
  end
  local keys = {}
  for key, _ in pairs(actual) do keys[key] = true end
  for key, _ in pairs(expected) do keys[key] = true end
  local ordered = {}
  for key, _ in pairs(keys) do table.insert(ordered, key) end
  table.sort(ordered, function(left, right) return tostring(left) < tostring(right) end)
  for _, key in ipairs(ordered) do
    if actual[key] == nil then
      return path .. "." .. tostring(key) .. " (missing from runtime capture)"
    end
    if expected[key] == nil then
      return path .. "." .. tostring(key) .. " (missing from committed record)"
    end
    local difference = first_difference(actual[key], expected[key], path .. "." .. tostring(key))
    if difference ~= nil then
      return difference
    end
  end
  return nil
end

local function fixing_event(version, fixture)
  local base = h.fixing()
  local review_fact = {
    review_proposal_id = base.review_proposal_id,
    review_dedup_key = base.review_dedup_key,
    reviewed_head_sha = base.reviewed_head_sha,
    blocking_gap = "missing OLD fix observation evidence",
  }
  for _, field in ipairs({ "gate_baseline_sha", "predecessor_set", "ci_failure_key", "gate_failure_excerpt" }) do
    if fixture and fixture[field] ~= nil then
      review_fact[field] = fixture[field]
    end
  end
  return payloads_builders.build_devloop_fixing_payload({
    proposal_id = base.proposal_id,
    impl_version = version,
  }, base.pr_number, review_fact, base.source_ref)
end

local function reject_comment(event)
  return requests_review.build_review_result_comment_request(core,
    "owner/repo",
    "42",
    event.proposal_id,
    event.version,
    {
      proposal_id = event.review_proposal_id,
      decision = "reject",
      body = "Reject because the OLD fix behavior must remain observable.",
      blocking_gap = "missing OLD fix observation evidence",
      dedup_key = event.review_dedup_key,
      source_ref = event.source_ref,
    },
    event.source_ref
  ).body
end

local function fix_pr_fields(event, branch, comments, head_sha)
  return {
    repo = "owner/repo",
    number = event.pr_number,
    comments = comments,
    head = branch,
    head_sha = head_sha or event.reviewed_head_sha,
    base_branch = "dev",
    state = "OPEN",
    head_repo = "owner/repo",
  }
end

local function mock_dispatch_context(event, branch, rejection, fix_reads)
  h.mock_bot_env()
  h.mock_default_issue_claim()
  local comments = json_array({
    m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev"),
    core.state_marker(event.proposal_id, "fixing", event.version),
    rejection,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    comments = comments,
    labels = { "fkst-dev:fixing" },
    title = "Implement decision recorder",
  }, "title,labels,comments,author", 1)
  local fields = fix_pr_fields(event, branch, comments)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_fix_selector, fix_reads or 1)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_fix_precheck_selector, 1)
end

local function merge_gate_comment(event, baseline, created_at)
  return {
    body = m_builders.merge_gate_marker(event.proposal_id, event.pr_number, event.version,
      event.review_proposal_id, event.review_dedup_key, event.reviewed_head_sha, baseline,
      event.gate_failure_excerpt, event.predecessor_set, event.ci_failure_key),
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function mock_returning_guard(fixture, event, branch)
  h.mock_bot_env()
  h.mock_default_issue_claim()
  local origin_branch = fixture.foreign_origin and branch .. "-foreign" or branch
  local comments = json_array({
    m_builders.pr_origin_marker(event.proposal_id, "42", origin_branch, event.version, "dev"),
    core.state_marker(event.proposal_id, "fixing", event.version),
  })
  if fixture.speculative_refix then
    local merge_ready_version = core._strip_latest_fix_version_suffix(event.version)
    table.insert(comments, core.state_marker(event.proposal_id, "merge-ready", merge_ready_version))
    table.insert(comments, m_builders.merge_ready_marker(event.proposal_id, event.pr_number,
      merge_ready_version, event.review_proposal_id, event.review_dedup_key, event.reviewed_head_sha))
    table.insert(comments, m_builders.review_result_marker(
      event.review_proposal_id, event.proposal_id, "approve", event.review_dedup_key
    ))
  end
  if fixture.superseded_merge_gate then
    table.insert(comments, merge_gate_comment(event, event.gate_baseline_sha, "2026-06-03T01:00:00Z"))
    table.insert(comments, merge_gate_comment(event, "828df8d3", "2026-06-03T01:01:00Z"))
  elseif fixture.merge_gate_feedback then
    table.insert(comments, merge_gate_comment(event, event.gate_baseline_sha))
  else
    table.insert(comments, reject_comment(event))
  end
  if fixture.ci_repair_visible then
    table.insert(comments, ci_repair_attempts.comment_request(
      "owner/repo", event, "no-fix", "No repaired revision was published."
    ).body)
  end
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo", number = 42, comments = comments, labels = { "fkst-dev:fixing" },
    title = "Implement decision recorder",
  }, "title,labels,comments,author", 1)
  local fields = fix_pr_fields(event, branch, comments, fixture.head_sha)
  fields.state = fixture.pr_state or fields.state
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_fix_selector, 1)
  if fixture.write_gate_stale or fixture.not_in_merge_queue then
    local precheck = copy_value(fields)
    if fixture.write_gate_stale then precheck.head_sha = "feedface" end
    entity_read_mocks.mock_pr_view_selector(t, precheck, entity_read_mocks.pr_fix_precheck_selector, 1)
  end
  if fixture.head_advanced then
    t.mock_command("rev-parse --verify refs/heads/", { stdout = "feedface\n", stderr = "", exit_code = 0 })
  end
  if fixture.not_in_merge_queue then
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime", stderr = "", exit_code = 0,
    })
    h.mock_existing_fix_worktree(branch, event.reviewed_head_sha)
    for _ = 1, 2 do
      t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&base=dev&per_page=100'", {
        stdout = "[[]]\n", stderr = "", exit_code = 0,
      })
    end
  end
  if fixture.speculative_refix then
    t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&base=dev&per_page=100'", {
      stdout = '[[{"number":6,"headRefName":"devloop-owner-repo-6","headRefOid":"abc999","baseRefName":"dev","state":"OPEN"}]]\n',
      stderr = "", exit_code = 0,
    })
    local predecessor_version = "ready/consensus-github-devloop/issue/owner/repo/41/2026-06-03T00-00-00Z"
    local predecessor_review = devloop_base.pr_review_proposal_id("owner/repo", 6, predecessor_version, "abc999")
    entity_read_mocks.mock_pr_view_selector(t, {
      repo = "owner/repo", number = 6, head = "devloop-owner-repo-6", head_sha = "abc999",
      base_branch = "dev", state = "OPEN", comments = json_array({
        m_builders.pr_origin_marker("github-devloop/issue/owner/repo/41", "41", "devloop-owner-repo-6", predecessor_version, "dev"),
        core.state_marker("github-devloop/issue/owner/repo/41", "merge-ready", predecessor_version),
        m_builders.merge_ready_marker("github-devloop/issue/owner/repo/41", 6, predecessor_version,
          predecessor_review, "consensus:" .. predecessor_review .. "/review", "abc999"),
      }),
    }, entity_read_mocks.pr_merge_selector, 1)
  end
end

local function prepare_fixture(fixture, event)
  local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
  if fixture.returning_guard then
    mock_returning_guard(fixture, event, branch)
    return
  end
  if fixture.feedback_visible then
    local feedback = fixture.merge_gate_feedback and merge_gate_comment(event, event.gate_baseline_sha)
      or reject_comment(event)
    mock_dispatch_context(event, branch, feedback, (fixture.successful_apply or fixture.fix_loop_max) and 2 or 1)
    if fixture.live_run_active then
      return
    end
    h.mock_context_bundle(event)
    h.mock_existing_fix_worktree(branch, event.reviewed_head_sha)
    if fixture.codex_deferred then
      return
    end
    h.mock_implement_codex(0, "fixed OLD observation coverage")
    if fixture.fix_loop_max then
      h.mock_git_status("")
      t.mock_command("rev-list --count", { stdout = "0\n", stderr = "", exit_code = 0 })
      return
    end
    h.mock_git_status(" M packages/github-devloop-pr/tests/old_behavior_fix_observation_test.lua\n")
    h.mock_git_commit(FIXED_HEAD, branch)
    h.mock_git_push(branch)
    entity_read_mocks.mock_pr_view_selector(t,
      fix_pr_fields(event, branch, json_array({
        m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev"),
      }), FIXED_HEAD),
      entity_read_mocks.pr_fix_selector,
      1
    )
    return
  end

  h.mock_bot_env()
  h.mock_default_issue_claim()
  local comments = json_array()
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(
      event.proposal_id,
      fixture.current_state,
      fixture.current_version
    ))
  end
  table.insert(comments, 1, m_builders.pr_origin_marker(
    event.proposal_id, "42", branch, event.version, "dev"
  ))
  entity_read_mocks.mock_pr_view_selector(t,
    fix_pr_fields(event, branch, comments),
    entity_read_mocks.pr_fix_selector,
    1
  )
end

local function observe_real_department(run, codex_runs_for_read)
  local captured = {
    probes = json_array(),
    decisions = json_array(),
    applies = json_array(),
    raises = json_array(),
    lines = json_array(),
    handoff_direct_lookup_count = 0,
    liveness_read_count = 0,
  }
  local original_cyclic = devloop_state.cyclic_transition_status
  local original_decision = devloop_logging.log_cas_decision
  local original_apply = devloop_logging.log_apply
  local original_raise = devloop_logging.log_raise
  local original_line = devloop_logging.log_line
  local original_codex_runs = fkst.codex_runs
  local original_write_mode = config.write_mode

  config.write_mode = function()
    return "real"
  end

  fkst.codex_runs = function()
    captured.liveness_read_count = captured.liveness_read_count + 1
    local running = codex_runs_for_read
    if type(codex_runs_for_read) == "function" then
      running = codex_runs_for_read(captured.liveness_read_count)
    end
    return { running = running or json_array() }
  end

  devloop_state.cyclic_transition_status = function(current, from_states, to_state, incoming_version, target_version)
    local outcome = original_cyclic(current, from_states, to_state, incoming_version, target_version)
    table.insert(captured.probes, {
      current = copy_value(current),
      from_states = copy_value(from_states),
      to_state = to_state,
      incoming_version = incoming_version,
      target_version = target_version,
      outcome = outcome,
    })
    return outcome
  end
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if dept == "fix" and from_state == "fixing" then
      table.insert(captured.decisions, {
        dept = dept,
        proposal_id = proposal_id,
        current = copy_value(current),
        from_state = from_state,
        to_state = to_state,
        outcome = outcome,
        reason = reason,
      })
    end
    return original_decision(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end
  devloop_logging.log_apply = function(dept, proposal_id, to_state, version, labels, queues)
    if dept == "fix" then
      table.insert(captured.applies, {
        proposal_id = proposal_id,
        to_state = to_state,
        version = version,
        labels = copy_value(labels),
        queues = copy_value(queues),
      })
    end
    return original_apply(dept, proposal_id, to_state, version, labels, queues)
  end
  devloop_logging.log_raise = function(dept, proposal_id, queue, payload)
    if dept == "fix" then
      table.insert(captured.raises, {
        proposal_id = proposal_id,
        queue = queue,
        payload = copy_value(payload),
      })
    end
    return original_raise(dept, proposal_id, queue, payload)
  end
  devloop_logging.log_line = function(level, dept, proposal_id, event, fields)
    if dept == "fix" then
      table.insert(captured.lines, {
        level = level,
        event = event,
        fields = copy_value(fields),
      })
    end
    return original_line(level, dept, proposal_id, event, fields)
  end

  local ok, result = pcall(run)
  fkst.codex_runs = original_codex_runs
  config.write_mode = original_write_mode
  devloop_logging.log_line = original_line
  devloop_logging.log_raise = original_raise
  devloop_logging.log_apply = original_apply
  devloop_logging.log_cas_decision = original_decision
  devloop_state.cyclic_transition_status = original_cyclic
  if not ok then
    error(result, 0)
  end
  return result, captured
end

local EFFECTS = {
  ["github-proxy.github_pr_comment_request"] = {
    effect_id = "comment:pr:fix-reviewing",
    sink_kind = "comment",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_label_request"] = {
    effect_id = "label:issue:fix-reviewing",
    sink_kind = "label",
    authority_class = "lifecycle-authoritative",
  },
  ["devloop_fix_reconcile"] = {
    effect_id = "queue:fix-reconcile",
    sink_kind = "queue",
    authority_class = "lifecycle-authoritative",
  },
  ["github-devloop-decompose.devloop_decompose"] = {
    effect_id = "queue:decompose",
    sink_kind = "queue",
    authority_class = "lifecycle-authoritative",
  },
}

local function outcome_status(probe, decision, apply, captured)
  if decision ~= nil and decision.outcome == "applied(fix-loop-max-rounds)" and probe.outcome == "apply" then
    t.eq(apply, nil, "fix-round termination logs its effects without a routed apply record")
    return "apply", "fix-loop-max-rounds", decision.outcome
  end
  local returning = {
    ["skip-stale(superseded-merge-gate-fact)"] = { "stale", "superseded-merge-gate-fact" },
    ["skip-foreign(pr-origin)"] = { "foreign", "pr-origin" },
    ["skip-stale(pr-closed)"] = { "stale", "pr-closed" },
    ["skip-stale(head-advanced)"] = { "stale", "head-advanced" },
    ["skip-idempotent(ci-repair-attempt-visible)"] = { "idempotent", "ci-repair-attempt-visible" },
    ["skip-stale(write-gate)"] = { "stale", "write-gate" },
    ["skip-stale(not-in-merge-queue)"] = { "stale", "not-in-merge-queue" },
  }
  local classified = decision and returning[decision.outcome] or nil
  if classified ~= nil and probe.outcome == "apply" then
    t.eq(apply, nil, "post-admission returning guard emits no apply effect")
    return classified[1], classified[2], decision.outcome
  end
  if decision ~= nil and decision.outcome == "skip-idempotent(live-exec-ref)" and probe.outcome == "apply" then
    t.eq(apply, nil, "live fix run defers after admission without applying an effect")
    return "apply", "liveness-deferred", "applied"
  end
  if decision == nil and probe.outcome == "apply" and captured.liveness_read_count == 3 then
    t.eq(apply, nil, "deferred fix dispatch emits no apply effect")
    return "apply", "codex-deferred", "applied"
  end
  if decision ~= nil and decision.outcome == "applied" and apply ~= nil then
    return "apply", "apply", decision.outcome
  end
  if decision ~= nil and decision.outcome == "skip-idempotent(already at to_state)" then
    return "idempotent", "already-at-target", decision.outcome
  end
  if decision ~= nil and decision.outcome == "skip-stale(incoming version < current marker version)" then
    return "stale", "incoming-version-older", decision.outcome
  end
  if decision ~= nil and decision.outcome == "skip-stale(version-mismatch)" and probe.outcome == "apply" then
    return "stale", "version-mismatch", decision.outcome
  end
  if decision ~= nil and decision.outcome == "skip-advanced-or-diverged" and probe.outcome == "stale" then
    return "stale", "advanced-or-diverged", decision.outcome
  end
  if decision ~= nil and decision.outcome == "applied" and probe.outcome == "apply" and apply == nil then
    return "stale", "from-state-mismatch", decision.outcome
  end
  error("unclassified OLD fix outcome: decision=" .. tostring(decision and decision.outcome)
    .. " probe=" .. tostring(probe.outcome)
    .. " liveness_reads=" .. tostring(captured.liveness_read_count)
    .. " applies=" .. tostring(apply and 1 or 0)
    .. " lines=" .. canonical_json(captured.lines))
end

local function effects_from_raises(raises)
  local effects = json_array()
  local writes = json_array()
  for ordinal, raised in ipairs(raises) do
    local shape = EFFECTS[raised.queue]
    if shape == nil then
      error("unclassified OLD fix raise: " .. tostring(raised.queue))
    end
    table.insert(effects, {
      effect_id = shape.effect_id,
      sink_kind = shape.sink_kind,
      authority_class = shape.authority_class,
      ordinal = ordinal,
    })
    table.insert(writes, {
      effect_id = shape.effect_id,
      queue = raised.queue,
      payload = copy_value(raised.payload),
    })
  end
  return effects, writes
end

local function build_record(event, result, captured)
  t.eq(#captured.probes, 1, "real fix CAS probe count")
  t.is_true(#captured.decisions <= 1, "real fix CAS decision count is zero only for codex defer")
  t.eq(#captured.raises, #result.raises, "logger and run_fake raise counts")
  for index, raised in ipairs(result.raises) do
    t.eq(canonical_json(captured.raises[index].payload), canonical_json(raised.payload), "captured raise payload " .. index)
    t.eq(captured.raises[index].queue, raised.queue, "captured raise queue " .. index)
  end

  local probe = captured.probes[1]
  local decision = captured.decisions[1]
  local apply = captured.applies[1]
  local status, reason_code, cas_outcome = outcome_status(probe, decision, apply, captured)
  local emitted_effects, observable_writes = effects_from_raises(result.raises)
  local observation_id = table.concat({
    "writer:github-devloop-pr:fix",
    tostring(probe.to_state),
    status,
    reason_code,
    apply and tostring(apply.to_state) or "none",
  }, "/")

  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = observation_id,
    owner = "github-devloop-pr",
    site = copy_value(SITE),
    boundary = "writer",
    typed_intent = {
      kind = "cyclic_transition_status",
      source_state = probe.from_states[1],
      source_boundary = JSON_NULL,
      target = probe.to_state,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = nullable(probe.current.version),
        incoming_version = probe.incoming_version,
        target_version = nullable(probe.target_version),
      },
      lineage = {
        proposal_id = event.payload.proposal_id,
        review_proposal_id = event.payload.review_proposal_id,
        review_dedup_key = event.payload.review_dedup_key,
        dedup_key = event.payload.dedup_key,
        work_unit_key = event.payload.work_unit_key,
        source_ref = copy_value(event.payload.source_ref),
      },
    },
    old_inputs = {
      current_fact = {
        state = nullable(probe.current.state),
        version = nullable(probe.current.version),
        stage_rank = nullable(probe.current.stage_rank),
      },
      caller_from_states = copy_value(probe.from_states),
      incoming_version = probe.incoming_version,
      target_version = nullable(probe.target_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = status,
      reason_code = reason_code,
      cas_outcome = cas_outcome,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      {
        kind = "runtime-cas-probe",
        ref = "devloop.state.cyclic_transition_status:" .. tostring(probe.outcome),
      },
      {
        kind = "runtime-event-source",
        ref = tostring(event.payload.source_ref and event.payload.source_ref.ref),
      },
    }),
  }
end

local FIXTURES = {
  {
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    feedback_visible = true,
    successful_apply = true,
    expected_status = "apply",
    expected_reason_code = "apply",
    expected_raise_count = 2,
  },
  {
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    feedback_visible = true,
    live_run_active = true,
    expected_status = "apply",
    expected_reason_code = "liveness-deferred",
    expected_raise_count = 0,
  },
  {
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    feedback_visible = true,
    codex_deferred = true,
    expected_status = "apply",
    expected_reason_code = "codex-deferred",
    expected_raise_count = 0,
  },
  {
    current_state = "reviewing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    expected_status = "idempotent",
    expected_reason_code = "already-at-target",
    expected_raise_count = 0,
  },
  {
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_OLDER,
    expected_status = "stale",
    expected_reason_code = "incoming-version-older",
    expected_raise_count = 0,
  },
  {
    current_state = "fixing",
    current_version = V_ORDERING_EQUAL_CURRENT,
    incoming_version = V_ORDERING_EQUAL_INCOMING,
    expected_status = "stale",
    expected_reason_code = "version-mismatch",
    expected_raise_count = 0,
  },
  {
    current_state = "blocked",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    expected_status = "stale",
    expected_reason_code = "advanced-or-diverged",
    expected_raise_count = 0,
  },
  {
    current_state = "pr-open",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    expected_status = "stale",
    expected_reason_code = "from-state-mismatch",
    expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, superseded_merge_gate = true,
    gate_baseline_sha = "281c4f9e", gate_failure_excerpt = "mergeable-conflicting",
    expected_status = "stale", expected_reason_code = "superseded-merge-gate-fact",
    expected_cas_outcome = "skip-stale(superseded-merge-gate-fact)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, foreign_origin = true,
    expected_status = "foreign", expected_reason_code = "pr-origin",
    expected_cas_outcome = "skip-foreign(pr-origin)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, pr_state = "CLOSED",
    expected_status = "stale", expected_reason_code = "pr-closed",
    expected_cas_outcome = "skip-stale(pr-closed)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, head_advanced = true, head_sha = "cafebabe",
    expected_status = "stale", expected_reason_code = "head-advanced",
    expected_cas_outcome = "skip-stale(head-advanced)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL .. "/fix/1", returning_guard = true, merge_gate_feedback = true,
    ci_repair_visible = true, ci_failure_key = "head:def456/checks:digest-0000000101",
    gate_failure_excerpt = "own-ci-red", expected_status = "idempotent",
    expected_reason_code = "ci-repair-attempt-visible",
    expected_cas_outcome = "skip-idempotent(ci-repair-attempt-visible)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, write_gate_stale = true,
    expected_status = "stale", expected_reason_code = "write-gate",
    expected_cas_outcome = "skip-stale(write-gate)", expected_raise_count = 0,
  },
  {
    incoming_version = V_EQUAL, returning_guard = true, merge_gate_feedback = true,
    predecessor_set = "none", gate_failure_excerpt = "speculative-merge-conflict",
    not_in_merge_queue = true, expected_status = "stale", expected_reason_code = "not-in-merge-queue",
    expected_cas_outcome = "skip-stale(not-in-merge-queue)", expected_raise_count = 0,
    expected_liveness_read_count = 2,
  },
  {
    incoming_version = V_EQUAL .. "/fix/1", returning_guard = true, merge_gate_feedback = true,
    predecessor_set = "none", gate_failure_excerpt = "speculative-merge-conflict",
    speculative_refix = true, expected_status = "apply", expected_reason_code = "apply",
    expected_cas_outcome = "applied", expected_raise_count = 2, expected_liveness_read_count = 0,
  },
  {
    incoming_version = (function()
      local version = V_EQUAL
      for _ = 1, config.max_fix_rounds() do version = devloop_state.next_fix_version(version) end
      return version
    end)(),
    feedback_visible = true, merge_gate_feedback = true, fix_loop_max = true,
    gate_failure_excerpt = "mergeable-conflicting", expected_status = "apply",
    expected_reason_code = "fix-loop-max-rounds",
    expected_cas_outcome = "applied(fix-loop-max-rounds)", expected_raise_count = 2,
  },
}

local function codex_runs_for_fixture(fixture, event)
  local matching = {
    role = "fix",
    proposal_id = event.proposal_id,
    dedup_key = event.work_unit_key,
    status = "running",
  }
  if fixture.live_run_active then
    return json_array({ matching })
  end
  if fixture.codex_deferred then
    return function(read_count)
      if read_count <= 2 then
        return json_array()
      end
      return json_array({ matching })
    end
  end
  return json_array()
end

local function capture_fixture(fixture)
  local event = {
    queue = "devloop_fixing",
    payload = fixing_event(fixture.incoming_version, fixture),
  }
  prepare_fixture(fixture, event.payload)
  local result, captured = observe_real_department(function()
    return testing.run_fake(fix_department, event)
  end, codex_runs_for_fixture(fixture, event.payload))
  local record = build_record(event, result, captured)
  t.eq(record.typed_intent.target, "reviewing", "real CAS call has the fixed reviewing target")
  t.eq(record.old_outcome.status, fixture.expected_status, "route reaches expected CAS regime")
  t.eq(record.old_outcome.reason_code, fixture.expected_reason_code, "route reaches expected disposition")
  if fixture.expected_cas_outcome ~= nil then
    t.eq(record.old_outcome.cas_outcome, fixture.expected_cas_outcome, "route reaches expected returning CAS outcome")
  end
  t.eq(#record.old_outcome.emitted_effects, fixture.expected_raise_count, "captured runtime effect count")
  t.eq(record.old_inputs.target_version, core.next_fix_version(event.payload.version), "five-argument cyclic call captures target_version")
  t.eq(record.old_inputs.handoff_reference, JSON_NULL, "fix consumes no direct handoff reference")
  if fixture.expected_liveness_read_count ~= nil then
    t.eq(captured.liveness_read_count, fixture.expected_liveness_read_count, "controlled post-admission liveness reads")
  elseif record.old_outcome.status == "apply" then
    t.is_true(captured.liveness_read_count > 0, "admitted fix input checks controlled codex-run liveness")
  else
    t.eq(captured.liveness_read_count, 0, "non-admitted fix input never reaches dispatch liveness")
  end
  if fixture.live_run_active then
    t.eq(captured.liveness_read_count, 1, "live run is visible at the first dispatch liveness read")
    t.eq(record.old_outcome.cas_outcome, "applied", "live run keeps CAS admission separate from defer")
  end
  if fixture.codex_deferred then
    t.eq(captured.liveness_read_count, 3, "codex defer becomes visible only at the dispatch precheck")
    t.eq(record.old_outcome.cas_outcome, "applied", "dispatch defer keeps CAS admission separate from defer")
  end
  return record
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

return {
  test_canonical_json_rejects_empty_array_object_drift = function()
    t.is_true(JSON_ARRAY_TAG ~= JSON_OBJECT_TAG, "json.decode preserves array versus object shape")

    local built = capture_fixture(FIXTURES[2])
    t.eq(canonical_json(built.old_outcome.emitted_effects), "[]", "built empty effects retain array shape")

    local drifted = copy_value(built)
    drifted.old_outcome.emitted_effects = {}
    local root = "old_behavior_observations[fix][negative_control]"
    local difference = first_difference(drifted, built, root)
    t.is_true(
      canonical_json(drifted) ~= canonical_json(built),
      "empty array to empty object drift changes canonical JSON"
    )
    t.is_true(
      difference ~= nil
        and difference:find(root .. ".old_outcome.emitted_effects", 1, true) ~= nil,
      "empty-container drift diagnostic names old_outcome.emitted_effects: " .. tostring(difference)
    )
  end,

  test_fix_pending_is_an_error_not_a_writer_disposition = function()
    local event = {
      queue = "devloop_fixing",
      payload = fixing_event(V_EQUAL),
    }
    prepare_fixture({ incoming_version = V_EQUAL }, event.payload)
    local result, captured = observe_real_department(function()
      return testing.run_fake_expecting_failure(fix_department, event)
    end, json_array())
    t.eq(#captured.probes, 1, "pending route reaches the real CAS probe")
    t.eq(captured.probes[1].outcome, "pending", "missing source marker produces pending")
    t.eq(#captured.decisions, 1, "pending route logs its retry decision")
    t.eq(captured.decisions[1].outcome, "retry-pending(from-state marker not yet visible)")
    t.is_true(result.failure ~= nil, "pending route raises instead of returning a writer disposition")
    t.eq(#result.raises, 0, "pending error emits no writer effect")
  end,

  test_fix_old_observations_are_runtime_bound_to_inventory = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "raw-version mismatch fixture is byte-distinct"
    )
    t.eq(
      transition_version.compare(V_ORDERING_EQUAL_CURRENT, V_ORDERING_EQUAL_INCOMING),
      0,
      "raw-version mismatch fixture is ordering-equal"
    )

    local actual = json_array()
    for _, fixture in ipairs(FIXTURES) do
      local ok, record = pcall(capture_fixture, fixture)
      if not ok then
        error("OLD fix fixture " .. tostring(fixture.expected_reason_code) .. " failed: " .. tostring(record), 0)
      end
      table.insert(actual, record)
    end
    table.sort(actual, function(left, right)
      return left.observation_id < right.observation_id
    end)

    local expected = committed_records()
    local difference = first_difference(actual, expected, "old_behavior_observations[fix]")
    if difference ~= nil or canonical_json(actual) ~= canonical_json(expected) then
      error(
        "runtime-bound OLD fix observation differs at " .. tostring(difference or "canonical-json")
          .. "; runtime_records=" .. canonical_json(actual),
        0
      )
    end
  end,
}
