local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_fix_feedback_observation = require("devloop.markers.fix_feedback_observation")

local core = h.core
local t = h.t

local REPO = "owner/repo"
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local BASE_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local FIXING_VERSION = BASE_VERSION .. "/fix/1"
local HEAD_SHA = "119ef6fd"
local BRANCH = "devloop-owner-repo-42-01HY"
local REVIEW_PROPOSAL_ID = devloop_base.pr_review_proposal_id(
  REPO, PR_NUMBER, BASE_VERSION, HEAD_SHA)
local REVIEW_DEDUP_KEY = devloop_base.pr_review_consensus_dedup_key(REVIEW_PROPOSAL_ID)

local LEGACY_REVIEW_META_MARKER = table.concat({
  '<!-- fkst:github-devloop:review-meta:v1',
  ' proposal="' .. PROPOSAL_ID .. '"',
  ' dedup="fix-reflection/' .. PROPOSAL_ID .. '/' .. FIXING_VERSION .. '/review"',
  ' action="fix"',
  ' version="' .. FIXING_VERSION .. '"',
  ' gap="non-enforcing projection guard" -->',
})

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = created_at or "2026-06-03T01:02:03Z",
  }
end

local function fixing_row()
  for _, row in ipairs(core.restart_transition_table()) do
    if row.from_state == "fixing" then
      return row
    end
  end
  error("legacy review-meta liveness test: fixing restart row is missing", 0)
end

local function fixing_state()
  return {
    state = "fixing",
    version = FIXING_VERSION,
    proposal_id = PROPOSAL_ID,
    marker_created_at = "2026-06-03T01:02:03Z",
  }
end

local function liveness_facts(comments)
  return {
    proposal_id = PROPOSAL_ID,
    current = { comments = comments },
    current_pr = { comments = comments, head_sha = HEAD_SHA },
    snapshot = { comments = comments },
  }
end

local function complete_review_meta_marker()
  return m_builders.review_meta_marker(
    PROPOSAL_ID,
    REVIEW_DEDUP_KEY,
    "fix",
    FIXING_VERSION,
    "non-enforcing projection guard",
    nil,
    {
      review_proposal_id = REVIEW_PROPOSAL_ID,
      review_dedup_key = REVIEW_DEDUP_KEY,
      reviewed_head_sha = HEAD_SHA,
    })
end

local function pr_comments(state, version, extra)
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      PROPOSAL_ID, "42", BRANCH, BASE_VERSION, "dev")),
    trusted_comment(core.state_marker(PROPOSAL_ID, state, version)),
  }
  for _, comment in ipairs(extra or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function pr_event(updated_at)
  return {
    queue = "github-devloop-pr.devloop_observe_pr",
    now_seconds = contract_time.iso_timestamp_epoch_seconds(updated_at),
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = REPO,
      number = PR_NUMBER,
      state = "OPEN",
      source = "liveness-scan",
      updated_at = updated_at,
      dedup_key = REPO .. "#pr#" .. PR_NUMBER .. "@" .. updated_at,
      source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
    },
  }
end

local function run_observe_pr(comments, updated_at, name)
  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, 42)
  h.mock_pr_origin_for({
    repo = REPO,
    number = PR_NUMBER,
    comments = comments,
    head = BRANCH,
    head_sha = HEAD_SHA,
    base_branch = "dev",
    labels = { "fkst-dev:fixing" },
    mergeable = "MERGEABLE",
    merge_state = "CLEAN",
    times = 2,
  })
  return t.run_department("departments/observe_pr/main.lua", pr_event(updated_at), h.opts(name))
end

local function raised_payload(result, queue)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      return raised.payload
    end
  end
  return nil
end

local function assert_no_liveness_mutation(result)
  for _, raised in ipairs(result.raises or {}) do
    t.is_true(raised.queue ~= "github-devloop-pr.devloop_fixing")
    t.is_true(raised.queue ~= "github-devloop-pr.devloop_timeout_reconcile")
  end
end

