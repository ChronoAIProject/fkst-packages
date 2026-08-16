local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local requests_labels = require("devloop.requests.labels")
local forge_validators = require("devloop.forge_validators")
local transition_version = require("contract.transition_version")
local comment_strings = require("devloop.strings")
local m_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")
local devloop_logging = require("devloop.logging")

local T = {}

function T.install(M)
local function linked_pr_state(pr)
  return tostring(pr and pr.state or ""):upper()
end

local function merged_head_sha(pr)
  local head_sha = tostring(pr and pr.head_sha or "")
  return forge_validators.is_git_sha(head_sha) and head_sha or nil
end

local mark_child_closed_unmerged
local mark_issue_merged_from_linked_pr

mark_child_closed_unmerged = function(dept, issue, state, proposal_id, link, tools, outcome, reason)
  local version = transition_version.strip_suffixes(state and state.version)
  local pr_number = link and link.pr_number
  local source_ref = pr_number ~= nil and entity_lib.pr_source_ref(issue.repo, pr_number) or issue.source_ref
  local comment_request = entity_lib.build_entity_comment_request({
    kind = "pr",
    repo = issue.repo,
    number = pr_number,
  }, "github-devloop marked delegated PR child closed without merge"
    .. "\n\nReason: " .. tostring(reason or "closed without merge")
    .. "\n\n" .. devloop_state.state_marker(proposal_id, "closed-unmerged", version)
    .. "\n" .. "⟦AI:FKST⟧", base_ids.dedup_key({
    "child-pr",
    "closed-unmerged",
    tostring(proposal_id),
    tostring(version),
    tostring(pr_number),
  }), source_ref)
  comment_request.handoff = {
    kind = "github-devloop.closed_unmerged",
    proposal_id = proposal_id,
    pr_number = pr_number,
    version = version,
    source_ref = source_ref,
  }
  devloop_logging.log_cas_decision(dept, proposal_id, state, state and state.state or "pr-open", "closed-unmerged", outcome, reason)
  local add_labels, remove_labels = devloop_state.state_label_changes("closed-unmerged")
  return tools.raise_effects(dept, proposal_id, "closed-unmerged", version, { add = add_labels, remove = remove_labels }, {
    { queue = "github-proxy.github_pr_comment_request", payload = comment_request },
  })
end

mark_issue_merged_from_linked_pr = function(dept, issue, state, proposal_id, link, pr, tools)
  local head_sha = merged_head_sha(pr)
  if head_sha == nil then
    return tools.log_skip(dept, proposal_id, state, state.state, "merged", "skip-foreign(head)", "merged linked PR head sha is missing")
  end
  local merged_body = comment_strings.comment_string(M.output_language, "merged_pr_prefix") .. tostring(link.pr_number)
    .. "\n\n" .. devloop_state.state_marker(proposal_id, "merged", state.version)
    .. "\n" .. m_builders.merged_marker(proposal_id, link.pr_number, state.version, head_sha)
  local source_ref = entity_lib.pr_source_ref(issue.repo, link.pr_number)
  local comment_request = entity_lib.build_entity_comment_request({
    kind = "issue",
    repo = issue.repo,
    number = issue.number,
  }, merged_body, base_ids.dedup_key({
    "orphaned-pr",
    "merged",
    tostring(proposal_id),
    tostring(state.version),
    tostring(link.pr_number),
    tostring(head_sha),
  }), issue.source_ref)
  local label_request = requests_labels.build_state_label_request(issue.repo,
    issue.number,
    "merged",
    proposal_id,
    state.version,
    base_ids.dedup_key({
      "orphaned-pr",
      "label",
      "merged",
      tostring(proposal_id),
      tostring(state.version),
      tostring(link.pr_number),
      tostring(head_sha),
    }),
    issue.source_ref
  )
  local add_labels, remove_labels = devloop_state.state_label_changes("merged")
  devloop_logging.log_cas_decision(dept, proposal_id, state, state.state, "merged", "applied(linked-pr-merged)", "linked PR is merged; marking issue complete")
  return tools.raise_effects(dept, proposal_id, "merged", state.version, { add = add_labels, remove = remove_labels }, {
    { queue = "github-proxy.github_issue_comment_request", payload = comment_request },
    { queue = "github-proxy.github_issue_label_request", payload = label_request },
  })
end

local function redrive_absent_replacement_pr(dept, issue, state, proposal_id, link, facts, tools)
  if facts.snapshot.absent_prs ~= nil and facts.snapshot.absent_prs[tostring(link.pr_number or "")] == true then
    return mark_child_closed_unmerged(dept, issue, state, proposal_id, link, tools, "applied(orphaned-pr-absent)", "linked PR is absent; parent awaiting-pr will re-drive implementation from child terminal")
  end
  return nil
end

local function terminal_linked_pr_action(dept, issue, state, proposal_id, link, pr, facts, tools)
  if pr == nil then
    return redrive_absent_replacement_pr(dept, issue, state, proposal_id, link, facts, tools)
  end
  local state_name = linked_pr_state(pr)
  if state_name == "MERGED" then
    return mark_issue_merged_from_linked_pr(dept, issue, state, proposal_id, link, pr, tools)
  end
  if state_name ~= "OPEN" then
    return mark_child_closed_unmerged(dept, issue, state, proposal_id, link, tools, "applied(orphaned-pr-closed)", "linked PR is closed; parent awaiting-pr will re-drive implementation from child terminal")
  end
  return nil
end

return {
  linked_pr_state = linked_pr_state,
  mark_child_closed_unmerged = mark_child_closed_unmerged,
  mark_issue_merged_from_linked_pr = mark_issue_merged_from_linked_pr,
  redrive_absent_replacement_pr = redrive_absent_replacement_pr,
  terminal_linked_pr_action = terminal_linked_pr_action,
}
end

return T
