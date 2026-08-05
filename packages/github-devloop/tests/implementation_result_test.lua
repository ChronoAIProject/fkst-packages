local h = require("tests.devloop_helpers")
local strings = require("contract.strings")
local harvest = require("departments.implement.harvest")
local requests_lifecycle = require("devloop.requests.lifecycle")

local t = h.t
local core = h.core
local implementation_result = require("departments.implement.implementation_result")

local proposal_id = "github-devloop/issue/owner/repo/42"
local implementation_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local refusal_reasons = {
  "precursor-missing",
  "wrong-layer",
  "already-satisfied",
}
local production_refusal_receipts = {
  {
    raw = [[{"schema":"github-devloop.implementation-result.v1","outcome":"cannot-implement-here","proposal_id":"github-devloop/issue/ChronoAIProject/fkst-packages/2983","implementation_version":"ready/github-devloop/issue/ChronoAIProject/fkst-packages/2983/intake/1664313850","attempt":1,"reason":"wrong-layer","evidence":"Repository ground truth assigns delivery, subscription routing, leases, acknowledgements, retries, and dead-letter state to `fkst-substrate`. The pinned engine revision has no `delivery_key`, `one_outstanding`, or `pending_dirty` primitive. The rejected `39361c10` attempt instead reconstructed subscriber state through `fkst.observe({ limit = 10000 })` and synthetic `/rearm/` keys. `scripts/run.sh test-affected` passed; the worktree remains clean as the issue acceptance requires."}]],
    expected = {
      proposal_id = "github-devloop/issue/ChronoAIProject/fkst-packages/2983",
      implementation_version = "ready/github-devloop/issue/ChronoAIProject/fkst-packages/2983/intake/1664313850",
      attempt = 1,
    },
    evidence_len = 483,
  },
  {
    raw = [[{"schema":"github-devloop.implementation-result.v1","outcome":"cannot-implement-here","proposal_id":"github-devloop/issue/ChronoAIProject/fkst-packages/2979","implementation_version":"ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2979/intake/2354696917/loop/4","attempt":1,"reason":"wrong-layer","evidence":"`fkst.observe()` provides no cross-request snapshot isolation, and `raise()` only buffers in-process; durable publish occurs later in the supervisor after `once` returns. Package-side revalidation therefore leaves the prohibited check-to-enqueue race. The required producer-owned atomic version validation needs an engine primitive in `fkst-substrate`, while this repository explicitly owns only Lua package behavior. `scripts/run.sh test-affected` passed with `FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE`; the worktree remains clean."}]],
    expected = {
      proposal_id = "github-devloop/issue/ChronoAIProject/fkst-packages/2979",
      implementation_version = "ready/consensus-github-devloop/issue/ChronoAIProject/fkst-packages/2979/intake/2354696917/loop/4",
      attempt = 1,
    },
    evidence_len = 532,
  },
  {
    raw = [[{"schema":"github-devloop.implementation-result.v1","outcome":"cannot-implement-here","proposal_id":"github-devloop/issue/ChronoAIProject/fkst-packages/2787","implementation_version":"ready/github-devloop/issue/ChronoAIProject/fkst-packages/2787/intake/1722137326/reimplement/2","attempt":2,"reason":"already-satisfied","evidence":"HEAD aba2a4da already has `github-devloop-ops.observability` consume both `restart_transition_anomaly` queues ephemerally, with composition dependencies and regression coverage introduced atomically by 9b0f6aff. `scripts/run.sh test-affected` exited 0: 22 packages and composed conformance 31/31 passed. The worktree is clean, so no scoped change is justified."}]],
    expected = {
      proposal_id = "github-devloop/issue/ChronoAIProject/fkst-packages/2787",
      implementation_version = "ready/github-devloop/issue/ChronoAIProject/fkst-packages/2787/intake/1722137326/reimplement/2",
      attempt = 2,
    },
    evidence_len = 360,
  },
}

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

  test_supported_refusal_receipts_preserve_exact_reason_and_non_empty_evidence = function()
    for _, reason in ipairs(refusal_reasons) do
      local evidence = "Worker-reported evidence for " .. reason .. "."
      local value, err = implementation_result.decode(receipt("cannot-implement-here", {
        '"reason":' .. strings.json_string(reason),
        '"evidence":' .. strings.json_string(evidence),
      }), expected())

      t.eq(err, nil, reason)
      t.eq(value.outcome, "cannot-implement-here", reason)
      t.eq(value.reason, reason, reason)
      t.eq(value.evidence, evidence, reason)
    end
  end,

  test_production_refusal_receipts_preserve_disposition_through_fact_round_trip = function()
    for _, fixture in ipairs(production_refusal_receipts) do
      t.is_true(#fixture.raw <= core._max_impl_output_len)
      local receipt_value, err = implementation_result.decode(fixture.raw, fixture.expected)

      t.eq(err, nil)
      t.eq(receipt_value.outcome, "cannot-implement-here")
      t.eq(#receipt_value.evidence, fixture.evidence_len)
      t.is_true(#receipt_value.evidence > core._max_blocking_gap_len)

      local ready = {
        proposal_id = fixture.expected.proposal_id,
        dedup_key = fixture.expected.implementation_version,
        source_ref = {
          kind = "external",
          ref = fixture.expected.proposal_id,
        },
      }
      local outcome = harvest.implementation_refusal_outcome(
        ready, receipt_value, fixture.expected.attempt, "100", "implement-exec/test", "base-sha")
      t.eq(outcome.kind, "implementation-refusal")
      t.eq(outcome.reason, receipt_value.reason)
      t.eq(outcome.evidence, receipt_value.evidence)

      local request = requests_lifecycle.build_implementation_refusal_comment_request(
        core, "ChronoAIProject/fkst-packages", 42, ready, outcome.reason, outcome.evidence,
        outcome.attempt, outcome.started_at, outcome.exec_ref)
      local fact = core.implementation_refusal_fact(
        { request.body }, fixture.expected.proposal_id, fixture.expected.implementation_version)
      t.is_true(fact ~= nil)
      t.eq(fact.reason, receipt_value.reason)
      t.eq(fact.evidence, receipt_value.evidence)
      t.eq(fact.attempt, fixture.expected.attempt)
    end
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
      '"reason":"Wrong-Layer"',
      '"evidence":"The requested file is in another repository."',
    }))
    decode_fails(receipt("cannot-implement-here", {
      '"evidence":"The reason field is missing."',
    }))
    decode_fails(receipt("cannot-implement-here", {
      '"reason":"already-satisfied"',
    }))
    decode_fails(receipt("cannot-implement-here", {
      '"reason":"precursor-missing"',
      '"evidence":"   "',
    }))
  end,

  test_receipt_rejects_string_attempt = function()
    decode_fails((receipt("changes-produced"):gsub('"attempt":1', '"attempt":"1"')))
  end,

  test_receipt_rejects_identity_and_attempt_mismatches = function()
    decode_fails(receipt("changes-produced"), expected({ proposal_id = proposal_id .. "/other" }))
    decode_fails(receipt("changes-produced"), expected({ implementation_version = implementation_version .. "/other" }))
    decode_fails(receipt("changes-produced"), expected({ attempt = 2 }))
  end,

  test_receipt_enforces_output_bound = function()
    decode_fails(string.rep(" ", core._max_impl_output_len + 1))
  end,
}
