local M = {}

local function issue_identity(proposal_id)
  local repo, issue_number = tostring(proposal_id or ""):match(
    "^github%-devloop/issue/(.+)/(%d+)$"
  )
  if repo == nil then
    error("testkit-internal: projected-state-fixture-proposal-invalid: issue proposal_id is required")
  end
  return repo, tonumber(issue_number)
end

function M.bind(state_api)
  if type(state_api) ~= "table"
    or type(state_api.build_projected_state_comment_request) ~= "function" then
    error("testkit-internal: projected-state-fixture-api-invalid: canonical state API is required")
  end
  return function(proposal_id, state, version, effects)
    local repo, issue_number = issue_identity(proposal_id)
    local source_ref = {
      kind = "external",
      ref = repo .. "#issue/" .. tostring(issue_number),
    }
    return state_api.build_projected_state_comment_request({
      repo = repo,
      issue_number = issue_number,
      proposal_id = proposal_id,
      state = state,
      marker_version = version,
      handoff_version = version,
      effects = effects,
      body_before_marker = "",
      body_after_marker = "",
      comment_dedup_key = "test-fixture/projected-state/comment/" .. tostring(state),
      label_policy = {
        dedup_key = "test-fixture/projected-state/label/" .. tostring(state),
      },
      source_ref = source_ref,
    }).body
  end
end

function M.bind_state_comment(state_api)
  local projected_state_comment = M.bind(state_api)
  return function(proposal_id, state, version, effects)
    if state == "ready" or state == "dependency_wait" then
      return projected_state_comment(proposal_id, state, version, effects)
    end
    return state_api.state_marker(proposal_id, state, version, effects)
  end
end

return M
