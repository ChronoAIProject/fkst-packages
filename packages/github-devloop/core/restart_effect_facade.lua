local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")

local M = {}

local COMMENT_EFFECT_ID = "github-proxy.github_issue_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"

local function index_sinks(sink_inventory)
  local by_id = {}
  for _, sink in ipairs(sink_inventory) do
    by_id[sink.id] = sink
  end
  return by_id
end

local function serialize_thinking_comment(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.proposal) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_lifecycle.build_observe_comment_request(
    args.core,
    args.issue,
    args.proposal
  )
end

local function serialize_thinking_label(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.proposal) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_labels.build_thinking_label_request(args.issue, args.proposal)
end

local function serialize_issue_reconcile_comment(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.reconcile) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return args.core.build_reconcile_comment_request(
    args.issue.repo,
    args.issue.number,
    args.reconcile,
    args.action,
    args.reason,
    args.state_version
  )
end

local function serialize_issue_reconcile_label(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.reconcile) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return args.core.build_reconcile_label_request(
    args.issue.repo,
    args.issue.number,
    args.reconcile
  )
end

local SERIALIZERS_BY_FAMILY = {
  thinking = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:thinking-state",
      serialize = serialize_thinking_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:thinking-state",
      serialize = serialize_thinking_label,
    },
  },
  ["issue-reconcile"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:reconcile-blocked",
      serialize = serialize_issue_reconcile_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:reconcile-blocked",
      serialize = serialize_issue_reconcile_label,
    },
  },
}

function M.make(config)
  assert(type(config) == "table", "restart-effect-facade: config is required")
  assert(type(config.verify_grant) == "function",
    "restart-effect-facade: verify_grant must be a function")
  assert(type(config.sink_inventory) == "table",
    "restart-effect-facade: sink_inventory must be a table")
  assert(type(config.family) == "string" and SERIALIZERS_BY_FAMILY[config.family] ~= nil,
    "restart-effect-facade: supported family is required")

  local verify_grant = config.verify_grant
  local sinks_by_id = index_sinks(config.sink_inventory)
  local serializers = SERIALIZERS_BY_FAMILY[config.family]

  for effect_id, serializer in pairs(serializers) do
    local sink = sinks_by_id[serializer.sink_id]
    assert(sink ~= nil,
      "restart-effect-facade: missing sink inventory record for " .. serializer.sink_id)
    assert(sink.authority_class == "lifecycle-authoritative",
      "restart-effect-facade: non-authoritative sink for " .. effect_id)
  end

  local facade = {}

  local function rejected_effect_reason(effect_id)
    local sink = sinks_by_id[effect_id] or sinks_by_id["queue:" .. tostring(effect_id)]
    if sink ~= nil and sink.authority_class ~= "lifecycle-authoritative" then
      return "not-lifecycle-authoritative"
    end
    return "unsupported-effect-id"
  end

  function facade.emit(grant, effect_id, sealed_snapshot, args)
    local serializer = serializers[effect_id]
    if serializer == nil then
      return nil, rejected_effect_reason(effect_id)
    end

    local sink = sinks_by_id[serializer.sink_id]
    if sink == nil or sink.authority_class ~= "lifecycle-authoritative" then
      return nil, "not-lifecycle-authoritative"
    end
    if verify_grant(grant, effect_id, sealed_snapshot) ~= true then
      return nil, "invalid-grant"
    end
    return serializer.serialize(args)
  end

  return facade
end

return M
