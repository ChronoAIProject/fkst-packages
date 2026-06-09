local S = {}

function S.install(M)
local function is_terminal_state(state)
  return state == "merged" or state == "blocked" or state == "impl-failed"
end

function M.is_status_card_terminal_state(state)
  return is_terminal_state(state)
end

function M.build_status_card_comment_request(repo, issue_number, proposal_id, current, source_ref)
  if type(current) ~= "table" or current.state == nil or current.version == nil then
    error("github-devloop: invalid status card state")
  end
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    dedup_key = M._dedup_key({
      "status-card",
      "comment",
      tostring(proposal_id),
    }),
    upsert = true,
    render = {
      kind = "github-devloop-status-card",
      proposal_id = proposal_id,
    },
    source_ref = M.normalize_source_ref(source_ref),
  }
end
end

return S
