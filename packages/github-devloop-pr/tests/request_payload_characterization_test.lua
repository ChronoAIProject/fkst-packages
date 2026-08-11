local core = require("core")
local entity = require("devloop.entity")
local observation = require("testkit_internal.old_behavior_observation_support")
local requests_review = require("devloop.requests.review")
local sha256 = require("contract.sha256")
local t = fkst.test

local function slice4_review_corpus()
  local proposal_id = "github-devloop/issue/owner/repo/42"
  local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
  local source_ref = entity.pr_source_ref("owner/repo", 7)
  local review_proposal_id = require("devloop.base").pr_review_proposal_id(
    "owner/repo", 7, version, "def456")
  local review_dedup_key = "consensus:" .. review_proposal_id .. "/review"
  local unresolved = {
    proposal_id = review_proposal_id,
    pr_number = 7,
    dedup_key = review_dedup_key,
    source_ref = source_ref,
    narrowed_question = "Does the named gap remain?",
    angle_digests = {
      { angle = "fidelity", verdict = "comment", digest = "verify the requirement" },
    },
  }
  local reached = {
    proposal_id = review_proposal_id,
    dedup_key = review_dedup_key,
    decision = "reject",
    body = "The named gap remains.",
    blocking_gap = "Missing regression coverage",
    angle_results = {
      { angle = "fidelity", verdict = "reject" },
      { angle = "parsimony", verdict = "approve" },
    },
  }
  local origin = {
    proposal_id = proposal_id,
    impl_version = version,
  }
  local merge_ready = {
    proposal_id = proposal_id,
    pr_number = 7,
    version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = "def456",
  }
  local fix = {
    proposal_id = proposal_id,
    pr_number = 7,
    version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = "def456",
    source_ref = source_ref,
    fix_summary = "Added regression coverage.",
  }

  return {
    review_converge = requests_review.build_review_converge_round_comment_request(core.output_language, "owner/repo", 42, unresolved, proposal_id, 2, "<!-- review marker -->", source_ref),
    issue_review_converge = requests_review.build_issue_review_converge_round_comment_request(core.output_language, "owner/repo", 42, unresolved, proposal_id, 2, "<!-- review marker -->", source_ref),
    reviewing = requests_review.build_reviewing_comment_request(core.output_language, "owner/repo", 42, origin, 7, source_ref),
    review_result = requests_review.build_review_result_comment_request(core.output_language, "owner/repo", 42, proposal_id, version, reached, source_ref),
    merge_gate_fix = requests_review.build_merge_gate_fix_comment_request(core.merge_gate_reason_class, core.output_language, "owner/repo", 42, merge_ready, version .. "/fix/1", "own-ci-red", "abc123", source_ref,
      "pred-1", { blocking_gap = "CI is red", current_head_sha = "def456" }),
    fix_reviewing = requests_review.build_fix_reviewing_comment_request(core.output_language, "owner/repo", 42, fix, "def456", "feedface", version .. "/fix/1"),
    merge_head_reviewing = requests_review.build_merge_head_reviewing_comment_request(core.output_language, "owner/repo", 42, merge_ready, "def456", "feedface", version .. "/head/1", source_ref),
  }
end

return {
  test_slice4_review_request_bytes_are_frozen = function()
    local bytes = observation.canonical_json(slice4_review_corpus())
    t.eq(sha256.hex(bytes), "f7530aed4eac534c06dc3d5a09901be69df333106323323c93b79f7cd07cf64c")
  end,
}
