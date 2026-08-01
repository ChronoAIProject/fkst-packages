local devloop_state = require("devloop.state")
local requests_lifecycle = require("devloop.requests.lifecycle")

local M = {}

function M.effects(batch)
  local effects = {}
  local previous_raise = raise
  raise = function(queue, payload)
    table.insert(effects, { queue = queue, payload = payload })
  end
  local ok, err = pcall(
    devloop_state.emit_projected_state_transition_batch,
    batch,
    "projected-transition-test",
    "github-devloop/issue/owner/repo/42"
  )
  raise = previous_raise
  if not ok then
    error(err, 0)
  end
  assert(#effects == 2, "projected transition must emit its comment and label effects")
  return effects
end

function M.result_comment(core, repo, issue_number, reached, state_name)
  local batch = requests_lifecycle.build_result_transition_effects(
    core,
    repo,
    issue_number,
    reached,
    state_name
  )
  return M.effects(batch)[1].payload
end

return M
