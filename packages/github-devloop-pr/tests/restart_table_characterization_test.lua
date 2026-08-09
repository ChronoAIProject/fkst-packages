local core = require("core")
local observation = require("testkit_internal.old_behavior_observation_support")
local sha256 = require("contract.sha256")
local t = fkst.test

local function canonical_runtime_value(value)
  if type(value) == "function" then
    return {
      bytecode_sha256 = sha256.hex(string.dump(value, true)),
    }
  end
  if type(value) ~= "table" then
    return value
  end
  local normalized = {}
  for key, field in pairs(value) do
    normalized[key] = canonical_runtime_value(field)
  end
  return normalized
end

return {
  test_restart_policy_is_a_typed_private_kernel = function()
    local policy = assert(rawget(core, "restart_policy"), "missing typed restart policy")
    t.eq(core.restart_transition_table, policy.restart_transition_table)
    t.eq(core.maybe_timeout_redrive_from_table, policy.maybe_timeout_redrive_from_table)
    t.eq(require("devloop.restart").install, nil)
    t.eq(require("devloop.liveness").install, nil)
    t.eq(require("devloop.restart.pr_review_replay_facts").install, nil)
  end,

  test_restart_transition_table_bytes_are_frozen = function()
    local bytes = observation.canonical_json(canonical_runtime_value(core.restart_transition_table()))
    t.eq(sha256.hex(bytes), "4784704922a8a50fe500dd2532081f762db75e2b74fca33d90588cca5a965f14")
  end,
}
