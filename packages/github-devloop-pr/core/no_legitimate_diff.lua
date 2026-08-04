local M = {}

local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_view = require("devloop.github_proxy_entity_view")
local entity_lib = require("devloop.entity")
local transition_version = require("contract.transition_version")

M.reason = "no-legitimate-diff: current PR head has no file delta against its base; no reviewable implementation remains"

function M.risk_is_empty_diff(risk)
  return type(risk) == "table"
    and risk.known == false
    and risk.reason == "diff-name-only-empty"
end

function M.closed_unmerged_version(state_or_version)
  local version = type(state_or_version) == "table" and state_or_version.version or state_or_version
  return transition_version.strip_suffixes(version)
end

function M.closed_unmerged_comment_request(core, repo, pr_number, proposal_id, version, source_ref, reason)
  local effective_version = M.closed_unmerged_version(version)
  local request = entity_lib.build_entity_comment_request({
    kind = "pr",
    repo = repo,
    number = pr_number,
  }, "github-devloop marked delegated PR child closed without merge"
    .. "\n\nReason: " .. tostring(reason or M.reason)
    .. "\n\n" .. devloop_state.state_marker(proposal_id, "closed-unmerged", effective_version)
    .. "\n" .. "⟦AI:FKST⟧", base_ids.dedup_key({
    "child-pr",
    "closed-unmerged",
    tostring(proposal_id),
    tostring(effective_version),
    tostring(pr_number),
  }), source_ref)
  request.handoff = {
    kind = "github-devloop.closed_unmerged",
    proposal_id = proposal_id,
    pr_number = pr_number,
    version = effective_version,
    source_ref = source_ref,
  }
  return request, effective_version
end

function M.raise_closed_unmerged(dept, core, repo, pr_number, proposal_id, state, source_ref)
  if devloop_base.read_env("FKST_GITHUB_WRITE") ~= "1" then
    devloop_logging.log_line("info", dept, proposal_id, "GATE", {
      "outcome=dry-run",
      "reason=no-legitimate-diff close requires FKST_GITHUB_WRITE=1",
      "pr=" .. tostring(pr_number),
    })
    return
  end
  local close_result = devloop_commands.gh_pr_close(repo, pr_number, 60)
  if close_result.exit_code ~= 0 then
    error("github-devloop: no-legitimate-diff-pr-close-failed: " .. tostring(close_result.stderr))
  end
  entity_view.invalidate_entity_after_write(repo, "pr", pr_number)
  devloop_logging.log_line("info", dept, proposal_id, "OUTBOUND", {
    "mode=real",
    "repo=" .. tostring(repo),
    "pr=" .. tostring(pr_number),
    "reason=closed PR with no legitimate diff before terminal marker",
  })
  local request, version = M.closed_unmerged_comment_request(core, repo, pr_number, proposal_id, state, source_ref, M.reason)
  devloop_logging.log_cas_decision(dept, proposal_id, state, state and state.state or "reviewing", "closed-unmerged", "applied(no-legitimate-diff)", M.reason)
  local add_labels, remove_labels = devloop_state.state_label_changes("closed-unmerged")
  devloop_logging.log_apply(dept, proposal_id, "closed-unmerged", version, { add = add_labels, remove = remove_labels }, {
    "gh_pr_close",
    "github-proxy.github_pr_comment_request",
  })
  devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_pr_comment_request", request)
end

return M
