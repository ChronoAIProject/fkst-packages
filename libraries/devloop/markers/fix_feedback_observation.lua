local ci_failure_keys = require("devloop.ci_failure_keys")
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local forge_validators = require("devloop.forge_validators")
local parsers_misc = require("devloop.parsers.misc")
local shared = require("devloop.markers.shared")
local strings = require("contract.strings")
local transition_version = require("contract.transition_version")

local M = {}

local function absent()
  return { status = "absent" }
end

local function nonempty_marker_attr(marker, name)
  return marker:match(name .. '="([^"]+)"')
end

local function classified_fact(fact, source, legacy_shape)
  local result = shared.classify_fix_feedback_fact(fact)
  result.source = source
  result.legacy_shape = legacy_shape
  return result
end

local function strict_or_observed(fact, source, legacy_shape, observe)
  local result = classified_fact(fact, source, legacy_shape)
  if observe then
    return result
  end
  if result.status ~= "valid" then
    return shared.parse_fix_feedback_fact(fact)
  end
  return result.fact
end

local function no_match(observe)
  if observe then
    return absent()
  end
  return nil
end

local function review_result_fact_from_marker(marker, comment, issue_proposal_id,
    issue_version, expected_decision, observe)
  local review_proposal = shared.marker_attr(marker, "proposal")
  local marker_issue = shared.marker_attr(marker, "issue_proposal")
  local decision = shared.marker_attr(marker, "decision")
  local review_dedup = shared.marker_attr(marker, "dedup")
  local _, _, review_version, reviewed_head_sha =
    devloop_base.parse_pr_review_proposal_id(review_proposal)
  if marker_issue ~= tostring(issue_proposal_id)
    or (expected_decision ~= nil and decision ~= expected_decision)
    or (decision ~= "approve" and decision ~= "reject") then
    return no_match(observe)
  end

  local fact = {
    review_proposal_id = review_proposal,
    review_dedup_key = review_dedup,
    reviewed_head_sha = reviewed_head_sha,
    decision = decision,
    review_reason = parsers_misc._comment_body(comment),
    comment_created_at = parsers_misc._comment_created_at(comment),
  }
  if decision == "reject" then
    local marker_fix_round = shared.valid_round(shared.marker_attr(marker, "fix_round"))
    if marker_fix_round == nil
      or marker_fix_round ~= devloop_state.version_fix_round(issue_version) then
      return no_match(observe)
    end
    local gap = shared.decode_marker_attr(shared.marker_attr(marker, "gap"))
    if gap == nil or not strings.is_bounded_string(gap, devloop_base._max_blocking_gap_len) then
      return no_match(observe)
    end
    fact.blocking_gap = gap
    fact.fix_round = marker_fix_round
    if fact.review_proposal_id == nil
      or fact.review_dedup_key == nil
      or fact.reviewed_head_sha == nil then
      local result = classified_fact(fact, "review-result")
      if observe then
        return result
      end
      return shared.parse_fix_feedback_fact(fact)
    end
    local canonical_review_dedup =
      devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
        fact.review_dedup_key,
        fact.review_proposal_id
      )
    if canonical_review_dedup == nil then
      return no_match(observe)
    end
    fact.review_dedup_key = canonical_review_dedup
    local _, _, parsed_review_version =
      devloop_base.parse_pr_review_proposal_id(fact.review_proposal_id)
    if parsed_review_version ~= transition_version.safe_version_segment(
        devloop_state._strip_latest_fix_version_suffix(issue_version)) then
      return no_match(observe)
    end
    local result = classified_fact(fact, "review-result")
    if result.status ~= "valid" then
      if observe then
        return result
      end
      return shared.parse_fix_feedback_fact(fact)
    end
    result.fact = fact
    return observe and result or fact
  end

  local canonical_review_dedup =
    devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
      review_dedup,
      review_proposal
    )
  if review_version == transition_version.safe_version_segment(
      devloop_state._strip_latest_fix_version_suffix(issue_version))
    and canonical_review_dedup ~= nil
    and forge_validators.is_git_sha(reviewed_head_sha) then
    fact.review_dedup_key = canonical_review_dedup
    return fact
  end
  return no_match(observe)
end

