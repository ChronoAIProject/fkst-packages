local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local payload_builders = require("devloop.payloads.builders")
local replayer = require("devloop.replayer")

local t = h.t
local core = h.core

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local BASE_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local FIXING_VERSION = BASE_VERSION .. "/fix/1"
local BRANCH = "devloop-owner-repo-42-01HY"
local REVIEWED_HEAD_SHA = "119ef6fd"
local REVIEW_PROPOSAL_ID = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, BASE_VERSION, REVIEWED_HEAD_SHA)
local REVIEW_DEDUP_KEY = devloop_base.pr_review_consensus_dedup_key(REVIEW_PROPOSAL_ID)
local REVIEW_META = payload_builders.build_devloop_review_meta_payload({
  proposal_id = REVIEW_PROPOSAL_ID,
  dedup_key = REVIEW_DEDUP_KEY,
  source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
}, PROPOSAL_ID, BASE_VERSION, PR_NUMBER, 1)

local function assert_error_class(expected, fn)
  local ok, failure = pcall(fn)
  if ok then
    error("expected typed failure " .. expected, 0)
  end
  t.eq(devloop_logging.error_class_from_message(failure), expected, tostring(failure))
end

local function complete_feedback()
  return {
    review_proposal_id = REVIEW_PROPOSAL_ID,
    review_dedup_key = REVIEW_DEDUP_KEY,
    reviewed_head_sha = REVIEWED_HEAD_SHA,
    review_reason = "Review consensus rejected the prior head.",
  }
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = "2026-06-03T01:02:03Z",
  }
end

local function fixing_row()
  for _, row in ipairs(core.restart_transition_table()) do
    if row.from_state == "fixing" then
      return row
    end
  end
  error("fix feedback contract test: fixing restart row is missing", 0)
end

local function replay_facts(feedback)
  local current_pr = {
    number = PR_NUMBER,
    state = "OPEN",
    head_ref_name = BRANCH,
    base_ref_name = "dev",
    head_sha = REVIEWED_HEAD_SHA,
    mergeable = "CONFLICTING",
    merge_state = "DIRTY",
    comments = {},
  }
  local link = {
    pr_number = PR_NUMBER,
    branch = BRANCH,
    base_branch = "dev",
    impl_version = BASE_VERSION,
  }
  return {
    proposal_id = PROPOSAL_ID,
    link = link,
    current = current_pr,
    current_pr = current_pr,
    snapshot = {
      comments = {},
      prs = { { number = PR_NUMBER, current = current_pr } },
    },
    feedback = feedback,
    source_ref = { kind = "external", ref = REPO .. "#pr/" .. PR_NUMBER },
  }
end

local function assert_replay_rejects_partial_feedback(classified)
  local feedback = complete_feedback()
  feedback.review_dedup_key = nil
  local ok, failure = pcall(function()
    local replay = classified and replayer.replay_from_table_classified or replayer.replay_from_table
    return replay(core,
      "liveness_scan",
      { repo = REPO, number = ISSUE_NUMBER, source_ref = { kind = "external", ref = REPO .. "#issue/" .. ISSUE_NUMBER } },
      {
        state = "fixing",
        version = FIXING_VERSION,
        proposal_id = PROPOSAL_ID,
        marker_created_at = "2026-06-03T01:02:03Z",
      },
      fixing_row(),
      replay_facts(feedback))
  end)
  if ok then
    error("expected replay to reject partial fix feedback", 0)
  end
  t.eq(devloop_logging.error_class_from_message(failure),
    "fix-feedback-missing-review-dedup-key",
    tostring(failure))
end

