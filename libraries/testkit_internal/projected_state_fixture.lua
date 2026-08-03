local M = {}

local PROJECTED_STATES = {
  dependency_wait = true,
  ready = true,
}

function M.state_marker(core, base_ids, proposal_id, state, version, effects)
  if PROJECTED_STATES[state] ~= true then
    return core.state_marker(proposal_id, state, version, effects)
  end

  local repo, issue_number = base_ids.parse_proposal_id(proposal_id)
  if repo == nil or issue_number == nil then
    error("testkit-internal: projected-state-fixture-invalid: proposal_id must identify an issue")
  end
  local ref = base_ids.issue_source_ref(repo, issue_number)
  local request = core.build_projected_transition_comment_handoff({
    repo = repo,
    issue_number = issue_number,
    proposal_id = proposal_id,
    state = state,
    version = version,
    effects = effects,
    comment_body_prefix = "",
    comment_body_suffix = "",
    comment_dedup_key = base_ids.dedup_key({ "test-fixture", "comment", proposal_id, version, state }),
    label_dedup_key = base_ids.dedup_key({ "test-fixture", "label", proposal_id, version, state }),
    source_ref = ref,
  })
  local marker = request.body:match("<!%-%- fkst:github%-devloop:state:v1.-%-%->")
  if marker == nil then
    error("testkit-internal: projected-state-fixture-missing: command did not render a state marker")
  end
  return marker
end

return M