local function read_review_result(comments, issue_proposal_id, issue_version,
    expected_decision, observe)
  if type(comments) ~= "table" then
    return no_match(observe)
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:review%-result:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local result = review_result_fact_from_marker(marker, comment,
        issue_proposal_id, issue_version, expected_decision, observe)
      if observe then
        if result.status ~= "absent" then
          return result
        end
      elseif result ~= nil then
        return result
      end
    end
  end
  return no_match(observe)
end

function M.review_result_fact_from_marker(marker, comment, issue_proposal_id,
    issue_version, expected_decision)
  return review_result_fact_from_marker(marker, comment, issue_proposal_id,
    issue_version, expected_decision, false)
end

function M.review_reject_fact(comments, issue_proposal_id, issue_version)
  return read_review_result(comments, issue_proposal_id, issue_version, "reject", false)
end

function M.review_result_fact(comments, issue_proposal_id, issue_version, expected_decision)
  return read_review_result(comments, issue_proposal_id, issue_version,
    expected_decision, false)
end

local function legacy_review_meta_shape(marker, issue_proposal_id, issue_version)
  local gap = shared.decode_marker_attr(shared.marker_attr(marker, "gap"))
  return shared.marker_attr(marker, "proposal") == tostring(issue_proposal_id)
    and shared.marker_attr(marker, "action") == "fix"
    and shared.marker_attr(marker, "version") == tostring(issue_version)
    and strings.is_bounded_string(shared.marker_attr(marker, "dedup"),
      devloop_base._max_dedup_len)
    and strings.is_bounded_string(gap, devloop_base._max_blocking_gap_len)
    and shared.marker_attr(marker, "review_proposal") == nil
    and shared.marker_attr(marker, "review_dedup") == nil
    and shared.marker_attr(marker, "head_sha") == nil
end

function M.is_legacy_review_meta_unbound_marker(marker, issue_proposal_id, issue_version)
  return legacy_review_meta_shape(marker, issue_proposal_id, issue_version)
end

local function read_review_meta_fix(comments, issue_proposal_id, issue_version, observe)
  if type(comments) ~= "table" then
    return no_match(observe)
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:review%-meta:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_issue = shared.marker_attr(marker, "proposal")
      local marker_dedup = shared.marker_attr(marker, "dedup")
      local action = shared.marker_attr(marker, "action")
      local version = shared.marker_attr(marker, "version")
      local gap = shared.decode_marker_attr(shared.marker_attr(marker, "gap"))
      if marker_issue == tostring(issue_proposal_id)
        and action == "fix"
        and version == tostring(issue_version)
        and strings.is_bounded_string(marker_dedup, devloop_base._max_dedup_len)
        and strings.is_bounded_string(gap, devloop_base._max_blocking_gap_len) then
        local legacy_shape = legacy_review_meta_shape(
          marker, issue_proposal_id, issue_version)
            and "review-meta-unbound-v1" or nil
        return strict_or_observed({
          review_proposal_id = shared.marker_attr(marker, "review_proposal"),
          review_dedup_key = shared.marker_attr(marker, "review_dedup"),
          reviewed_head_sha = shared.marker_attr(marker, "head_sha"),
          review_reason = parsers_misc._comment_body(comment),
          blocking_gap = gap,
        }, "review-meta", legacy_shape, observe)
      end
    end
  end
  return no_match(observe)
end

function M.review_meta_fix_fact(comments, issue_proposal_id, issue_version)
  return read_review_meta_fix(comments, issue_proposal_id, issue_version, false)
end

local function merge_gate_matches_bindings(fact, opts)
  if type(opts) ~= "table" then
    return true
  end
  local fact_review_dedup =
    devloop_base.canonical_pr_review_consensus_dedup_key(fact.review_dedup_key)
  local opts_review_dedup = opts.review_dedup_key ~= nil
      and devloop_base.canonical_pr_review_consensus_dedup_key(opts.review_dedup_key)
    or nil
  local baseline_bound = opts.match_gate_baseline_sha == true
    or opts.gate_baseline_sha ~= nil
  local predecessor_bound = opts.match_predecessor_set == true
    or opts.predecessor_set ~= nil
  local ci_failure_bound = opts.match_ci_failure_key == true
    or opts.ci_failure_key ~= nil
  return (opts.review_proposal_id == nil
      or fact.review_proposal_id == tostring(opts.review_proposal_id))
    and (opts.review_dedup_key == nil
      or (fact_review_dedup ~= nil and fact_review_dedup == opts_review_dedup))
    and (opts.reviewed_head_sha == nil
      or fact.reviewed_head_sha == tostring(opts.reviewed_head_sha))
    and (not baseline_bound
      or (opts.gate_baseline_sha ~= nil
        and fact.gate_baseline_sha == tostring(opts.gate_baseline_sha))
      or (opts.gate_baseline_sha == nil and fact.gate_baseline_sha == nil))
    and (not predecessor_bound
      or tostring(fact.predecessor_set or "") == tostring(opts.predecessor_set or ""))
    and (not ci_failure_bound
      or tostring(fact.ci_failure_key or "") == tostring(opts.ci_failure_key or ""))