return {
  test_legacy_review_meta_fix_marker_does_not_crash_the_fixing_liveness_probe = function()
    local state = fixing_state()
    local facts = liveness_facts({ trusted_comment(LEGACY_REVIEW_META_MARKER) })
    t.eq(state.work_unit_key, nil)
    t.eq(facts.work_unit_key, nil)

    local ok, result = pcall(core.restart_row_receiver_liveness,
      fixing_row(),
      state,
      facts,
      contract_time.iso_timestamp_epoch_seconds("2026-06-03T01:03:03Z"))
    if not ok then
      error("liveness probe threw on a legacy review-meta marker: " .. tostring(result), 0)
    end
    t.eq(type(result), "table")
    t.eq(result.action, "defer")
    t.eq(result.signal.indeterminate, true)
    t.eq(result.signal.reason, "fix-feedback-observation-invalid")
    t.eq(facts.fix_feedback_observation.status, "invalid")
    t.eq(facts.fix_feedback_observation.reason_code,
      "fix-feedback-missing-review-proposal-id")
    t.eq(facts.fix_feedback_observation.legacy_shape,
      "review-meta-unbound-v1")
  end,

  test_complete_review_meta_fix_marker_reaches_a_liveness_decision = function()
    local facts = liveness_facts({ trusted_comment(complete_review_meta_marker()) })
    local result = core.restart_row_receiver_liveness(
      fixing_row(),
      fixing_state(),
      facts,
      contract_time.iso_timestamp_epoch_seconds("2026-06-03T01:03:03Z"))
    t.eq(type(result), "table")
    t.eq(type(result.action), "string")
  end,

  test_strict_fixing_replay_rejects_the_legacy_review_meta_marker = function()
    local ok, failure = pcall(core.fixing_replay_feedback_fact,
      { trusted_comment(LEGACY_REVIEW_META_MARKER) },
      PROPOSAL_ID,
      FIXING_VERSION)
    if ok then
      error("strict fixing replay accepted a legacy review-meta marker", 0)
    end
    t.eq(devloop_logging.error_class_from_message(failure),
      "fix-feedback-missing-review-proposal-id",
      tostring(failure))
  end,

  test_fix_feedback_observation_is_total_for_all_strict_liveness_readers = function()
    local cases = {
      {
        source = "merge-gate",
        body = '<!-- fkst:github-devloop:merge-gate:v1 proposal="' .. PROPOSAL_ID
          .. '" pr="' .. PR_NUMBER
          .. '" version="' .. FIXING_VERSION
          .. '" review_proposal="' .. REVIEW_PROPOSAL_ID
          .. '" head_sha="' .. HEAD_SHA
          .. '" reason="mergeable-conflicting" -->',
        reason = "fix-feedback-missing-review-dedup-key",
      },
      {
        source = "review-result",
        body = '<!-- fkst:github-devloop:review-result:v1 proposal="' .. REVIEW_PROPOSAL_ID
          .. '" issue_proposal="' .. PROPOSAL_ID
          .. '" decision="reject" fix_round="1" gap="missing review dedup" -->',
        reason = "fix-feedback-missing-review-dedup-key",
      },
      {
        source = "review-meta",
        body = LEGACY_REVIEW_META_MARKER,
        reason = "fix-feedback-missing-review-proposal-id",
        legacy_shape = "review-meta-unbound-v1",
      },
    }
    for _, case in ipairs(cases) do
      local observation = m_fix_feedback_observation.observe(
        { trusted_comment(case.body) }, PROPOSAL_ID, FIXING_VERSION)
      t.eq(observation.status, "invalid", case.source)
      t.eq(observation.source, case.source, case.source)
      t.eq(observation.reason_code, case.reason, case.source)
      t.eq(observation.legacy_shape, case.legacy_shape, case.source)
    end
  end,

  test_observe_pr_routes_legacy_fix_feedback_to_review_meta_before_replay = function()
    local initial_comments = pr_comments("fixing", FIXING_VERSION, {
      trusted_comment(LEGACY_REVIEW_META_MARKER),
    })
    local first = run_observe_pr(
      initial_comments,
      "2026-06-03T01:03:03Z",
      "legacy-fix-feedback-first-observe")
    t.eq(first.exit_code, 0, first.stderr)
    assert_no_liveness_mutation(first)

    local comment_request = raised_payload(
      first, "github-proxy.github_pr_comment_request")
    local label_request = raised_payload(
      first, "github-proxy.github_issue_label_request")
    t.is_true(comment_request ~= nil, "legacy remediation writes the review-meta state")
    t.is_true(label_request ~= nil, "legacy remediation projects the review-meta label")
    t.is_true(comment_request.body:find('state="review-meta"', 1, true) ~= nil)
    t.is_true(comment_request.body:find("legacy-fix-feedback-unbound", 1, true) ~= nil)
    t.eq(comment_request.handoff.review_proposal_id, REVIEW_PROPOSAL_ID)
    t.eq(comment_request.handoff.review_dedup_key, REVIEW_DEDUP_KEY)

    local remediated_comments = pr_comments("fixing", FIXING_VERSION, {
      trusted_comment(LEGACY_REVIEW_META_MARKER),
      trusted_comment(comment_request.body, "2026-06-03T01:03:04Z"),
    })
    local second = run_observe_pr(
      remediated_comments,
      "2026-06-03T01:04:03Z",
      "legacy-fix-feedback-second-observe")
    t.eq(second.exit_code, 0, second.stderr)
    assert_no_liveness_mutation(second)
  end,
}
