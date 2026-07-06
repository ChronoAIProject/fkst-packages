local requests_review = require("devloop.requests.review")
local payloads_builders = require("devloop.payloads.builders")
local m_facts = require("devloop.markers.facts")
local m_builders = require("devloop.markers.builders")
local replayer = require("devloop.replayer")
local replay_fields = require("devloop.replay_fields")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local v_fixing = require("devloop.validators.fixing")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local merge_ready = h.merge_ready

local function replay_payload(event, ci_failure_key)
  return payloads_builders.build_replayed_fixing_payload({
    proposal_id = event.proposal_id,
    impl_version = event.version,
  }, event.pr_number, {
    review_proposal_id = event.review_proposal_id,
    review_dedup_key = event.review_dedup_key,
    reviewed_head_sha = event.reviewed_head_sha,
    blocking_gap = "own-ci-red",
    gate_baseline_sha = "ba5e9999",
    ci_failure_key = ci_failure_key,
    review_reason = "own-ci-red",
  }, event.source_ref)
end

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function capture_raises(fn)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original
  if not ok then
    error(err)
  end
  return raised
end

local function count_raises(raised, queue)
  local count = 0
  for _, item in ipairs(raised or {}) do
    if item.queue == queue then
      count = count + 1
    end
  end
  return count
end

local function find_raise(raised, queue)
  for _, item in ipairs(raised or {}) do
    if item.queue == queue then
      return item
    end
  end
  return nil
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T00:00:00Z",
  }
end

return {
  test_own_ci_red_fixing_lineage_is_keyed_by_failing_check_run = function()
    local event = merge_ready()
    local fix_version = core.fix_version_from_review_version(event.version)
    local first_key = "check-run/test/1001/def456/COMPLETED/FAILURE"
    local second_key = "check-run/test/1002/def456/COMPLETED/FAILURE"
    local request = requests_review.build_merge_gate_fix_comment_request(core,
      "owner/repo",
      "42",
      event,
      fix_version,
      "own-ci-red",
      "ba5e9999",
      event.source_ref,
      "none",
      {
        ci_failure_key = first_key,
      }
    )

    t.eq(request.handoff.ci_failure_key, first_key)
    local fact = m_facts.merge_gate_fix_fact({ request.body }, event.proposal_id, request.handoff.version)
    t.eq(fact.ci_failure_key, first_key)

    local first = replay_payload(event, first_key)
    local same = replay_payload(event, first_key)
    local changed = replay_payload(event, second_key)

    t.eq(first.dedup_key, same.dedup_key)
    t.is_true(first.dedup_key ~= changed.dedup_key)
    t.is_true(first.dedup_key:find("/" .. first_key, 1, true) ~= nil)
    t.is_true(changed.dedup_key:find("/" .. second_key, 1, true) ~= nil)
    t.eq(first.ci_failure_key, first_key)
    t.eq(v_fixing.is_supported_fixing(first), true)
    t.eq(v_fixing.is_supported_fixing(changed), true)
  end,

  test_own_ci_red_replay_dispatches_one_fixing_payload_keyed_by_failing_check_run = function()
    local event = merge_ready()
    local fix_version = core.fix_version_from_review_version(event.version)
    local ci_failure_key = "check-run/test/1001/def456/COMPLETED/FAILURE"
    local link = {
      proposal_id = event.proposal_id,
      pr_number = event.pr_number,
      branch = "devloop-owner-repo-42-01HY",
      impl_version = core._strip_latest_fix_version_suffix(fix_version),
      base_branch = "dev",
    }
    local comments = {
      trusted_comment(m_builders.pr_link_marker(event.proposal_id,
        link.pr_number,
        link.branch,
        link.impl_version,
        link.base_branch
      )),
      trusted_comment(core.state_marker(event.proposal_id, "fixing", fix_version)),
      trusted_comment("github-devloop merge gate failed: own-ci-red\n" .. m_builders.merge_gate_marker(event.proposal_id,
        event.pr_number,
        fix_version,
        event.review_proposal_id,
        event.review_dedup_key,
        event.reviewed_head_sha,
        "ba5e9999",
        "own-ci-red",
        nil,
        ci_failure_key
      )),
    }
    local state = {
      state = "fixing",
      version = fix_version,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local facts = {
      proposal_id = event.proposal_id,
      source_ref = entity_lib.pr_source_ref("owner/repo", event.pr_number),
      current_pr = {
        comments = comments,
        head_sha = event.reviewed_head_sha,
        head_ref_name = link.branch,
        base_ref_name = link.base_branch,
        state = "OPEN",
      },
      link = link,
      snapshot = {
        comments = comments,
        prs = {
          {
            number = event.pr_number,
            current = {
              comments = comments,
              head_sha = event.reviewed_head_sha,
              head_ref_name = link.branch,
              base_ref_name = link.base_branch,
              state = "OPEN",
            },
          },
        },
        state = state,
      },
    }
    local issue = {
      repo = "owner/repo",
      number = 42,
      source_ref = entity_lib.issue_source_ref("owner/repo", 42),
    }
    local row = restart_transition_row("fixing")
    t.eq(row.payload_fields.ci_failure_key, "marker:merge-gate.ci_failure_key")

    local first = capture_raises(function()
      local classified = replayer.replay_from_table_classified(core, "liveness_scan", issue, state, row, facts)
      t.eq(classified.kind, "issued")
    end)
    local second = capture_raises(function()
      local classified = replayer.replay_from_table_classified(core, "liveness_scan", issue, state, row, facts)
      t.eq(classified.kind, "issued")
    end)

    t.eq(count_raises(first, "devloop_fixing"), 1)
    t.eq(count_raises(second, "devloop_fixing"), 1)
    local first_payload = find_raise(first, "devloop_fixing").payload
    local second_payload = find_raise(second, "devloop_fixing").payload
    t.eq(first_payload.ci_failure_key, ci_failure_key)
    t.eq(first_payload.dedup_key, second_payload.dedup_key)
    t.is_true(first_payload.dedup_key:find("/" .. ci_failure_key .. "/", 1, true) ~= nil)
    t.eq(v_fixing.is_supported_fixing(first_payload), true)
  end,
}
