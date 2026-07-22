local base_ids = require("devloop.base_ids")
local awaiting_pr_replayer = require("core.awaiting_pr_replayer")
local conv_reconcile = require("devloop.convergence.reconcile")
local entity_lib = require("devloop.entity")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
local restart_effect_facade = require("devloop.restart_effect_facade")

local M = {}

local PROPOSAL_EFFECT_ID = "consensus.proposal"
local COMMENT_EFFECT_ID = "github-proxy.github_issue_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"

local function serialize_thinking_proposal(args)
  if type(args) ~= "table" or type(args.proposal) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return args.proposal
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

local function serialize_implement_activation_comment(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.ready) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_lifecycle.build_implementing_state_comment_request(
    args.core,
    args.issue.repo,
    args.issue.number,
    args.ready,
    args.worktree,
    args.branch,
    args.base_branch,
    args.base_sha,
    args.attempt,
    args.started_at,
    args.exec_ref
  )
end

local function serialize_implement_activation_label(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.ready) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_labels.build_implementing_label_request(
    args.issue.repo, args.issue.number, args.ready
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

local function valid_consensus_result_args(args)
  return type(args) == "table"
    and type(args.core) == "table"
    and type(args.repo) == "string"
    and args.issue_number ~= nil
    and type(args.reached) == "table"
    and type(args.to_state) == "string"
end

local function serialize_consensus_result_comment(args)
  if not valid_consensus_result_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return requests_lifecycle.build_result_comment_request(
    args.core,
    args.repo,
    args.issue_number,
    args.reached,
    args.to_state
  )
end

local function serialize_consensus_result_label(args)
  if not valid_consensus_result_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  if args.to_state == "declined" then
    return requests_labels.build_result_state_label_request(
      args.repo,
      args.issue_number,
      args.reached,
      "declined"
    )
  end
  return requests_labels.build_result_label_request(
    args.repo,
    args.issue_number,
    args.reached
  )
end

local function serialize_awaiting_pr_comment(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.state) ~= "table"
    or type(args.delegation) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return awaiting_pr_replayer.build_awaiting_pr_canonicalization_comment_request(
    args.issue,
    args.state,
    args.delegation
  )
end

local function serialize_awaiting_pr_label(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.state) ~= "table"
    or type(args.delegation) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  local source_ref = args.issue.source_ref
    or entity_lib.issue_source_ref(args.issue.repo, args.issue.number)
  return requests_labels.build_state_label_request(
    args.issue.repo,
    args.issue.number,
    "awaiting-pr",
    args.delegation.proposal_id,
    args.state.version,
    base_ids.dedup_key({
      "awaiting-pr",
      "canonicalize",
      "implementing",
      "label",
      tostring(args.delegation.proposal_id),
      tostring(args.state.version),
      tostring(args.delegation.pr_number),
      tostring(args.delegation.delegation),
    }),
    source_ref
  )
end

local function valid_awaiting_pr_exit_args(args)
  return type(args) == "table"
    and type(args.issue) == "table"
    and type(args.state) == "table"
    and type(args.next_state) == "table"
    and type(args.child_state) == "table"
    and type(args.delegation) == "table"
    and type(args.current_pr) == "table"
    and type(args.proposal_id) == "string"
end

local function serialize_awaiting_pr_exit_comment(args)
  if not valid_awaiting_pr_exit_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  return awaiting_pr_replayer.build_resume_comment_request(
    args.issue,
    args.state,
    args.next_state,
    args.child_state,
    args.delegation,
    args.current_pr
  )
end

local function serialize_awaiting_pr_exit_label(args)
  if not valid_awaiting_pr_exit_args(args) then
    return nil, "invalid-serializer-arguments"
  end
  local source_ref = args.issue.source_ref
    or entity_lib.issue_source_ref(args.issue.repo, args.issue.number)
  return requests_labels.build_state_label_request(
    args.issue.repo,
    args.issue.number,
    args.next_state.to_state,
    args.proposal_id,
    args.next_state.version,
    base_ids.dedup_key({
      "awaiting-pr",
      "label",
      tostring(args.proposal_id),
      tostring(args.delegation.pr_number),
      tostring(args.delegation.delegation),
      tostring(args.next_state.to_state),
      tostring(args.next_state.version),
    }),
    source_ref
  )
end

local function serialize_loop_plain_comment(args)
  if type(args) ~= "table"
    or type(args.core) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.unresolved) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_lifecycle.build_converge_round_comment_request(
    args.core,
    args.issue.repo,
    args.issue.number,
    args.unresolved,
    args.round,
    args.marker_body,
    args.handoff
  )
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

local function serialize_timeout_reconcile_comment(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.reconcile) ~= "table"
    or type(args.why_fields) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return conv_reconcile.build_timeout_reconcile_comment_request(
    args.issue.repo,
    args.issue.number,
    args.reconcile,
    args.action,
    args.reason,
    args.state_version,
    args.why_fields
  )
end

local function serialize_timeout_reconcile_label(args)
  if type(args) ~= "table"
    or type(args.issue) ~= "table"
    or type(args.reconcile) ~= "table" then
    return nil, "invalid-serializer-arguments"
  end
  return requests_labels.build_state_label_request(
    args.issue.repo,
    args.issue.number,
    "blocked",
    args.reconcile.proposal_id,
    args.state_version,
    base_ids.dedup_key({
      "timeout-reconcile",
      "label",
      tostring(args.reconcile.dedup_key),
    }),
    args.reconcile.source_ref
  )
end

local SERIALIZERS_BY_FAMILY = {
  ["awaiting-pr"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:awaiting-pr-state",
      serialize = serialize_awaiting_pr_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:awaiting-pr-state",
      serialize = serialize_awaiting_pr_label,
    },
  },
  ["awaiting-pr-exit"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:awaiting-pr-terminal",
      serialize = serialize_awaiting_pr_exit_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:awaiting-pr-terminal",
      serialize = serialize_awaiting_pr_exit_label,
    },
  },
  ["implement-activation"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:implementation-start",
      serialize = serialize_implement_activation_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:implementation-start",
      serialize = serialize_implement_activation_label,
    },
  },
  ["loop-plain"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:converge-round",
      serialize = serialize_loop_plain_comment,
    },
  },
  ["observe-issue-entry"] = {
    [PROPOSAL_EFFECT_ID] = {
      sink_id = "queue:consensus.proposal",
      serialize = serialize_thinking_proposal,
    },
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:thinking-state",
      serialize = serialize_thinking_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:thinking-state",
      serialize = serialize_thinking_label,
    },
  },
  ["consensus-result"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:consensus-result",
      serialize = serialize_consensus_result_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:consensus-result",
      serialize = serialize_consensus_result_label,
    },
  },
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
  ["timeout-reconcile"] = {
    [COMMENT_EFFECT_ID] = {
      sink_id = "comment:issue:timeout-reconcile",
      serialize = serialize_timeout_reconcile_comment,
    },
    [LABEL_EFFECT_ID] = {
      sink_id = "label:issue:timeout-reconcile",
      serialize = serialize_timeout_reconcile_label,
    },
  },
}

function M.make(config)
  assert(type(config) == "table", "restart-effect-facade: config is required")
  assert(type(config.family) == "string" and SERIALIZERS_BY_FAMILY[config.family] ~= nil,
    "restart-effect-facade: supported family is required")
  return restart_effect_facade.make({
    verify_grant = config.verify_grant,
    sink_inventory = config.sink_inventory,
    serializers = SERIALIZERS_BY_FAMILY[config.family],
  })
end

return M
