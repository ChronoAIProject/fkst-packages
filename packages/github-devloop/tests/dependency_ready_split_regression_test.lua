local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local conv_attempts = require("devloop.convergence.attempts")
local t = h.t
local core = h.core
local operator_commands = require("devloop.operator_commands")
local replay_fields = require("devloop.replay_fields")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function command_result(exit_code, stderr, stdout)
  return {
    stdout = stdout or "",
    stderr = stderr or "",
    exit_code = exit_code,
  }
end

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function encode_json_string(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function render_comment(comment)
  local body = comment
  local id = ""
  local created_at = "2026-06-03T01:00:00Z"
  if type(comment) == "table" then
    body = comment.body
    id = comment.id or ""
    created_at = comment.created_at or comment.createdAt or created_at
  end
  return string.format(
    '{"id":"%s","body":"%s","author":{"login":"fkst-test-bot"},"createdAt":"%s"}',
    encode_json_string(id),
    encode_json_string(body or ""),
    encode_json_string(created_at)
  )
end

local function trusted_comment(id, body, created_at)
  return {
    id = id,
    body = body,
    author = { login = "fkst-test-bot" },
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function issue_comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function issue_view_json(labels, comments, state)
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, string.format('{"name":"%s"}', encode_json_string(label)))
  end
  return string.format(
    '{"title":"Implement dependency split","state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    encode_json_string(state or "OPEN"),
    table.concat(rendered_labels, ","),
    issue_comments_json(comments)
  )
end

local function blocked_by_json(nodes)
  local rendered = {}
  local input = nodes or {}
  for _, node in ipairs(input) do
    local state_reason = node.state_reason or node.stateReason or ""
    table.insert(rendered, string.format(
      '{"number":%s,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tostring(node.number),
      encode_json_string(node.state or "OPEN"),
      encode_json_string(state_reason),
      encode_json_string(node.repo or repo)
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#input)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function mock_blocked_by(issue_number, nodes)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), command_result(0, "", blocked_by_json(nodes)))
end

local function mock_blocked_by_failure(issue_number)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), command_result(1, "graphql failed"))
end

local function mock_blocker_issue(issue_number, state_name)
  local comments = {}
  if state_name ~= nil then
    table.insert(comments, h.state_comment(base_ids.proposal_id(repo, issue_number), state_name, "v-" .. tostring(issue_number)))
  end
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), command_result(
    0,
    "",
    '{"state":"OPEN","comments":[' .. issue_comments_json(comments) .. '],"author":{"login":"fkst-test-bot"}}\n'
  ))
end

local function mock_thinking_dependency_wait_with_ready_blocker(current, labels)
  h.mock_issue_result(labels, {
    core.state_marker(current.proposal_id, "thinking", current.dedup_key),
  })
  mock_blocked_by(42, { { number = 51 } })
  mock_blocked_by(51, {})
  mock_blocker_issue(51, "ready")
end

local function mock_observe_issue(labels, comments)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 42,
    labels = labels,
    comments = comments,
    times = 1,
  })
  t.mock_command(core.gh_issue_view_entity_cmd(repo, 42), command_result(0, "", issue_view_json(labels, comments)))
end

local function mock_implement_issue(labels, comments)
  t.mock_command(core.gh_issue_view_implement_cmd(repo, 42), command_result(0, "", issue_view_json(labels, comments)))
end

local function reached()
  return {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal_id,
    decision = "approve",
    body = "Approved.",
    dedup_key = version,
    source_ref = source_ref(),
  }
end

local function ready_at(inner_version)
  return payloads_builders.build_devloop_ready_payload({
    proposal_id = proposal_id,
    dedup_key = inner_version,
    source_ref = source_ref(),
  })
end

local function run_observe()
  return h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = h.issue(),
  }, h.opts("ready-split-regression-observe"))
end

local function run_observe_with_issue(event)
  return h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = event,
  }, h.opts("ready-split-regression-observe-visible"))
end

local function run_implement(payload)
  return h.run_department("departments/implement/main.lua", {
    queue = "devloop_ready",
    payload = payload,
  }, h.opts("ready-split-regression-implement"))
end

