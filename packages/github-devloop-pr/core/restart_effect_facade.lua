local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local restart_effect_facade = require("devloop.restart_effect_facade")

local M = {}

local COMMENT_EFFECT_ID = "github-proxy.github_pr_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"

local function serialize_review_activation_comment(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.repo) ~= "string"
    or type(args.origin) ~= "table"
    or args.pr_number == nil
    or type(args.source_ref) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_review.build_reviewing_comment_request(
    args.core,
    args.repo,
    args.issue_number,
    args.origin,
    args.pr_number,
    args.source_ref
  )
end

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

local function valid_fix_args(args)
  return type(args) == "table"
    and type(args.core) == "table"
    and type(args.repo) == "string"
    and args.issue_number ~= nil
    and type(args.fix) == "table"
    and type(args.old_head_sha) == "string"
    and type(args.new_head_sha) == "string"
    and type(args.new_version) == "string"
end

local function serialize_fix_reviewing_comment(args)
  if not valid_fix_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return requests_review.build_fix_reviewing_comment_request(
    args.core,
    args.repo,
    args.issue_number,
    args.fix,
    args.old_head_sha,
    args.new_head_sha,
    args.new_version
  )
end

local function serialize_fix_reviewing_label(args)
  if not valid_fix_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return requests_labels.build_fix_reviewing_label_request(
    args.repo,
    args.issue_number,
    args.fix,
    args.new_head_sha,
    args.new_version
  )
end

local function valid_review_meta_args(args)
  return type(args) == "table"
    and type(args.core) == "table"
    and type(args.repo) == "string"
    and args.issue_number ~= nil
    and type(args.review_meta) == "table"
    and type(args.action) == "string"
    and type(args.reason) == "string"
    and type(args.version) == "string"
end

local function serialize_review_meta_comment(args)
  if not valid_review_meta_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return args.core.build_review_meta_comment_request(
    args.repo,
    args.issue_number,
    args.review_meta,
    args.action,
    args.reason,
    args.version,
    args.blocking_gap
  )
end

local function serialize_review_meta_label(args)
  if not valid_review_meta_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return args.core.build_review_meta_label_request(
    args.repo,
    args.issue_number,
    args.review_meta,
    args.action,
    args.version
  )
end

local REVIEW_RESULT_SERIALIZERS = {
  [COMMENT_EFFECT_ID] = {
    sink_id = "comment:pr:review-result",
    serialize = serialize_review_result_comment,
  },
  [LABEL_EFFECT_ID] = {
    sink_id = "label:issue:review-result",
    serialize = serialize_review_result_label,
  },
}

local REVIEW_ACTIVATION_SERIALIZERS = {
  [COMMENT_EFFECT_ID] = {
    sink_id = "comment:pr:observe-reviewing",
    serialize = serialize_review_activation_comment,
  },
}

local FIX_SERIALIZERS = {
  [COMMENT_EFFECT_ID] = {
    sink_id = "comment:pr:fix-reviewing",
    serialize = serialize_fix_reviewing_comment,
  },
  [LABEL_EFFECT_ID] = {
    sink_id = "label:issue:fix-reviewing",
    serialize = serialize_fix_reviewing_label,
  },
}

local REVIEW_META_SERIALIZERS = {
  [COMMENT_EFFECT_ID] = {
    sink_id = "comment:pr:review-meta-result",
    serialize = serialize_review_meta_comment,
  },
  [LABEL_EFFECT_ID] = {
    sink_id = "label:issue:review-meta-result",
    serialize = serialize_review_meta_label,
  },
}

local SERIALIZERS_BY_FAMILY = {
  ["pr-review-activation"] = REVIEW_ACTIVATION_SERIALIZERS,
  ["pr-review-result"] = REVIEW_RESULT_SERIALIZERS,
  ["pr-review-meta"] = REVIEW_META_SERIALIZERS,
  ["pr-fix"] = FIX_SERIALIZERS,
}

function M.make(config)
  assert(type(config) == "table", "restart-effect-facade: config is required")
  local serializers = SERIALIZERS_BY_FAMILY[config.family]
  assert(serializers ~= nil, "restart-effect-facade: supported family is required")
  return restart_effect_facade.make({
    verify_grant = config.verify_grant,
    sink_inventory = config.sink_inventory,
    serializers = serializers,
  })
end

return M
