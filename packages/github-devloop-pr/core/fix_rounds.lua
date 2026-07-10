local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local ci_verdict = require("core.ci_verdict")
local fix_terminal = require("core.fix_terminal")
local OWN_CI_RED = ci_verdict.OWN_CI_RED

local C = {}

local function terminate(state, ctx, round, intent)
  local decompose = fix_terminal.build_decompose(intent)
  local dept = ctx.dept or "merge"
  local from_state = ctx.from_state or state.state or "merge-ready"
  devloop_logging.log_cas_decision(dept, ctx.proposal_id, state, from_state, "blocked", "applied(fix-loop-max-rounds)", ctx.reason)
  devloop_logging.log_raise(dept, ctx.proposal_id, "devloop_fix_reconcile", intent)
  devloop_logging.log_raise(dept, ctx.proposal_id, "github-devloop-decompose.devloop_decompose", decompose)
  return {
    kind = "terminate",
    round = round,
    reconcile = intent,
    decompose = decompose,
  }
end

-- The budget is derived only from the stable `/fix/N` version lineage, never from a
-- drifting external key (e.g. a merge-queue predecessor set), so no such key can reset it.
local function admit_decision(state)
  local round = devloop_state.version_fix_round(state.version)
  if round >= config.max_fix_rounds() then
    return { kind = "terminate", round = round }
  end
  local version = devloop_state.next_fix_version(state.version)
  return {
    kind = "admit",
    round = devloop_state.version_fix_round(version),
    version = version,
  }
end

-- This is the only operation allowed to admit an own-CI-red fixing continuation.
function C.admit_own_ci_continuation(state, classification, ctx)
  if type(state) ~= "table" or type(classification) ~= "table" or type(ctx) ~= "table" then
    error("github-devloop: own-ci-admission-invalid: state, classification, and context are required")
  end
  local current_pr = classification.current_pr
  local bound_head_sha = tostring(classification.head_sha or "")
  if bound_head_sha == "" then
    error("github-devloop: own-ci-admission-invalid: current PR head is required")
  end
  if type(current_pr) ~= "table" or tostring(current_pr.head_sha or "") ~= bound_head_sha then
    error("github-devloop: own-ci-admission-invalid: classified PR head is inconsistent")
  end
  local pr_state = tostring(current_pr.state or ""):upper()
  if pr_state == "MERGED" then
    return { kind = "pr-merged", current_pr = current_pr }
  end
  if pr_state ~= "OPEN" then
    return { kind = "pr-closed", current_pr = current_pr }
  end
  if (ctx.head_branch ~= nil and tostring(current_pr.head_ref_name or "") ~= tostring(ctx.head_branch))
    or (ctx.base_branch ~= nil and tostring(current_pr.base_ref_name or "") ~= tostring(ctx.base_branch)) then
    return { kind = "identity-mismatch", current_pr = current_pr }
  end
  if classification.kind ~= OWN_CI_RED then
    return {
      kind = "not-own-ci",
      reason = classification.reason,
      current_pr = current_pr,
      bound_head_sha = bound_head_sha,
    }
  end
  local decision = admit_decision(state)
  if decision.kind == "terminate" then
    local terminal_ctx = {}
    for key, value in pairs(ctx) do terminal_ctx[key] = value end
    terminal_ctx.bound_head_sha = bound_head_sha
    terminal_ctx.reason = ctx.reason or classification.reason
    local intent = fix_terminal.build_own_ci(terminal_ctx, state.version, fix_terminal.FIX_LOOP_MAX_ROUNDS)
    return terminate(state, terminal_ctx, decision.round, intent)
  end
  decision.current_pr = current_pr
  decision.reason = classification.reason
  decision.ci_failure_key = classification.ci_failure_key
  decision.bound_head_sha = bound_head_sha
  return decision
end

function C.terminate_own_ci_policy_invalid(state, ctx)
  if type(state) ~= "table" or type(ctx) ~= "table" then
    error("github-devloop: own-ci-policy-terminal-invalid: state and context are required")
  end
  local round = devloop_state.version_fix_round(state.version)
  local intent = fix_terminal.build_own_ci(ctx, state.version, fix_terminal.CI_REPAIR_RETRY_POLICY_INVALID)
  return terminate(state, ctx, round, intent)
end

-- Non-own-CI merge-gate continuations retain their existing capped behavior. They do not
-- carry the own-CI classification and therefore cannot call the authority above.
function C.admit_or_terminate(state, ctx)
  if type(state) ~= "table" or type(ctx) ~= "table" then
    error("github-devloop: fix-round-admission-invalid: state and context are required")
  end
  local decision = admit_decision(state)
  if decision.kind == "terminate" then
    local intent = fix_terminal.build_merge_gate(ctx, state.version)
    return terminate(state, ctx, decision.round, intent)
  end
  return decision
end

return C