local function find_raise(raises, queue, predicate)
  for _, item in ipairs(raises or {}) do
    if item.queue == queue and (predicate == nil or predicate(item.payload)) then
      return item
    end
  end
  return nil
end

local count_queue = require("testkit_internal.raises").count

local function state_comment_request(raises, to_state, to_version)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    if type(payload.body) ~= "string" then
      return false
    end
    local projected = core.current_state({
      trusted_comment("IC_projected_result", payload.body),
    }, proposal_id)
    return projected.state == to_state and projected.version == to_version
  end)
end

local function state_label_request(raises, to_state, to_version)
  return find_raise(raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.require_marker_guard == true
      and payload.expected_state == to_state
      and payload.expected_version == to_version
  end)
end

local function dependency_auxiliary_label_request(raises, change_field)
  change_field = change_field or "add_labels"
  return find_raise(raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.require_marker_guard ~= true
      and h.has_value(payload[change_field], devloop_base._blocked_on_dependency_label)
  end)
end

local function assert_result_projection(raises, to_state, to_version)
  local comment = state_comment_request(raises, to_state, to_version)
  t.is_true(comment ~= nil)
  local direct_label = state_label_request(raises, to_state, to_version)
  local handoff = comment.payload.handoff
  local projected = type(handoff) == "table" and type(handoff.label_request) == "table"
  if projected then
    t.eq(direct_label, nil)
  else
    t.is_true(direct_label ~= nil)
  end
  local label = projected and handoff and handoff.label_request or direct_label.payload
  t.is_true(type(label) == "table")
  t.eq(label.marker_guard.expected.state, to_state)
  t.eq(label.marker_guard.expected.version, to_version)
  return comment.payload, label
end

local function marker_body(raises, needle)
  local raise = find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return type(payload.body) == "string" and payload.body:find(needle, 1, true) ~= nil
  end)
  return raise and raise.payload.body or nil
end

local function assert_ready_split_effects(raises, to_state, to_version, blocked_label_added)
  local effects = to_state == "ready"
    and "result-marker,ready-label,devloop-ready"
    or "ready-split-canonicalized"
  local comment_raise = find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return type(payload.body) == "string"
      and payload.body:find("ready-split-canonicalized:v1", 1, true) ~= nil
  end)
  t.is_true(comment_raise ~= nil)
  local body = comment_raise.payload.body
  t.is_true(body ~= nil)
  t.is_true(body:find(h.state_comment(proposal_id, to_state, to_version, effects), 1, true) ~= nil)

  local direct_label_raise = find_raise(raises, "github-proxy.github_issue_label_request", function(payload)
    return payload.expected_state == to_state and payload.expected_version == to_version
  end)
  t.eq(direct_label_raise, nil)
  local handoff = comment_raise.payload.handoff
  t.is_true(type(handoff) == "table")
  t.eq(handoff.kind, to_state == "ready" and "github-devloop.ready" or "github-devloop.ready-split-label")
  local request = handoff.label_request
  t.is_true(type(request) == "table")
  t.is_true(h.has_value(request.add_labels, "fkst-dev:ready"))
  t.eq(h.has_value(request.add_labels, devloop_base._blocked_on_dependency_label), blocked_label_added)
  t.eq(h.has_value(request.remove_labels, devloop_base._blocked_on_dependency_label), not blocked_label_added)
  t.is_true(h.has_value(request.remove_labels, "fkst-dev:impl-failed"))
  t.eq(request.require_marker_guard, true)
  t.eq(request.expected_proposal_id, proposal_id)
  t.eq(request.expected_state, to_state)
  t.eq(request.expected_version, to_version)
  t.eq(request.marker_guard.match.proposal, proposal_id)
  t.eq(request.marker_guard.expected.state, to_state)
  t.eq(request.marker_guard.expected.version, to_version)
end

local function ready_handoff_comment_raise(raises)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return type(payload.handoff) == "table"
      and payload.handoff.kind == "github-devloop.ready"
  end)
end

