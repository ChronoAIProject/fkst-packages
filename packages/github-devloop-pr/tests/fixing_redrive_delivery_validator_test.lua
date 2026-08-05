local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local v_fixing = require("devloop.validators.fixing")

local t = h.t

local function replayed(redrive_delivery)
  local fixing = h.fixing()
  return payloads_builders.build_replayed_fixing_payload({
    proposal_id = fixing.proposal_id,
    impl_version = fixing.version,
  }, fixing.pr_number, fixing, fixing.source_ref, redrive_delivery)
end

return {
  test_fixing_validator_accepts_typed_redrive_delivery_identity = function()
    local payload = replayed({
      generation_key = "fixing/actionable/2026-06-03T02-01-00Z",
      attempt = 3,
    })
    t.eq(v_fixing.is_supported_fixing(payload), true)
    t.eq(payload.redrive_delivery.generation_key,
      "fixing/actionable/2026-06-03T02-01-00Z")
    t.eq(payload.redrive_delivery.attempt, 3)
  end,

  test_fixing_validator_rejects_malformed_or_mismatched_redrive_delivery = function()
    local malformed = replayed({
      generation_key = "fixing/actionable/2026-06-03T02-01-00Z",
      attempt = 3,
    })
    malformed.redrive_delivery.attempt = 0
    t.eq(v_fixing.is_supported_fixing(malformed), false)

    local mismatched = replayed({
      generation_key = "fixing/actionable/2026-06-03T02-01-00Z",
      attempt = 3,
    })
    mismatched.dedup_key = mismatched.dedup_key .. "/different"
    t.eq(v_fixing.is_supported_fixing(mismatched), false)
  end,
}
