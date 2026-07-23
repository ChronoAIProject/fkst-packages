local base_ids = require("devloop.base_ids")
local payload_registry = require("devloop.payload_registry")
local payloads_builders = require("devloop.payloads.builders")

local t = fkst.test

local function assert_rejected(token, message)
  local ok, failure = pcall(payload_registry.validate, token)
  t.eq(ok, false)
  t.is_true(tostring(failure):find(message, 1, true) ~= nil)
end

return {
  test_validate_accepts_only_registered_dedup_strategies = function()
    t.eq(payload_registry.validate("dedup:ready"), true)
    t.eq(payload_registry.validate("dedup:reviewing"), true)
    assert_rejected("unknown:ready", "unknown prefix unknown")
    assert_rejected("dedup:unregistered", "unknown dedup strategy unregistered")
    assert_rejected("marker:unregistered.value", "unknown marker family unregistered")
  end,

  test_resolve_returns_missing_evidence_without_partial_value = function()
    local value, failure = payload_registry.resolve("dedup:ready", {})
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")

    value, failure = payload_registry.resolve("dedup:reviewing", {
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = "ready/version",
    })
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")
  end,

  test_ready_builder_dedup_is_byte_exact_with_previous_expression = function()
    local source = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-07-23T01-02-03Z",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    }
    local payload = payloads_builders.build_devloop_ready_payload({
      _max_impl_retry_attempts = 3,
    }, source)
    local previous = base_ids.dedup_key({
      "ready",
      tostring(source.dedup_key),
    })
    t.eq(payload.dedup_key, previous)
  end,

  test_reviewing_builder_dedup_is_byte_exact_with_previous_expression = function()
    local origin = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      impl_version = "ready/version",
    }
    local pr_number = 17
    local payload = payloads_builders.build_devloop_reviewing_payload(
      origin,
      pr_number,
      { kind = "external", ref = "owner/repo#pr/17" }
    )
    local previous = base_ids.dedup_key({
      "reviewing",
      tostring(origin.proposal_id),
      tostring(origin.impl_version),
      tostring(pr_number),
    })
    t.eq(payload.dedup_key, previous)
  end,
}