local function run_comment_handoff_from_request(request, comment_id, name)
  return h.run_department("departments/comment_handoff/main.lua", {
    queue = "github-proxy.github_comment_written",
    payload = {
      schema = "github-proxy.comment-written.v1",
      repo = request.repo,
      target = "issue",
      issue_number = request.issue_number,
      comment_id = comment_id,
      request_dedup_key = request.dedup_key,
      dedup_key = tostring(request.dedup_key) .. "/written/" .. tostring(comment_id),
      source_ref = request.source_ref,
      handoff = request.handoff,
    },
  }, h.opts(name))
end

local function capture_core_raises(fn)
  local raised = {}
  local original_log_raise = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, {
      queue = queue,
      payload = payload,
    })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original_log_raise
  if not ok then
    error(err)
  end
  return raised
end

local function replay_ready_with_comments(comments)
  return capture_core_raises(function()
    core.replay_ready_state("observe_issue", h.issue(), {
      state = "ready",
      version = version,
      proposal_id = proposal_id,
    }, restart_transition_row("ready"), {
      proposal_id = proposal_id,
      current = {
        labels = { "fkst-dev:enabled", "fkst-dev:ready" },
        comments = comments,
      },
      dependency_gate = {
        kind = "satisfied",
        reason = "test",
      },
    })
  end)
end

