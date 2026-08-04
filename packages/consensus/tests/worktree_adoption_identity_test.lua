local consensus = require("consensus")
local t = fkst.test

local angles = { "teleology", "parsimony", "fidelity" }

local function proposal(dedup_key)
  return {
    schema = "consensus.proposal.v1",
    proposal_id = "delivery-local-proposal",
    title = "Adopt completed consensus seats",
    body = "Replay one consensus invocation after its delivery owner exits.",
    context = "The replay must keep the stable child work identities.",
    angles = angles,
    dedup_key = dedup_key,
    source_ref = {
      kind = "external",
      ref = "fixture/repo#proposal/42",
    },
  }
end

local function mock_consensus()
  for _ = 1, 2 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/consensus-worktree-adoption",
      stderr = "",
      exit_code = 0,
    })
    for _, angle in ipairs(angles) do
      t.mock_command("mkdir -p", {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("codex exec", {
        stdout = "⟦FKST:VERDICT⟧ approve\n⟦FKST:REPLY⟧ " .. angle .. " approves.\n",
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function calls_by_angle()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      for _, angle in ipairs(angles) do
        if call.stdin:find("Angle: " .. angle, 1, true) ~= nil then
          calls[angle] = calls[angle] or {}
          table.insert(calls[angle], call)
        end
      end
    end
  end
  return calls
end

return {
  test_redelivery_keeps_scratch_worktree_bound_to_stable_invocation_identity = function()
    mock_consensus()

    local first = consensus.reach(proposal("delivery-a"), { invocation_id = "stable-invocation-42" })
    local second = consensus.reach(proposal("delivery-b"), { invocation_id = "stable-invocation-42" })

    t.eq(first.status, "reached")
    t.eq(second.status, "reached")
    local calls = calls_by_angle()
    for _, angle in ipairs(angles) do
      t.eq(#calls[angle], 2)
      t.eq(calls[angle][1].cwd, calls[angle][2].cwd)
    end
  end,
}
