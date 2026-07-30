local h = require("tests.devloop_helpers")
local strings = require("contract.strings")

local t = h.t
local core = h.core
local implementation_result = require("departments.implement.implementation_result")

local proposal_id = "github-devloop/issue/owner/repo/42"
local implementation_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function receipt(outcome, fields)
  local values = {
    '"schema":"github-devloop.implementation-result.v1"',
    '"outcome":' .. strings.json_string(outcome),
    '"proposal_id":' .. strings.json_string(proposal_id),
    '"implementation_version":' .. strings.json_string(implementation_version),
    '"attempt":1',
  }
  for _, field in ipairs(fields or {}) do
    table.insert(values, field)
  end
  return "{" .. table.concat(values, ",") .. "}"
end

local function expected(overrides)
  local value = {
    proposal_id = proposal_id,
    implementation_version = implementation_version,
    attempt = 1,
  }
  for key, field in pairs(overrides or {}) do
    value[key] = field
  end
  return value
end

local function decode_fails(raw, expected_fields)
  local value, err = implementation_result.decode(raw, expected_fields or expected())
  t.eq(value, nil)
  t.eq(type(err), "string")
  t.is_true(err ~= "")
end

return {
  test_changes_produced_receipt_accepts_only_the_exact_common_shape = function()
    local value, err = implementation_result.decode(receipt("changes-produced"), expected())

    t.eq(err, nil)
    t.eq(value.schema, "github-devloop.implementation-result.v1")
    t.eq(value.outcome, "changes-produced")
    t.eq(value.proposal_id, proposal_id)
    t.eq(value.implementation_version, implementation_version)
    t.eq(value.attempt, 1)
    t.eq(value.reason, nil)
    t.eq(value.evidence, nil)
  end,

  test_precursor_missing_receipt_preserves_bounded_evidence = function()
    local value, err = implementation_result.decode(receipt("cannot-implement-here", {
      '"reason":"precursor-missing"',
      '"evidence":"Required generated parser is absent from packages/parser."',
    }), expected())

    t.eq(err, nil)
    t.eq(value.outcome, "cannot-implement-here")
    t.eq(value.reason, "precursor-missing")
    t.eq(value.evidence, "Required generated parser is absent from packages/parser.")
  end,

  test_receipt_rejects_malformed_or_unsupported_shapes = function()
    decode_fails("not-json")
    decode_fails(receipt("changes-produced", { '"extra":"unsupported"' }))
    decode_fails(receipt("future-outcome"))
    decode_fails(receipt("cannot-implement-here", {
      '"reason":"scope-mismatch"',
      '"evidence":"The requested file is absent."',
    }))
    decode_fails(receipt("cannot-implement-here", {
      '"reason":"precursor-missing"',
      '"evidence":"   "',
    }))
  end,

  test_receipt_rejects_identity_and_attempt_mismatches = function()
    decode_fails(receipt("changes-produced"), expected({ proposal_id = proposal_id .. "/other" }))
    decode_fails(receipt("changes-produced"), expected({ implementation_version = implementation_version .. "/other" }))
    decode_fails(receipt("changes-produced"), expected({ attempt = 2 }))
  end,

  test_receipt_enforces_output_and_evidence_bounds = function()
    decode_fails(string.rep(" ", core._max_impl_output_len + 1))

    local bounded = implementation_result.decode(receipt("cannot-implement-here", {
      '"reason":"precursor-missing"',
      '"evidence":' .. strings.json_string(string.rep("e", core._max_blocking_gap_len)),
    }), expected())
    t.is_true(bounded ~= nil)

    decode_fails(receipt("cannot-implement-here", {
      '"reason":"precursor-missing"',
      '"evidence":' .. strings.json_string(string.rep("e", core._max_blocking_gap_len + 1)),
    }))
  end,
}
