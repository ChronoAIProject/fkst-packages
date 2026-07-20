local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local restart_effect_facade = require("devloop.restart_effect_facade")

local M = {}

local COMMENT_EFFECT_ID = "github-proxy.github_pr_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"

local function valid_args(args)
  return type(args) == "table"
    and type(args.core) == "table"
    and type(args.repo) == "string"
    and args.issue_number ~= nil
    and type(args.issue_proposal_id) == "string"
    and type(args.issue_version) == "string"
    and type(args.reached) == "table"
    and type(args.pr_source_ref) == "table"
end

local function serialize_review_result_comment(args)
  if not valid_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return requests_review.build_review_result_comment_request(
    args.core,
    args.repo,
    args.issue_number,
    args.issue_proposal_id,
    args.issue_version,
    args.reached,
    args.pr_source_ref
  )
end

local function serialize_review_result_label(args)
  if not valid_args(args)
    or type(args.issue_source_ref) ~= "table"
    or type(args.marker_target) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_labels.build_review_result_label_request(
    args.repo,
    args.issue_number,
    args.issue_proposal_id,
    args.issue_version,
    args.reached,
    args.issue_source_ref,
    args.marker_target
  )
end

local SERIALIZERS = {
  [COMMENT_EFFECT_ID] = {
    sink_id = "comment:pr:review-result",
    serialize = serialize_review_result_comment,
  },
  [LABEL_EFFECT_ID] = {
    sink_id = "label:issue:review-result",
    serialize = serialize_review_result_label,
  },
}

function M.make(config)
  assert(type(config) == "table", "restart-effect-facade: config is required")
  assert(config.family == "pr-review-result",
    "restart-effect-facade: supported family is required")
  return restart_effect_facade.make({
    verify_grant = config.verify_grant,
    sink_inventory = config.sink_inventory,
    serializers = SERIALIZERS,
  })
end

return M