return {
  test_fix_feedback_parser_rejects_missing_review_proposal_id = function()
    local feedback = complete_feedback()
    feedback.review_proposal_id = nil
    assert_error_class("fix-feedback-missing-review-proposal-id", function()
      m_facts.parse_fix_feedback_fact(feedback)
    end)
  end,

  test_fix_feedback_parser_rejects_missing_review_dedup_key = function()
    local feedback = complete_feedback()
    feedback.review_dedup_key = nil
    assert_error_class("fix-feedback-missing-review-dedup-key", function()
      m_facts.parse_fix_feedback_fact(feedback)
    end)
  end,

  test_fix_feedback_parser_rejects_missing_reviewed_head_sha = function()
    local feedback = complete_feedback()
    feedback.reviewed_head_sha = nil
    assert_error_class("fix-feedback-missing-reviewed-head-sha", function()
      m_facts.parse_fix_feedback_fact(feedback)
    end)
  end,

  test_fix_feedback_parser_rejects_review_meta_delivery_dedup_as_review_binding = function()
    local feedback = complete_feedback()
    feedback.review_dedup_key = REVIEW_META.dedup_key
    assert_error_class("fix-feedback-mismatched-review-dedup-key", function()
      m_facts.parse_fix_feedback_fact(feedback)
    end)
  end,

  test_fix_feedback_marker_families_produce_complete_facts = function()
    local review_result = m_builders.review_result_marker(
      REVIEW_PROPOSAL_ID,
      PROPOSAL_ID,
      "reject",
      REVIEW_DEDUP_KEY,
      1,
      "missing regression guard")
    local review_meta = m_builders.review_meta_marker(
      PROPOSAL_ID,
      REVIEW_META.dedup_key,
      "fix",
      FIXING_VERSION,
      "missing regression guard",
      nil,
      complete_feedback())
    local merge_gate = m_builders.merge_gate_marker(
      PROPOSAL_ID,
      PR_NUMBER,
      FIXING_VERSION,
      REVIEW_PROPOSAL_ID,
      REVIEW_DEDUP_KEY,
      REVIEWED_HEAD_SHA,
      "abc123",
      "mergeable-conflicting")
    local facts = {
      m_facts.review_reject_fact({ trusted_comment(review_result) }, PROPOSAL_ID, FIXING_VERSION),
      m_facts.review_meta_fix_fact({ trusted_comment(review_meta) }, PROPOSAL_ID, FIXING_VERSION),
      (m_facts.merge_gate_fix_fact({ trusted_comment(merge_gate) }, PROPOSAL_ID, FIXING_VERSION)),
    }
    for _, fact in ipairs(facts) do
      t.eq(m_facts.parse_fix_feedback_fact(fact), fact)
      t.eq(fact.review_proposal_id, REVIEW_PROPOSAL_ID)
      t.eq(fact.review_dedup_key, REVIEW_DEDUP_KEY)
      t.eq(fact.reviewed_head_sha, REVIEWED_HEAD_SHA)
    end
    t.is_true(REVIEW_META.dedup_key ~= REVIEW_META.review_dedup_key)
    t.is_true(review_meta:find('dedup="' .. REVIEW_META.dedup_key .. '"', 1, true) ~= nil)
    t.is_true(review_meta:find('review_dedup="' .. REVIEW_DEDUP_KEY .. '"', 1, true) ~= nil)
  end,

  test_owned_marker_families_reject_missing_review_dedup_before_returning = function()
    local cases = {
      {
        name = "review-result",
        body = '<!-- fkst:github-devloop:review-result:v1 proposal="' .. REVIEW_PROPOSAL_ID
          .. '" issue_proposal="' .. PROPOSAL_ID
          .. '" decision="reject" fix_round="1" gap="missing review dedup" -->',
        parse = function(comments)
          return m_facts.review_reject_fact(comments, PROPOSAL_ID, FIXING_VERSION)
        end,
      },
      {
        name = "review-meta",
        body = '<!-- fkst:github-devloop:review-meta:v1 proposal="' .. PROPOSAL_ID
          .. '" dedup="' .. REVIEW_META.dedup_key
          .. '" action="fix" version="' .. FIXING_VERSION
          .. '" gap="missing review dedup" review_proposal="' .. REVIEW_PROPOSAL_ID
          .. '" head_sha="' .. REVIEWED_HEAD_SHA .. '" -->',
        parse = function(comments)
          return m_facts.review_meta_fix_fact(comments, PROPOSAL_ID, FIXING_VERSION)
        end,
      },
      {
        name = "merge-gate",
        body = '<!-- fkst:github-devloop:merge-gate:v1 proposal="' .. PROPOSAL_ID
          .. '" pr="' .. PR_NUMBER
          .. '" version="' .. FIXING_VERSION
          .. '" review_proposal="' .. REVIEW_PROPOSAL_ID
          .. '" head_sha="' .. REVIEWED_HEAD_SHA
          .. '" reason="mergeable-conflicting" -->',
        parse = function(comments)
          return m_facts.merge_gate_fix_fact(comments, PROPOSAL_ID, FIXING_VERSION)
        end,
      },
    }
    for _, case in ipairs(cases) do
      assert_error_class("fix-feedback-missing-review-dedup-key", function()
        case.parse({ trusted_comment(case.body) })
      end)
    end
  end,

  test_observe_fixing_replay_rejects_partial_feedback = function()
    assert_replay_rejects_partial_feedback(false)
  end,

  test_timeout_classified_fixing_replay_rejects_partial_feedback = function()
    assert_replay_rejects_partial_feedback(true)
  end,
}
