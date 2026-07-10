local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local forge_validators = require("devloop.forge_validators")
local payloads_builders = require("devloop.payloads.builders")
local source_refs = require("contract.source_ref")
local strings = require("contract.strings")

local C = {}

C.OWN_CI_SCHEMA = "github-devloop.own-ci-reconcile.v1"
C.MERGE_GATE_SCHEMA = "github-devloop.merge-gate-reconcile.v1"
C.FIX_LOOP_MAX_ROUNDS = "fix-loop-max-rounds"
C.CI_REPAIR_RETRY_POLICY_INVALID = "ci-repair-retry-policy-invalid"

local own_ci_reasons = {
  [C.FIX_LOOP_MAX_ROUNDS] = true,
  [C.CI_REPAIR_RETRY_POLICY_INVALID] = true,
}

local merge_gate_reasons = {
  [C.FIX_LOOP_MAX_ROUNDS] = true,
}

local function dedup_key(schema, issue_version, reason_class)
  return base_ids.dedup_key({ schema, tostring(issue_version), tostring(reason_class) })
end

local function build(schema, ctx, issue_version, reason_class)
  return {
    schema = schema,
    proposal_id = ctx.proposal_id,
    review_proposal_id = ctx.review_proposal_id,
    review_dedup_key = ctx.review_dedup_key,
    issue_version = issue_version,
    reason_class = reason_class,
    bound_head_sha = ctx.bound_head_sha,
    round = devloop_state.version_fix_round(issue_version),
    pr_number = ctx.pr_number,
    dedup_key = dedup_key(schema, issue_version, reason_class),
    source_ref = base_ids.normalize_source_ref(ctx.source_ref),
  }
end

function C.build_own_ci(ctx, issue_version, reason_class)
  if own_ci_reasons[reason_class] ~= true then
    error("github-devloop: own-ci-terminal-reason-invalid: unsupported reason class")
  end
  return build(C.OWN_CI_SCHEMA, ctx, issue_version, reason_class)
end

function C.build_merge_gate(ctx, issue_version)
  return build(C.MERGE_GATE_SCHEMA, ctx, issue_version, C.FIX_LOOP_MAX_ROUNDS)
end

local function is_supported(payload, schema, reasons)
  if type(payload) ~= "table" then
    return false
  end
  local repo, issue_number = base_ids.parse_proposal_id(payload.proposal_id)
  return payload.schema == schema
    and repo ~= nil
    and issue_number ~= nil
    and strings.is_path_safe_key(payload.proposal_id, devloop_base._max_key_len)
    and strings.is_path_safe_key(payload.review_proposal_id, devloop_base._max_key_len)
    and strings.is_bounded_string(payload.review_dedup_key, devloop_base._max_dedup_len)
    and strings.is_bounded_string(payload.issue_version, devloop_base._max_dedup_len)
    and reasons[payload.reason_class] == true
    and forge_validators.is_git_sha(payload.bound_head_sha)
    and tonumber(payload.round) == devloop_state.version_fix_round(payload.issue_version)
    and forge_validators.is_positive_pr_number(payload.pr_number)
    and payload.dedup_key == dedup_key(schema, payload.issue_version, payload.reason_class)
    and source_refs.has_bounded_source_ref(payload.source_ref, devloop_base._max_key_len)
end

function C.is_supported_own_ci(payload)
  return is_supported(payload, C.OWN_CI_SCHEMA, own_ci_reasons)
end

function C.is_supported_merge_gate(payload)
  return is_supported(payload, C.MERGE_GATE_SCHEMA, merge_gate_reasons)
end

function C.build_decompose(intent)
  return payloads_builders.build_devloop_decompose_payload({
    proposal_id = intent.proposal_id,
    pr_number = intent.pr_number,
    issue_version = intent.issue_version,
    review_proposal_id = intent.review_proposal_id,
    review_dedup_key = intent.review_dedup_key,
    head_sha = intent.bound_head_sha,
    round = intent.round,
    source_ref = intent.source_ref,
  })
end

return C
