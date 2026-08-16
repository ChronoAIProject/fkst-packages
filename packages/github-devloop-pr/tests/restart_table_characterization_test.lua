local core = require("core")
local observation = require("testkit_internal.old_behavior_observation_support")
local sha256 = require("contract.sha256")
local t = fkst.test

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
    local bytes = observation.canonical_json(core.restart_transition_table())
    t.eq(sha256.hex(bytes), "bf0ed6c5f50c00740d40186dd8ffff5e4c8551e5b316571cf6050e0483b06090")
  end,
}
