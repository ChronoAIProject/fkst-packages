local core = require("core")
local entity = require("devloop.entity")
local observation = require("testkit_internal.old_behavior_observation_support")
local payloads_builders = require("devloop.payloads.builders")
local sha256 = require("contract.sha256")
local v_reviewing = require("devloop.validators.reviewing")
local t = fkst.test

local function copy_with(payload, key, value)
  local copy = observation.copy_value(payload)
  copy[key] = value
  return copy
end

local function reviewing_corpus()
  local valid = payloads_builders.build_devloop_reviewing_payload({
    proposal_id = "github-devloop/issue/owner/repo/42",
    impl_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-08-09T01-02-03Z",
    reviewing_comment_id = "IC_reviewing_characterization",
  }, 7, entity.pr_source_ref("owner/repo", 7))
  local bad_hand_off = observation.copy_value(valid)
  bad_hand_off.reviewing_hand_off.state = "fixing"
  return {
    v_reviewing.is_supported_reviewing(valid),
    v_reviewing.is_supported_reviewing(nil),
    v_reviewing.is_supported_reviewing(copy_with(valid, "schema", "github-devloop.reviewing.v2")),
    v_reviewing.is_supported_reviewing(copy_with(valid, "proposal_id", "unsafe proposal")),
    v_reviewing.is_supported_reviewing(copy_with(valid, "pr_number", 0)),
    v_reviewing.is_supported_reviewing(copy_with(valid, "version", string.rep("x", core._max_dedup_len + 1))),
    v_reviewing.is_supported_reviewing(copy_with(valid, "source_ref", { kind = "external", ref = "unsafe ref" })),
    v_reviewing.is_supported_reviewing(copy_with(valid, "review_delivery_dedup_key", valid.dedup_key)),
    v_reviewing.is_supported_reviewing(copy_with(valid, "review_delivery_dedup_key", "reviewing/wrong")),
    v_reviewing.is_supported_reviewing(bad_hand_off),
  }
end

return {
  test_reviewing_validator_acceptance_matrix_is_frozen = function()
    local bytes = observation.canonical_json(reviewing_corpus())
    t.eq(sha256.hex(bytes), "c29d3b53f8cc9bc15c3d001d50071260a3817c3e52bba956690330bb448027ba")
  end,
}