return {
  test_marker_only_ready_split_apis_are_not_public = function()
    t.eq(core.ready_split_canonicalized_marker, nil)
    t.eq(core.build_ready_split_canonicalized_comment_request, nil)
  end,

  test_ready_hand_off_comment_id_requires_trusted_visible_ready_marker = function()
    local marker = h.projected_state_comment(proposal_id, "ready", version, "result-marker,ready-label,devloop-ready")
    t.eq(core.ready_hand_off_comment_id({
      trusted_comment("IC_ready_1", marker),
    }, proposal_id, version), "IC_ready_1")
    t.eq(core.ready_hand_off_comment_id({
      {
        id = "IC_forged",
        body = marker,
        author = { login = "not-the-bot" },
      },
    }, proposal_id, version), nil)
    t.eq(core.ready_hand_off_comment_id({
      trusted_comment("IC_missing_effects", h.projected_state_comment(proposal_id, "ready", version)),
    }, proposal_id, version), nil)
  end,

  test_ready_redrive_with_visible_marker_carries_handoff_and_distinct_generation = function()
    local marker = h.projected_state_comment(proposal_id, "ready", version, "result-marker,ready-label,devloop-ready")
    mock_observe_issue({ "fkst-dev:enabled", "fkst-dev:ready" }, {
      trusted_comment("IC_ready_visible", marker),
    })
    mock_blocked_by(42, {})

    local result = run_observe_with_issue(h.issue())
    t.eq(result.exit_code, 0)
    local ready = find_raise(result.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.ready_hand_off.comment_id, "IC_ready_visible")
    t.eq(ready.payload.ready_hand_off.marker_version, version)
    t.eq(ready.payload.ready_hand_off.event_version, ready.payload.dedup_key)
    t.is_true(ready.payload.dedup_key ~= payloads_builders.build_devloop_ready_payload({
      proposal_id = proposal_id,
      dedup_key = version,
      source_ref = source_ref(),
    }).dedup_key)
    t.is_true(ready.payload.dedup_key:find("/redrive/ready/1", 1, true) ~= nil)
  end,

  test_ready_redrive_generation_advances_with_timeout_attempt_markers = function()
    local marker_version = version
    local marker = h.projected_state_comment(proposal_id, "ready", marker_version, "result-marker,ready-label,devloop-ready")
    local attempt_1 = conv_attempts.timeout_attempt_marker(proposal_id, marker_version, "ready", 1, source_ref())
    local first_raises = replay_ready_with_comments({
      trusted_comment("IC_ready_visible", marker),
      trusted_comment("IC_timeout_1", attempt_1, "2026-06-03T01:01:00Z"),
    })

    local first_ready = find_raise(first_raises, "devloop_ready")
    t.eq(first_ready ~= nil, true)
    t.eq(first_ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload({
      proposal_id = proposal_id,
      dedup_key = marker_version .. "/redrive/ready/2",
      source_ref = source_ref(),
    }).dedup_key)
    t.eq(first_ready.payload.ready_hand_off.marker_version, marker_version)
    t.eq(first_ready.payload.ready_hand_off.event_version, first_ready.payload.dedup_key)

    local attempt_2 = conv_attempts.timeout_attempt_marker(proposal_id, marker_version, "ready", 2, source_ref())
    local second_raises = replay_ready_with_comments({
      trusted_comment("IC_ready_visible", marker),
      trusted_comment("IC_timeout_1", attempt_1, "2026-06-03T01:01:00Z"),
      trusted_comment("IC_timeout_2", attempt_2, "2026-06-03T01:02:00Z"),
    })

    local second_ready = find_raise(second_raises, "devloop_ready")
    t.eq(second_ready ~= nil, true)
    t.eq(second_ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload({
      proposal_id = proposal_id,
      dedup_key = marker_version .. "/redrive/ready/3",
      source_ref = source_ref(),
    }).dedup_key)
    t.eq(second_ready.payload.ready_hand_off.comment_id, "IC_ready_visible")
    t.eq(second_ready.payload.ready_hand_off.marker_version, marker_version)
    t.eq(second_ready.payload.ready_hand_off.event_version, second_ready.payload.dedup_key)
    t.eq(first_ready.payload.dedup_key == second_ready.payload.dedup_key, false)
  end,

  test_ready_redrive_generation_advances_after_accepted_reready_response = function()
    local marker = h.projected_state_comment(proposal_id, "ready", version, "result-marker,ready-label,devloop-ready")
    local command = {
      command = "reready",
      key = "operator-command/IC_reready_ready",
    }
    local accepted = operator_commands.operator_command_marker(command, "applied", "ready")
    local raises = replay_ready_with_comments({
      trusted_comment("IC_ready_visible", marker),
      trusted_comment("IC_reready_response", accepted, "2026-06-03T01:01:00Z"),
    })

    local ready = find_raise(raises, "devloop_ready")
    t.eq(ready ~= nil, true)
    t.eq(ready.payload.ready_hand_off.comment_id, "IC_ready_visible")
    t.eq(ready.payload.ready_hand_off.marker_version, version)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload({
      proposal_id = proposal_id,
      dedup_key = version .. "/redrive/ready/2",
      source_ref = source_ref(),
    }).dedup_key)
  end,

  test_ready_replay_ignores_prebuilt_payload_without_hand_off = function()
    local marker_version = version
    local marker = h.projected_state_comment(proposal_id, "ready", marker_version, "result-marker,ready-label,devloop-ready")
    local raises = capture_core_raises(function()
      core.replay_ready_state("observe_issue", h.issue(), {
        state = "ready",
        version = marker_version,
        proposal_id = proposal_id,
      }, restart_transition_row("ready"), {
        proposal_id = proposal_id,
        current = {
          labels = { "fkst-dev:enabled", "fkst-dev:ready" },
          comments = {
            trusted_comment("IC_ready_visible", marker),
            trusted_comment(
              "IC_timeout_1",
              conv_attempts.timeout_attempt_marker(proposal_id, marker_version, "ready", 1, source_ref()),
              "2026-06-03T01:01:00Z"
            ),
          },
        },
        dependency_gate = {
          kind = "satisfied",
          reason = "test",
        },
        ready_payload = payloads_builders.build_devloop_ready_payload({
          proposal_id = proposal_id,
          dedup_key = marker_version .. "/stale-bypass",
          source_ref = source_ref(),
        }),
      })
    end)

    local ready = find_raise(raises, "devloop_ready")
    t.eq(ready ~= nil, true)
    t.eq(ready.payload.ready_hand_off.comment_id, "IC_ready_visible")
    t.eq(ready.payload.ready_hand_off.marker_version, marker_version)
    t.eq(ready.payload.ready_hand_off.event_version, ready.payload.dedup_key)
    t.eq(ready.payload.dedup_key, payloads_builders.build_devloop_ready_payload({
      proposal_id = proposal_id,
      dedup_key = marker_version .. "/redrive/ready/2",
      source_ref = source_ref(),
    }).dedup_key)
  end,

  test_ready_redrive_without_visible_ready_marker_fails_closed = function()
    mock_observe_issue({ "fkst-dev:enabled", "fkst-dev:ready" }, {
      h.projected_state_comment(proposal_id, "ready", version),
    })
    mock_blocked_by(42, {})

    local result = run_observe_with_issue(h.issue())
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_implement_backstop_split_generation_uses_inner_ready_version = function()
    local split_version = core.ready_split_version(version)
    local ready = ready_at(split_version)
    mock_blocked_by(42, { { number = 55 } })
    mock_blocked_by(55, {})
    mock_implement_issue({ "fkst-dev:impl-failed" }, {
      h.projected_state_comment(proposal_id, "ready", split_version),
    })

    local result = run_implement(ready)
    t.eq(result.exit_code, 0)
    t.eq(count_queue(result.raises, "github-proxy.github_issue_comment_request"), 1)
    t.eq(count_queue(result.raises, "github-proxy.github_issue_label_request"), 0)
    local body = marker_body(result.raises, "ready-split-canonicalized:v1")
    local inner_version = core.ready_payload_inner_version(ready.dedup_key)
    local next_split_version = core.ready_split_version(inner_version)
    t.is_true(body ~= nil)
    t.is_true(body:find('from_version="' .. inner_version .. '"', 1, true) ~= nil)
    t.is_true(body:find('to_version="' .. next_split_version .. '"', 1, true) ~= nil)
    t.is_true(body:find('to_version="ready/', 1, true) == nil)
    t.is_true(body:find('state="dependency_wait"', 1, true) ~= nil)
    assert_ready_split_effects(result.raises, "dependency_wait", next_split_version, true)
  end,

  test_ready_replay_dependency_hold_projects_guarded_state_and_auxiliary_labels = function()
    mock_observe_issue({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, {
      trusted_comment("IC_ready_visible", h.projected_state_comment(proposal_id, "ready", version)),
    })
    mock_blocked_by(42, { { number = 55 } })
    mock_blocked_by(55, {})

    local result = run_observe_with_issue(h.issue())
    t.eq(result.exit_code, 0)
    local split_version = core.ready_split_version(version)
    assert_ready_split_effects(result.raises, "dependency_wait", split_version, true)

    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return type(payload.body) == "string"
        and payload.body:find('state="dependency_wait"', 1, true) ~= nil
    end)
    local handoff = run_comment_handoff_from_request(
      comment.payload,
      "IC_dependency_wait_split",
      "ready-split-regression-dependency-wait-comment-handoff"
    )
    t.eq(handoff.exit_code, 0)
    t.eq(find_raise(handoff.raises, "devloop_ready"), nil)
    local label = state_label_request(handoff.raises, "dependency_wait", split_version)
    t.is_true(label ~= nil)
    t.is_true(h.has_value(label.payload.add_labels, devloop_base._blocked_on_dependency_label))
  end,

  test_ready_reconcile_clears_stale_dependency_label_from_satisfied_gate = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:ready", devloop_base._blocked_on_dependency_label },
      {
        trusted_comment("IC_ready_visible", h.projected_state_comment(
          proposal_id, "ready", version, "result-marker,ready-label,devloop-ready"
        )),
      }
    )
    mock_blocked_by(42, {})

    local result = run_observe()
    t.eq(result.exit_code, 0)
    local auxiliary = dependency_auxiliary_label_request(result.raises, "remove_labels")
    t.is_true(auxiliary ~= nil)
    t.eq(h.has_value(auxiliary.payload.add_labels, devloop_base._blocked_on_dependency_label), false)
    t.eq(h.count_calls(core.gh_blocked_by_cmd(repo, 42)), 1)
  end,

  test_ready_reconcile_does_not_clear_dependency_label_for_active_gate = function()
    mock_observe_issue({
      "fkst-dev:enabled", "fkst-dev:ready", devloop_base._blocked_on_dependency_label,
    }, {
      trusted_comment("IC_ready_visible", h.projected_state_comment(proposal_id, "ready", version)),
    })
    mock_blocked_by(42, { { number = 55 } })
    mock_blocked_by(55, {})

    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(dependency_auxiliary_label_request(result.raises, "remove_labels"), nil)
    assert_ready_split_effects(result.raises, "dependency_wait", core.ready_split_version(version), true)
    t.eq(h.count_calls(core.gh_blocked_by_cmd(repo, 42)), 1)
  end,

  test_legacy_ready_unresolvable_hold_canonicalizes_to_dependency_wait = function()
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:impl-failed", "fkst-dev:blocked-on-dependency" },
      {
        h.projected_state_comment(proposal_id, "ready", version),
        "github-devloop dependency hold: unresolvable\n\nReason: gh-failed\n\n"
          .. core.dependency_unresolvable_marker(proposal_id, version, { 42 }),
      }
    )
    mock_blocked_by_failure(42)

    local result = run_observe()
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local split_version = core.ready_split_version(version)
    local body = marker_body(result.raises, "ready-split-canonicalized:v1")
    t.is_true(body ~= nil)
    t.is_true(body:find('derived_state="dependency_wait"', 1, true) ~= nil)
    t.is_true(body:find('state="dependency_wait"', 1, true) ~= nil)
    t.is_true(body:find('version="' .. split_version .. '"', 1, true) ~= nil)
    t.is_true(body:find("fkst:github-devloop:dependency-wait:v1", 1, true) ~= nil)
    assert_ready_split_effects(result.raises, "dependency_wait", split_version, true)
  end,

  test_consensus_result_reraises_partial_dependency_wait_effects = function()
    local current = reached()
    h.mock_issue_result({ "fkst-dev:enabled", "fkst-dev:blocked-on-dependency" }, {
      h.projected_state_comment(current.proposal_id, "dependency_wait", current.dedup_key),
      m_builders.result_marker(current.proposal_id, current.decision, current.dedup_key),
      "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
        .. core.dependency_wait_marker(current.proposal_id, current.dedup_key, { 51 }),
    })
    mock_blocked_by(42, { { number = 51 } })
    mock_blocked_by(51, {})
    mock_blocker_issue(51, "ready")

    local result = h.run_result(current, h.opts("ready-split-regression-result"))
    t.eq(result.exit_code, 0)
    local label = state_label_request(result.raises, "dependency_wait", current.dedup_key)
    t.is_true(label ~= nil)
    t.is_true(h.has_value(label.payload.add_labels, "fkst-dev:ready"))
    t.is_true(h.has_value(label.payload.remove_labels, "fkst-dev:impl-failed"))
    t.eq(h.has_value(label.payload.remove_labels, devloop_base._blocked_on_dependency_label), false)
    t.eq(state_comment_request(result.raises, "dependency_wait", current.dedup_key), nil)
    t.eq(dependency_auxiliary_label_request(result.raises), nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_consensus_result_dependency_wait_projects_the_committed_target = function()
    local current = reached()
    mock_thinking_dependency_wait_with_ready_blocker(current, { "fkst-dev:thinking", "fkst-dev:impl-failed" })

    local result = h.run_result(current, h.opts("ready-split-regression-result-target-dependency-wait"))
    t.eq(result.exit_code, 0)
    local _, label = assert_result_projection(result.raises, "dependency_wait", current.dedup_key)
    t.is_true(h.has_value(label.add_labels, "fkst-dev:ready"))
    t.is_true(h.has_value(label.remove_labels, "fkst-dev:impl-failed"))
    t.eq(h.has_value(label.remove_labels, devloop_base._blocked_on_dependency_label), false)
    t.is_true(dependency_auxiliary_label_request(result.raises) ~= nil)
  end,

  test_consensus_result_dependency_wait_comment_hands_off_only_the_label_projection = function()
    local current = reached()
    mock_thinking_dependency_wait_with_ready_blocker(current, { "fkst-dev:thinking" })

    local result = h.run_result(current, h.opts("ready-split-regression-result-hold-handoff"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local result_comment = find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
      return type(payload.body) == "string"
        and payload.body:find('state="dependency_wait"', 1, true) ~= nil
        and payload.body:find("fkst:github-devloop:result:v1", 1, true) ~= nil
    end)
    t.is_true(result_comment ~= nil)
    t.eq(result_comment.payload.handoff.kind, "github-devloop.ready-split-label")

    local handoff = run_comment_handoff_from_request(
      result_comment.payload,
      "IC_dependency_hold_result",
      "ready-split-regression-result-hold-comment-handoff"
    )
    t.eq(handoff.exit_code, 0)
    t.eq(find_raise(handoff.raises, "devloop_ready"), nil)
    t.is_true(state_label_request(handoff.raises, "dependency_wait", current.dedup_key) ~= nil)
  end,

  test_consensus_result_ready_comment_keeps_ready_handoff = function()
    local current = reached()
    h.mock_issue_result({ "fkst-dev:thinking" }, {
      core.state_marker(current.proposal_id, "thinking", current.dedup_key),
    })
    mock_blocked_by(42, {})

    local result = h.run_result(current, h.opts("ready-split-regression-result-ready-handoff"))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local _, label = assert_result_projection(result.raises, "ready", current.dedup_key)
    t.is_true(h.has_value(label.add_labels, "fkst-dev:ready"))
    t.is_true(h.has_value(label.remove_labels, devloop_base._blocked_on_dependency_label))
    local result_comment = ready_handoff_comment_raise(result.raises)
    t.is_true(result_comment ~= nil)
    t.eq(result_comment.payload.handoff.proposal_id, current.proposal_id)
    t.eq(result_comment.payload.handoff.version, current.dedup_key)
    t.eq(result_comment.payload.handoff.marker_version, current.dedup_key)

    local handoff = run_comment_handoff_from_request(
      result_comment.payload,
      "IC_ready_result",
      "ready-split-regression-result-ready-comment-handoff"
    )
    t.eq(handoff.exit_code, 0)
    local ready = find_raise(handoff.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.ready_hand_off.comment_id, "IC_ready_result")
    t.eq(ready.payload.ready_hand_off.marker_version, current.dedup_key)
  end,

  test_consensus_result_declined_projects_the_committed_target_without_dependency_changes = function()
    local current = reached()
    current.decision = "reject"
    current.decision_reason = "premise-refuted"
    h.mock_issue_result({ "fkst-dev:thinking", "fkst-dev:blocked-on-dependency" }, {
      core.state_marker(current.proposal_id, "thinking", current.dedup_key),
    })

    local result = h.run_result(current, h.opts("ready-split-regression-result-target-declined"))
    t.eq(result.exit_code, 0)
    local _, label = assert_result_projection(result.raises, "declined", current.dedup_key)
    t.is_true(h.has_value(label.add_labels, "fkst-dev:declined"))
    t.eq(h.has_value(label.remove_labels, devloop_base._blocked_on_dependency_label), false)
    t.eq(dependency_auxiliary_label_request(result.raises), nil)
  end,

  test_dependency_release_ready_handoff_accepts_direct_visible_marker = function()
    local split_version = core.ready_split_version(version)
    mock_observe_issue(
      { "fkst-dev:enabled", "fkst-dev:impl-failed", "fkst-dev:blocked-on-dependency" },
      {
        h.projected_state_comment(proposal_id, "dependency_wait", version),
        "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
          .. core.dependency_wait_marker(proposal_id, version, { 53 }),
      }
    )
    mock_blocked_by(42, { { number = 53 } })
    mock_blocked_by(53, {})
    mock_blocker_issue(53, "merged")

    local released = run_observe()
    t.eq(released.exit_code, 0)
    t.eq(find_raise(released.raises, "devloop_ready"), nil)
    local release_comment = ready_handoff_comment_raise(released.raises)
    t.is_true(release_comment ~= nil)
    t.eq(release_comment.payload.handoff.marker_version, split_version)
    t.is_true(release_comment.payload.body:find(
      h.projected_state_comment(proposal_id, "ready", split_version, "result-marker,ready-label,devloop-ready"),
      1,
      true
    ) ~= nil)
    t.is_true(release_comment.payload.body:find("fkst:github-devloop:ready-split-canonicalized:v1", 1, true) ~= nil)
    assert_ready_split_effects(released.raises, "ready", split_version, false)

    local handoff = run_comment_handoff_from_request(
      release_comment.payload,
      "IC_dependency_release_ready",
      "ready-split-regression-release-comment-handoff"
    )
    t.eq(handoff.exit_code, 0)
    local label = state_label_request(handoff.raises, "ready", split_version)
    t.is_true(label ~= nil)
    t.is_true(h.has_value(label.payload.remove_labels, devloop_base._blocked_on_dependency_label))
    local ready = find_raise(handoff.raises, "devloop_ready")
    t.is_true(ready ~= nil)
    t.eq(ready.payload.ready_hand_off.comment_id, "IC_dependency_release_ready")
    t.eq(ready.payload.ready_hand_off.marker_version, split_version)

    local branch = devloop_base.implement_branch(repo, 42, ready.payload.dedup_key)
    mock_implement_issue({ "fkst-dev:ready" }, {
      h.projected_state_comment(proposal_id, "dependency_wait", version),
    })
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_dependency_release_ready'", command_result(
      0,
      "",
      '{"body":"' .. encode_json_string(release_comment.payload.body) .. '","user":{"login":"fkst-test-bot"}}\n'
    ))
    h.mock_fresh_implement_worktree({ impl_version = ready.payload.dedup_key })
    h.mock_implement_codex(0, "implemented")
    h.mock_git_status(" M packages/github-devloop/core/ready_split.lua\n")
    h.mock_git_commit("def456", branch)
    mock_implement_issue({ "fkst-dev:ready" }, {
      h.projected_state_comment(proposal_id, "dependency_wait", version),
    })
    mock_implement_issue({ "fkst-dev:ready" }, {
      h.projected_state_comment(proposal_id, "dependency_wait", version),
    })

    local implemented = h.run_implement(ready.payload, h.opts("ready-split-regression-release-implement"))
    t.eq(implemented.exit_code, 0)
    t.eq(count_queue(implemented.raises, "github-proxy.github_issue_label_request"), 1)
    t.eq(find_raise(implemented.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:implementing")
    t.eq(h.count_calls("repos/owner/repo/issues/comments/IC_dependency_release_ready"), 1)
    t.eq(h.count_calls("codex exec"), 1)
  end,

  -- The dependency backstop in departments/implement/main.lua runs BEFORE the
  -- `state.state == "implementing"` skip-stale guard. A redelivered devloop_ready
  -- for an issue that already advanced to `implementing` must not be pulled back
  -- into the ready-phase `dependency_wait` gate: that is a phase-rank regression
  -- with no generation bump, and a transient blocker read failure (gh-failed) is
  -- precisely when it fires.
  test_implementing_is_not_regressed_to_dependency_wait_when_blocker_read_fails = function()
    local ready = ready_at(version)
    local implementing_version = core.implementation_attempt_version(ready.dedup_key)
    local branch = h.deterministic_branch_for(ready)
    local delegation = "g" .. tostring(core.implementation_delegation_generation(implementing_version))
    mock_blocked_by_failure(42)
    local implementing_comments = {
      h.projected_state_comment(proposal_id, "ready", version),
      core.state_marker(proposal_id, "implementing", implementing_version),
      core.implement_attempt_marker(proposal_id, implementing_version, 1, "2026-06-03T01:01:00Z"),
      m_builders.implementing_marker(proposal_id, implementing_version, branch, "def456", "dev", "abc123"),
      m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/7",
        7,
        implementing_version,
        delegation
      ),
    }
    mock_implement_issue({ "fkst-dev:enabled", "fkst-dev:implementing" }, implementing_comments)
    mock_implement_issue({ "fkst-dev:enabled", "fkst-dev:implementing" }, implementing_comments)
    t.mock_command("git fetch 'origin' '" .. branch .. "'", command_result(0))
    t.mock_command("refs/remotes/'origin'/'" .. branch .. "'^{commit}", command_result(0, "", "def456\n"))

    local result = h.run_implement(ready, h.opts("ready-split-regression-advanced-implement"))
    t.eq(result.exit_code, 0)
    t.eq(marker_body(result.raises, "ready-split-canonicalized:v1"), nil)
    t.eq(marker_body(result.raises, "dependency-wait:v1"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(h.count_calls(core.gh_blocked_by_cmd(repo, 42)), 0)
  end,

  test_all_lifecycle_states_have_positive_stage_rank = function()
    for state_name in pairs(devloop_state.lifecycle_state_set()) do
      t.is_true(devloop_state.stage_rank(state_name) > 0)
    end
  end,
}