end

local function read_merge_gate(comments, issue_proposal_id, issue_version, opts, observe)
  if type(comments) ~= "table" then
    if observe then
      return absent()
    end
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:merge%-gate:v1.-%-%->"
  local best, best_seconds, matched_binding = nil, nil, false
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local marker_issue = nonempty_marker_attr(marker, "proposal")
      local marker_version = marker:match('version="([^"]*)"')
      local marker_gate_baseline_sha = nonempty_marker_attr(marker, "gate_baseline_sha")
      local marker_predecessor_set = nonempty_marker_attr(marker, "predecessor_set")
      local marker_ci_failure_key = nonempty_marker_attr(marker, "ci_failure_key")
      local marker_reason = nonempty_marker_attr(marker, "reason")
      if marker_issue == tostring(issue_proposal_id)
        and marker_version == tostring(issue_version)
        and strings.is_path_safe_key(marker_reason, devloop_base._max_key_len)
        and (marker_gate_baseline_sha == nil
          or forge_validators.is_git_sha(marker_gate_baseline_sha))
        and (marker_predecessor_set == nil
          or strings.is_path_safe_key(marker_predecessor_set, devloop_base._max_dedup_len))
        and (marker_ci_failure_key == nil
          or ci_failure_keys.is_valid(marker_ci_failure_key, devloop_base._max_dedup_len)) then
        local fact = {
          review_proposal_id = nonempty_marker_attr(marker, "review_proposal"),
          review_dedup_key = nonempty_marker_attr(marker, "review_dedup"),
          reviewed_head_sha = nonempty_marker_attr(marker, "head_sha"),
          gate_baseline_sha = marker_gate_baseline_sha,
          predecessor_set = marker_predecessor_set,
          ci_failure_key = marker_ci_failure_key,
          reason = marker_reason,
          review_reason = parsers_misc._comment_body(comment),
          comment_created_at = parsers_misc._comment_created_at(comment),
        }
        local result = classified_fact(fact, "merge-gate")
        if result.status ~= "valid" then
          if observe then
            return result
          end
          return shared.parse_fix_feedback_fact(fact)
        end
        if merge_gate_matches_bindings(fact, opts) then
          matched_binding = true
        end
        local candidate_seconds =
          contract_time.iso_timestamp_epoch_seconds(fact.comment_created_at) or 0
        if best == nil or candidate_seconds >= best_seconds then
          best, best_seconds = fact, candidate_seconds
        end
      end
    end
  end
  if observe then
    if best == nil then
      return absent()
    end
    return classified_fact(best, "merge-gate")
  end
  return best, best ~= nil and merge_gate_matches_bindings(best, opts), matched_binding
end

function M.merge_gate_fix_fact(comments, issue_proposal_id, issue_version, opts)
  return read_merge_gate(comments, issue_proposal_id, issue_version, opts, false)
end

function M.observe(comments, issue_proposal_id, issue_version)
  local result = read_merge_gate(comments, issue_proposal_id, issue_version, nil, true)
  if result.status ~= "absent" then
    return result
  end
  result = read_review_result(comments, issue_proposal_id, issue_version, "reject", true)
  if result.status ~= "absent" then
    return result
  end
  return read_review_meta_fix(comments, issue_proposal_id, issue_version, true)
end

function M.legacy_review_meta_unbound(comments, issue_proposal_id, issue_version)
  local result = read_review_meta_fix(comments, issue_proposal_id, issue_version, true)
  if result.status == "invalid" and result.legacy_shape == "review-meta-unbound-v1" then
    return result
  end
  return nil
end

return M
