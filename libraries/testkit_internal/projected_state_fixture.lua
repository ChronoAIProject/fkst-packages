local M = {}

local PROJECTED_STATES = {
  dependency_wait = true,
  ready = true,
}

function M.comment_request(state_api, base_ids, proposal_id, state, version, effects)
  local repo, issue_number = base_ids.parse_proposal_id(proposal_id)
  local pr_number = nil
  if repo == nil then
    local rest = tostring(proposal_id or ""):match("^github%-devloop/pr/(.+)$")
    pr_number = rest and rest:match("/([^/]+)$") or nil
    repo = pr_number and rest:sub(1, #rest - #pr_number - 1) or nil
  end
  if repo == nil or (issue_number == nil and pr_number == nil) then
    error("testkit-internal: state-comment-fixture-invalid: proposal_id must identify an issue or pull request")
  end
  local ref = issue_number ~= nil
    and base_ids.issue_source_ref(repo, issue_number)
    or { kind = "external", ref = tostring(repo) .. "#pr/" .. tostring(pr_number) }
  local comment_dedup_key = base_ids.dedup_key({ "test-fixture", "comment", proposal_id, version, state })
  if PROJECTED_STATES[state] ~= true then
    local request = {
      schema = "github-proxy.v1",
      repo = repo,
      body = state_api.state_marker(proposal_id, state, version, effects),
      dedup_key = comment_dedup_key,
      source_ref = ref,
    }
    request[issue_number ~= nil and "issue_number" or "pr_number"] = issue_number or pr_number
    return request
  end
  if issue_number == nil then
    error("testkit-internal: state-comment-fixture-invalid: projected state must target an issue")
  end
  return state_api.build_projected_transition_comment_handoff({
    repo = repo,
    issue_number = issue_number,
    proposal_id = proposal_id,
    state = state,
    version = version,
    effects = effects,
    comment_body_prefix = "",
    comment_body_suffix = "",
    comment_dedup_key = comment_dedup_key,
    label_dedup_key = base_ids.dedup_key({ "test-fixture", "label", proposal_id, version, state }),
    source_ref = ref,
  })
end

return M
