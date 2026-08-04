local awaiting_pr_replayer = require("awaiting_pr_replay")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local projection = require("tests.projection_outcome_helpers")
local replay_fields = require("devloop.replay_fields")
local testing = require("testkit_internal.testing")
local dependency_fixtures = require("tests.dependency_cascade_helpers")

local t = h.t
local core = h.core
local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local awaiting_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local blocked_label = "fkst-dev:blocked-on-dependency"
local ready_add = { "fkst-dev:ready" }
local ready_state_removes = {
  "fkst-dev:awaiting-pr",
  "fkst-dev:blocked",
  "fkst-dev:declined",
  "fkst-dev:fixing",
  "fkst-dev:impl-failed",
  "fkst-dev:implementing",
  "fkst-dev:merge-ready",
  "fkst-dev:merged",
  "fkst-dev:merging",
  "fkst-dev:pr-open",
  "fkst-dev:review-meta",
  "fkst-dev:reviewing",
  "fkst-dev:thinking",
}

local function source_ref()
  return entity_lib.issue_source_ref(repo, issue_number)
end

local function issue()
  return {
    repo = repo,
    number = issue_number,
    source_ref = source_ref(),
  }
end

local function trusted_comment(id, body, created_at)
  return {
    id = id,
    body = body,
    author_login = core._test_bot_login,
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
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

local function mock_blocked_by(number, nodes)
  local fixtures = {}
  for _, node in ipairs(nodes or {}) do
    fixtures[#fixtures + 1] = { number = node }
  end
  dependency_fixtures.mock_blocked_by(number, fixtures)
end

local function mock_consensus(blocked)
  h.mock_issue_result({ "fkst-dev:thinking", "fkst-dev:impl-failed" }, {
    core.state_marker(proposal_id, "thinking", version),
  })
  if blocked then
    mock_blocked_by(issue_number, { 51 })
    mock_blocked_by(51, {})
    dependency_fixtures.mock_blocker_issue(51, "ready")
  else
    mock_blocked_by(issue_number, {})
  end
end

local function guarded_projection(outcome, state, marker_version)
  for _, label in ipairs(outcome.label_projections) do
    if label.guarded
      and label.proposal_id == proposal_id
      and label.state == state
      and label.version == marker_version then
      return label
    end
  end
  return nil
end

local function auxiliary_dependency_add(outcome)
  for _, label in ipairs(outcome.label_projections) do
    if not label.guarded and projection.has_value(label.add_labels, blocked_label) then
      return label
    end
  end
  return nil
end

local function assert_single_state(outcome, state, marker_version)
  t.eq(#outcome.state_facts, 1)
  t.eq(outcome.state_facts[1].state, state)
  t.eq(outcome.state_facts[1].version, marker_version)
end

local function assert_label_sets(label, add_labels, remove_labels, context)
  t.eq(
    projection.set_key(label.add_labels),
    projection.set_key(add_labels),
    context .. " add_labels"
  )
  t.eq(
    projection.set_key(label.remove_labels),
    projection.set_key(remove_labels),
    context .. " remove_labels"
  )
end

local function with_value(values, value)
  local out = {}
  for _, item in ipairs(values) do out[#out + 1] = item end
  out[#out + 1] = value
  return out
end

local function assert_ready_activation(outcome, marker_version, comment_id)
  t.eq(#outcome.lifecycle_activations, 1)
  local activation = outcome.lifecycle_activations[1]
  t.eq(activation.proposal_id, proposal_id)
  t.eq(activation.marker_version, marker_version)
  if comment_id ~= nil then t.eq(activation.comment_id, comment_id) end
  t.is_true(
    projection.activation_has_marker_evidence(outcome, activation),
    "ready activation must reference an acknowledged or visible marker comment"
  )
end

local function queue_summary(outcome)
  local queues = {}
  for _, raised in ipairs(outcome.normalized_raises or {}) do
    queues[#queues + 1] = tostring(raised.queue)
  end
  table.sort(queues)
  return table.concat(queues, ",")
end

local function run_core_replay(state_name, facts)
  local state = {
    state = state_name,
    version = version,
    proposal_id = proposal_id,
  }
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
  return testing.run_fake({
    pipeline = function()
      if state_name == "ready" then
        return core.replay_ready_state("observe_issue", issue(), state, row, facts)
      end
      return core.replay_dependency_wait_state("observe_issue", issue(), state, row, facts)
    end,
  }, {
    queue = "github-proxy.github_entity_changed",
    payload = h.issue(),
  })
end

local function ready_to_dependency_wait()
  return run_core_replay("ready", {
    proposal_id = proposal_id,
    current = {
      labels = { "fkst-dev:enabled", "fkst-dev:ready" },
      comments = { trusted_comment("IC_ready_input", core.state_marker(proposal_id, "ready", version)) },
    },
    dependency_gate = {
      ok = false,
      kind = "waiting",
      reason = "waiting-on-dependency",
      unmet = { 51 },
    },
  })
end

local function dependency_wait_to_ready()
  return run_core_replay("dependency_wait", {
    proposal_id = proposal_id,
    current = {
      labels = { "fkst-dev:enabled", "fkst-dev:ready", blocked_label },
      comments = {
        trusted_comment("IC_dependency_input", core.state_marker(proposal_id, "dependency_wait", version)),
      },
    },
    dependency_gate = {
      ok = true,
      kind = "satisfied",
      reason = "dependencies-satisfied",
      unmet = {},
    },
    ["dependency-release"] = {},
  })
end

local function awaiting_pr_closed_unmerged()
  local pr_number = 7
  local child_proposal = entity_lib.pr_proposal_id(repo, pr_number)
  local delegation = "g1"
  local branch = devloop_base.implement_branch(repo, issue_number, core.implementation_base_version(awaiting_version))
  local parent_issue = issue()
  parent_issue.comments = {
    trusted_comment("IC_awaiting", core.state_marker(proposal_id, "awaiting-pr", awaiting_version)),
    trusted_comment("IC_delegation", m_builders.pr_delegation_marker(
      proposal_id, child_proposal, pr_number, awaiting_version, delegation
    )),
  }
  local current_pr = {
    force_fresh = true,
    number = pr_number,
    state = "CLOSED",
    comments = {
      trusted_comment("IC_origin", m_builders.pr_origin_marker(
        proposal_id, issue_number, branch, awaiting_version, "integration/dev"
      )),
      trusted_comment("IC_child_closed", core.state_marker(
        proposal_id, "closed-unmerged", awaiting_version
      )),
    },
    head_ref_name = branch,
    base_ref_name = "integration/dev",
    head_sha = "0123456789abcdef0123456789abcdef01234567",
    status_check_rollup = {},
  }
  local state = { state = "awaiting-pr", version = awaiting_version }
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), "awaiting-pr")
  local original_branch_config = config.branch_config
  local original_write_mode = config.write_mode
  config.branch_config = function()
    return { integration = "integration/dev", upstream = "dev" }
  end
  config.write_mode = function() return "dry-run" end
  local ok, result = pcall(function()
    return testing.run_fake({
      pipeline = function()
        return awaiting_pr_replayer["awaiting-pr"]("observe_issue", parent_issue, state, row, {
          proposal_id = proposal_id,
          current_pr = current_pr,
          child_state = { state = "closed-unmerged", version = awaiting_version },
          ["pr-delegation"] = {
            proposal_id = proposal_id,
            pr_proposal_id = child_proposal,
            pr_number = pr_number,
            version = awaiting_version,
            delegation = delegation,
          },
        })
      end,
    }, { queue = "github-proxy.github_entity_changed", payload = h.issue() })
  end)
  config.write_mode = original_write_mode
  config.branch_config = original_branch_config
  if not ok then error(result) end
  return result
end

local function fresh_ready_comment(id)
  return trusted_comment(
    id,
    core.state_marker(proposal_id, "ready", version, "result-marker,ready-label,devloop-ready"),
    os.date("!%Y-%m-%dT%H:%M:%SZ", now())
  )
end

local function assert_projection_repair(labels, name, visible_id, stale_label)
  local visible = fresh_ready_comment(visible_id)
  h.mock_issue_state(labels, "OPEN", { visible })
  mock_blocked_by(issue_number, {})
  local observed = h.run_observe(h.issue({ labels = labels }), h.opts(name))
  t.eq(observed.exit_code, 0)
  local outcome = projection.collect(observed.raises, {
    proposal_id = proposal_id,
    visible_comments = { visible },
    comment_id_prefix = visible_id .. "_repair",
    name = name .. "-handoff",
  })
  assert_single_state(outcome, "ready", version)
  local label = guarded_projection(outcome, "ready", version)
  t.is_true(label ~= nil, "repair must emit guarded ready projection; queues=" .. queue_summary(outcome))
  assert_label_sets(
    label,
    ready_add,
    stale_label == nil and {} or { stale_label },
    "ready projection repair"
  )
  assert_ready_activation(outcome, version, visible.id)
end

return {
  test_consensus_ready_projection_is_observable_after_comment_ack = function()
    mock_consensus(false)
    local result = h.run_result(reached(), h.opts("projection-outcome-consensus-ready"))
    t.eq(result.exit_code, 0)
    local outcome = projection.collect(result.raises, {
      proposal_id = proposal_id,
      result_identity = version,
      comment_id_prefix = "IC_projection_consensus_ready",
      name = "projection-outcome-consensus-ready-handoff",
    })

    assert_single_state(outcome, "ready", version)
    t.eq(#outcome.result_facts, 1)
    t.eq(outcome.result_facts[1].decision, "approve")
    t.eq(outcome.result_facts[1].logical_identity, version)
    local label = guarded_projection(outcome, "ready", version)
    t.is_true(label ~= nil)
    assert_label_sets(label, ready_add, with_value(ready_state_removes, blocked_label), "consensus ready")
    assert_ready_activation(outcome, version)
  end,

  test_ready_activation_rejects_acknowledged_non_marker_comment = function()
    local marker_comment_id = "IC_projection_authoritative_ready"
    local unrelated_comment_id = "IC_projection_unrelated_handoff"
    local outcome = {
      state_facts = {
        { state = "ready", version = version, comment_id = marker_comment_id },
      },
      lifecycle_activations = {
        {
          proposal_id = proposal_id,
          marker_version = version,
          comment_id = unrelated_comment_id,
        },
      },
      acked_comment_ids = {
        [marker_comment_id] = true,
        [unrelated_comment_id] = true,
      },
      visible_comment_ids = {},
    }

    t.raises(function()
      assert_ready_activation(outcome, version)
    end)
  end,

  test_consensus_dependency_wait_projection_has_result_and_no_activation = function()
    mock_consensus(true)
    local result = h.run_result(reached(), h.opts("projection-outcome-consensus-dependency-wait"))
    t.eq(result.exit_code, 0)
    local outcome = projection.collect(result.raises, {
      proposal_id = proposal_id,
      result_identity = version,
      comment_id_prefix = "IC_projection_consensus_dependency",
      name = "projection-outcome-consensus-dependency-handoff",
    })

    assert_single_state(outcome, "dependency_wait", version)
    t.eq(#outcome.result_facts, 1)
    t.eq(outcome.result_facts[1].decision, "approve")
    t.eq(outcome.result_facts[1].logical_identity, version)
    local label = guarded_projection(outcome, "dependency_wait", version)
    t.is_true(label ~= nil)
    assert_label_sets(label, ready_add, ready_state_removes, "consensus dependency_wait")
    local auxiliary = auxiliary_dependency_add(outcome)
    t.is_true(auxiliary ~= nil)
    assert_label_sets(auxiliary, { blocked_label }, {}, "consensus dependency auxiliary")
    t.eq(#outcome.lifecycle_activations, 0)
  end,

  test_ready_split_replay_projects_both_directions_through_ack = function()
    local held = ready_to_dependency_wait()
    local held_version = core.ready_split_version(version)
    local held_outcome = projection.collect(held.raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_ready_held",
      name = "projection-outcome-ready-held-handoff",
    })
    assert_single_state(held_outcome, "dependency_wait", held_version)
    local held_label = guarded_projection(held_outcome, "dependency_wait", held_version)
    t.is_true(held_label ~= nil)
    assert_label_sets(
      held_label,
      { "fkst-dev:ready", blocked_label },
      ready_state_removes,
      "ready split dependency_wait"
    )
    t.eq(#held_outcome.lifecycle_activations, 0)

    local released = dependency_wait_to_ready()
    local released_version = core.ready_split_version(version)
    local released_outcome = projection.collect(released.raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_dependency_released",
      name = "projection-outcome-dependency-released-handoff",
    })
    assert_single_state(released_outcome, "ready", released_version)
    local released_label = guarded_projection(released_outcome, "ready", released_version)
    t.is_true(released_label ~= nil)
    assert_label_sets(
      released_label,
      ready_add,
      with_value(ready_state_removes, blocked_label),
      "dependency release ready"
    )
    assert_ready_activation(released_outcome, released_version)
  end,

  test_awaiting_pr_closed_unmerged_resume_projects_replacement_ready = function()
    local result = awaiting_pr_closed_unmerged()
    local replacement_version = awaiting_version .. "/reimplement/1"
    local outcome = projection.collect(result.raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_awaiting_resume",
      name = "projection-outcome-awaiting-resume-handoff",
    })

    assert_single_state(outcome, "ready", replacement_version)
    local label = guarded_projection(outcome, "ready", replacement_version)
    t.is_true(label ~= nil)
    assert_label_sets(label, ready_add, ready_state_removes, "awaiting-pr replacement ready")
    assert_ready_activation(outcome, replacement_version)
  end,

  test_visible_ready_marker_repairs_missing_projection_without_unbound_activation = function()
    assert_projection_repair(
      { "fkst-dev:enabled" },
      "projection-outcome-repair-missing",
      "IC_projection_visible_ready_missing"
    )
  end,

  test_visible_ready_marker_repairs_stale_projection_without_unbound_activation = function()
    assert_projection_repair(
      { "fkst-dev:enabled", "fkst-dev:thinking" },
      "projection-outcome-repair-stale",
      "IC_projection_visible_ready_stale",
      "fkst-dev:thinking"
    )
  end,

  test_comment_handoff_rejects_each_mismatched_guard_identity = function()
    local split = dependency_wait_to_ready()
    local request = nil
    for _, raised in ipairs(split.raises) do
      if raised.queue == "github-proxy.github_issue_comment_request"
        and type(raised.payload.handoff) == "table" then
        request = raised.payload
      end
    end
    t.is_true(request ~= nil)
    local mutations = {
      function(value) value.handoff.label_request.expected_proposal_id = proposal_id .. "/other" end,
      function(value) value.handoff.label_request.expected_state = "dependency_wait" end,
      function(value) value.handoff.label_request.expected_version = version .. "/other" end,
      function(value) value.handoff.label_request.marker_guard.match.proposal = proposal_id .. "/other" end,
      function(value) value.handoff.label_request.marker_guard.expected.state = "dependency_wait" end,
      function(value) value.handoff.label_request.marker_guard.expected.version = version .. "/other" end,
      function(value) value.handoff.label_request.marker_guard.marker_target.kind = "pr" end,
      function(value) value.handoff.label_request.marker_guard.marker_target.number = 43 end,
      function(value) value.handoff.label_request.repo = "owner/other" end,
      function(value) value.handoff.label_request.issue_number = 43 end,
      function(value) value.handoff.label_request.target_kind = "pr" end,
      function(value) value.handoff.label_request.target_number = 43 end,
    }
    for index, mutate in ipairs(mutations) do
      local mismatched = projection.copy(request)
      mutate(mismatched)
      local outcome = projection.collect({
        { queue = "github-proxy.github_issue_comment_request", payload = mismatched },
      }, {
        proposal_id = proposal_id,
        comment_id_prefix = "IC_projection_rejected_" .. tostring(index),
        name = "projection-outcome-rejected-handoff-" .. tostring(index),
      })
      t.eq(#outcome.label_projections, 0)
      t.eq(#outcome.lifecycle_activations, 0)
    end
  end,

  test_duplicate_transition_and_ack_normalize_to_stable_semantic_identities = function()
    local first = dependency_wait_to_ready()
    local second = dependency_wait_to_ready()
    local first_outcome = projection.collect(first.raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_idempotent",
      name = "projection-outcome-idempotent-first-handoff",
    })
    local second_outcome = projection.collect(second.raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_idempotent",
      name = "projection-outcome-idempotent-second-handoff",
    })
    t.eq(projection.semantic_json(first_outcome), projection.semantic_json(second_outcome))

    local duplicate_raises = {}
    for _, result in ipairs({ first, second }) do
      for _, raised in ipairs(result.raises) do
        duplicate_raises[#duplicate_raises + 1] = projection.copy(raised)
      end
    end
    local outcome = projection.collect(duplicate_raises, {
      proposal_id = proposal_id,
      comment_id_prefix = "IC_projection_idempotent",
      name = "projection-outcome-idempotent-handoff",
    })
    assert_single_state(outcome, "ready", core.ready_split_version(version))
    t.eq(#outcome.label_projections, 1)
    t.eq(#outcome.lifecycle_activations, 1)
    assert_ready_activation(outcome, core.ready_split_version(version))

    local conflict = projection.copy(second.raises)
    conflict[1].payload.body = conflict[1].payload.body .. "\nconflicting duplicate"
    t.raises(function()
      projection.collect({ first.raises[1], conflict[1] }, {
        proposal_id = proposal_id,
        comment_id_prefix = "IC_projection_conflict",
        name = "projection-outcome-conflict-handoff",
      })
    end)
  end,
}
