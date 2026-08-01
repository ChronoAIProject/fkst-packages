local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
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
      REVIEW_DEDUP_KEY,
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
  end,

  test_fix_feedback_selector_rejects_partial_output_from_every_marker_family = function()
    local ops = require("devloop.restart.pr_review_replay_facts").install(core)
    local names = { "review_reject_fact", "review_meta_fix_fact", "merge_gate_fix_fact" }
    for _, selected in ipairs(names) do
      local originals = {}
      for _, name in ipairs(names) do
        originals[name] = m_facts[name]
        m_facts[name] = name == selected and function()
          local feedback = complete_feedback()
          feedback.reviewed_head_sha = nil
          return feedback
        end or function()
          return nil
        end
      end
      local ok, failure = pcall(ops.fixing_replay_feedback_fact, {}, PROPOSAL_ID, FIXING_VERSION)
      for _, name in ipairs(names) do
        m_facts[name] = originals[name]
      end
      if ok then
        error("expected selector to reject partial output from " .. selected, 0)
      end
      t.eq(devloop_logging.error_class_from_message(failure),
        "fix-feedback-missing-reviewed-head-sha",
        selected .. ": " .. tostring(failure))
    end
  end,

  test_observe_fixing_replay_rejects_partial_feedback = function()
    assert_replay_rejects_partial_feedback(false)
  end,

  test_timeout_classified_fixing_replay_rejects_partial_feedback = function()
    assert_replay_rejects_partial_feedback(true)
  end,
}
