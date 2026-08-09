local core = require("core")
local observation = require("testkit_internal.old_behavior_observation_support")
local parsers = require("devloop.parsers.issue")
local payloads_builders = require("devloop.payloads.builders")
local sha256 = require("contract.sha256")
local v_ready = require("devloop.validators.ready")
local h = require("tests.devloop_core_helpers")
local t = fkst.test

local issue_json = [[{
  "title":"Issue title",
  "body":"Issue body",
  "createdAt":"2026-08-09T01:02:03Z",
  "updatedAt":"2026-08-09T04:05:06Z",
  "state":"OPEN",
  "stateReason":"REOPENED",
  "labels":[{"name":"bug"},"plain-label"],
  "comments":[{"id":"IC_1","body":"comment body","author":{"login":"fkst-test-bot"}}],
  "assignees":[{"login":"alice"},{"login":"bob"}],
  "author":{"login":"carol"},
  "milestone":{"number":3}
}]]

local issue_list_json = [=[[[{
  "number":41,
  "title":"Pull request",
  "pull_request":{"url":"https://api.example.test/pulls/41"}
},{
  "number":42,
  "title":"Issue title",
  "body":"Issue body",
  "createdAt":"2026-08-09T01:02:03Z",
  "updatedAt":"2026-08-09T04:05:06Z",
  "labels":[{"name":"bug"}],
  "assignees":[{"login":"alice"}],
  "author":{"login":"carol"}
}],[{
  "number":43,
  "title":"Second issue",
  "body":"Second body",
  "created_at":"2026-08-08T01:02:03Z",
  "updated_at":"2026-08-08T04:05:06Z",
  "labels":["plain-label"],
  "assignees":[],
  "author_login":"dave"
}]]]=]

local function parser_corpus()
  local decoded = json.decode(issue_json)
  return {
    parse_issue_view_state = parsers.parse_issue_view_state(issue_json),
    issue_state_from_json = parsers.issue_state_from_json(decoded),
    parse_issue_list_intake = parsers.parse_issue_list_intake(issue_list_json, 2),
    parse_issue_view_result = parsers.parse_issue_view_result(issue_json),
    parse_issue_view_loop = parsers.parse_issue_view_loop(issue_json),
    parse_issue_view_intake_judge = parsers.parse_issue_view_intake_judge(issue_json),
    parse_issue_view_meta = parsers.parse_issue_view_meta(issue_json),
    parse_issue_view_implement = parsers.parse_issue_view_implement(issue_json),
    parse_issue_view_open_pr = parsers.parse_issue_view_open_pr(issue_json),
    parse_issue_view_reviewing = parsers.parse_issue_view_reviewing(issue_json),
    parse_issue_view_review = parsers.parse_issue_view_review(issue_json),
    parse_issue_view_decompose = parsers.parse_issue_view_decompose(issue_json),
    parse_issue_view_fix = parsers.parse_issue_view_fix(issue_json),
    parse_issue_view_review_loop = parsers.parse_issue_view_review_loop(issue_json),
    parse_issue_view_merge = parsers.parse_issue_view_merge(issue_json),
    parse_issue_view_observe = parsers.parse_issue_view_observe(issue_json),
  }
end

local function copy_with(payload, key, value)
  local copy = observation.copy_value(payload)
  copy[key] = value
  return copy
end

local function ready_corpus()
  local valid = payloads_builders.build_devloop_ready_payload(h.reached({
    framing = "bounded framing",
    include_ready_hand_off = true,
    ready_comment_id = "IC_ready_characterization",
  }))
  local bad_hand_off = observation.copy_value(valid)
  bad_hand_off.ready_hand_off.state = "reviewing"
  return {
    v_ready.is_supported_ready(valid),
    v_ready.is_supported_ready(nil),
    v_ready.is_supported_ready(copy_with(valid, "schema", "github-devloop.ready.v2")),
    v_ready.is_supported_ready(copy_with(valid, "proposal_id", "unsafe proposal")),
    v_ready.is_supported_ready(copy_with(valid, "framing", string.rep("x", core._max_framing_len + 1))),
    v_ready.is_supported_ready(copy_with(valid, "source_ref", { kind = "external", ref = "unsafe ref" })),
    v_ready.is_supported_ready(copy_with(valid, "impl_retry_attempt", 1)),
    v_ready.is_supported_ready(copy_with(valid, "impl_retry_attempt", core._max_impl_retry_attempts)),
    v_ready.is_supported_ready(copy_with(valid, "impl_retry_attempt", 0)),
    v_ready.is_supported_ready(copy_with(valid, "impl_retry_attempt", 1.5)),
    v_ready.is_supported_ready(copy_with(valid, "impl_retry_attempt", core._max_impl_retry_attempts + 1)),
    v_ready.is_supported_ready(bad_hand_off),
  }
end

return {
  test_issue_parser_result_bytes_are_frozen = function()
    local bytes = observation.canonical_json(parser_corpus())
    t.eq(sha256.hex(bytes), "b7f5638206551caa67c63a58c69be879dd5d574aed408711d8a7c9c0a1637915")
  end,

  test_ready_validator_acceptance_matrix_is_frozen = function()
    local bytes = observation.canonical_json(ready_corpus())
    t.eq(sha256.hex(bytes), "fc7bb7b9ac64411d4e52bedb359a2f560bce2daa1eafaddf527452968b049a2d")
  end,
}
