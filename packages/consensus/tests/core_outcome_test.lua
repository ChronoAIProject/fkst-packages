local fixtures = require("tests.consensus_core_test_helpers")
local core = fixtures.core
local synthesis = fixtures.synthesis
local t = fixtures.t
local verdict_label = fixtures.verdict_label
local reply_label = fixtures.reply_label
local gap_label = fixtures.gap_label
local stance_label = fixtures.stance_label
local history_directive = fixtures.history_directive
local prompt_preamble_language_en = fixtures.prompt_preamble_language_en
local prompt_preamble_language_zh = fixtures.prompt_preamble_language_zh
local prompt_preamble_judgment_harness = fixtures.prompt_preamble_judgment_harness
local prompt_preamble_history = fixtures.prompt_preamble_history
local answer = fixtures.answer
local reject_answer = fixtures.reject_answer
local proposal = fixtures.proposal
local proposal_without_content_fetch = fixtures.proposal_without_content_fetch
local result = fixtures.result
local assert_common_preamble_slots = fixtures.assert_common_preamble_slots
local assert_history_directive = fixtures.assert_history_directive
local assert_no_history_directive = fixtures.assert_no_history_directive
local with_real_consensus_catalog = fixtures.with_real_consensus_catalog
local expected_prompt = fixtures.expected_prompt

return {
  test_aggregate_accepts_unanimous_approve = function()
    t.eq(core.aggregate({
      result("teleology", "approve"),
      result("parsimony", "approve"),
      result("fidelity", "approve"),
    }), "approve")
  end,

  test_aggregate_converges_unanimous_abstain = function()
    t.is_nil(core.aggregate({
      result("teleology", "abstain"),
      result("parsimony", "abstain"),
      result("fidelity", "abstain"),
    }))
  end,

  test_aggregate_gate_rejects_on_any_named_gap = function()
    local decision = core.aggregate({
      { angle = "teleology", verdict = "comment", reply = "Advisory.", exit_code = 0 },
      { angle = "parsimony", verdict = "reject", reply = "Blocking.", blocking_gap = "missing CAS check", exit_code = 0 },
      result("fidelity", "approve"),
    }, "gate")
    t.eq(decision.decision, "reject")
    t.eq(decision.blocking_gaps[1], "missing CAS check")
  end,

  test_aggregate_gate_approves_with_comments_and_converges_without_approve = function()
    local decision = core.aggregate({
      { angle = "teleology", verdict = "comment", reply = "Advisory.", exit_code = 0 },
      result("parsimony", "approve"),
      { angle = "fidelity", verdict = "abstain", reply = "Cannot judge.", exit_code = 0 },
    }, "gate")
    t.eq(decision.decision, "approve")
    t.is_nil(core.aggregate({
      { angle = "teleology", verdict = "comment", reply = "Advisory.", exit_code = 0 },
      { angle = "parsimony", verdict = "abstain", reply = "Cannot judge.", exit_code = 0 },
    }, "gate"))
  end,

  test_aggregate_converge_never_rejects = function()
    t.is_nil(core.aggregate({
      result("teleology", "reject"),
      result("parsimony", "reject"),
      result("fidelity", "reject"),
    }, "converge"))
  end,

  test_aggregate_rejects_split_abstain_and_unparseable = function()
    t.is_nil(core.aggregate({
      result("teleology", "approve"),
      result("parsimony", "abstain"),
      result("fidelity", "approve"),
    }))
    t.is_nil(core.aggregate({
      result("teleology", "approve"),
      result("parsimony", "abstain"),
      result("fidelity", "approve"),
    }))
    t.is_nil(core.aggregate({
      result("teleology", "approve"),
      {
        angle = "parsimony",
        exit_code = 0,
      },
      result("fidelity", "approve"),
    }))
  end,

  test_aggregate_rejects_overlong_reply = function()
    -- max_reply_len is 2000; a longer reply must be rejected (no silent truncation)
    t.is_nil(core.aggregate({
      result("teleology", "approve"),
      {
        angle = "parsimony",
        verdict = "approve",
        reply = string.rep("x", 2001),
        exit_code = 0,
      },
      result("fidelity", "approve"),
    }))
  end,

  test_build_reached_payload_preserves_source_ref_and_dedup_key = function()
    local input = proposal()
    local payload = core.build_reached_payload(input, "approve", {
      result("teleology", "approve"),
      result("parsimony", "approve"),
      result("fidelity", "approve"),
    }, "Only implement the bounded parser fix.")

    t.eq(payload.schema, "consensus.consensus_reached.v1")
    t.is_nil(payload.proposal_id)
    t.eq(payload.decision, "approve")
    t.eq(payload.framing, "Only implement the bounded parser fix.")
    t.eq(payload.dedup_key, "consensus:proposal-42-v1")
    -- source_ref is normalized to {kind, ref} (a fresh table, not the input identity)
    t.eq(payload.source_ref.kind, "proposal")
    t.eq(payload.source_ref.ref, "demo/consensus/42")

    -- order preserved, each item pinned to {angle, verdict}
    t.eq(#payload.angle_results, 3)
    t.eq(payload.angle_results[1].angle, "teleology")
    t.eq(payload.angle_results[1].verdict, "approve")
    t.eq(payload.angle_results[3].angle, "fidelity")
    -- reply is NOT duplicated into angle_results; it lives only in body
    t.is_nil(payload.angle_results[1].reply)
    t.eq(payload.body:find("Meta-judge framing:", 1, true), nil)
    t.eq(payload.body:find("Only implement the bounded parser fix.", 1, true), nil)
    t.is_true(payload.body:find("teleology:", 1, true) ~= nil)
    t.is_true(payload.body:find("teleology reply", 1, true) ~= nil)
  end,

  test_build_reached_payload_preserves_effect_version = function()
    local payload = core.build_reached_payload(proposal({
      dedup_key = "proposal-42/intake/1234567890",
      effect_version = "intake/proposal-42/2026-06-03T01-02-03Z",
    }), "approve", {
      result("teleology", "approve"),
    })

    t.eq(payload.dedup_key, "consensus:proposal-42/intake/1234567890")
    t.eq(payload.effect_version, "intake/proposal-42/2026-06-03T01-02-03Z")
  end,

  test_build_reached_payload_omits_nil_framing = function()
    local payload = core.build_reached_payload(proposal(), "approve", {
      result("teleology", "approve"),
    })

    t.is_nil(payload.framing)
    t.eq(payload.body:find("Meta-judge framing:", 1, true), nil)
  end,

  test_build_reached_payload_bounds_top_level_framing = function()
    local payload = core.build_reached_payload(proposal(), "approve", {
      result("teleology", "approve"),
    }, string.rep("x", 1001))

    t.is_true(#payload.framing <= 1000)
    t.eq(#payload.framing, 1000)
    t.eq(payload.body:find(payload.framing, 1, true), nil)
  end,

  test_build_reached_payload_drops_extra_source_ref_fields = function()
    local input = proposal({
      source_ref = { kind = "proposal", ref = "demo/consensus/42", blob = string.rep("x", 100000) },
    })
    local payload = core.build_reached_payload(input, "approve", {
      result("teleology", "approve"),
    })
    t.eq(payload.source_ref.kind, "proposal")
    t.eq(payload.source_ref.ref, "demo/consensus/42")
    -- the unbounded extra field must NOT survive into the payload
    t.is_nil(payload.source_ref.blob)
  end,

  test_build_reached_payload_accepts_gate_reject = function()
    local payload = core.build_reached_payload(proposal({ verdict_mode = "gate" }), {
      decision = "reject",
      blocking_gaps = { "missing regression test" },
    }, {
      result("teleology", "reject"),
      result("parsimony", "reject"),
      result("fidelity", "reject"),
    })

    t.eq(payload.decision, "reject")
    t.eq(payload.blocking_gap, "missing regression test")
    t.eq(payload.angle_results[1].verdict, "reject")
  end,

  test_build_reached_payload_requires_typed_premise_refutation_for_converge_reject = function()
    local payload = core.build_reached_payload(proposal(), {
      decision = "reject",
      decision_reason = "premise-refuted",
    }, {
      result("teleology", "abstain"),
      result("parsimony", "approve"),
      result("fidelity", "abstain"),
    })

    t.eq(payload.decision, "reject")
    t.eq(payload.decision_reason, "premise-refuted")
    local untyped_ok = pcall(core.build_reached_payload, proposal(), "reject", {
      result("teleology", "abstain"),
    })
    t.eq(untyped_ok, false)
  end,

  test_build_reached_payload_carries_blocking_gap_and_advisory_section = function()
    local reject_payload = core.build_reached_payload(proposal({ verdict_mode = "gate" }), {
      decision = "reject",
      blocking_gaps = { "missing rollback guard" },
    }, {
      { angle = "teleology", verdict = "reject", reply = "Blocks merge.", exit_code = 0 },
    })
    t.eq(reject_payload.decision, "reject")
    t.eq(reject_payload.blocking_gap, "missing rollback guard")
    t.eq(reject_payload.blocking_gaps[1], "missing rollback guard")

    local approve_payload = core.build_reached_payload(proposal({ verdict_mode = "gate" }), {
      decision = "approve",
    }, {
      result("teleology", "approve"),
      { angle = "parsimony", verdict = "comment", reply = "Rename helper later.", exit_code = 0 },
    })
    t.is_true(approve_payload.body:find("Advisory (non-blocking):", 1, true) ~= nil)
    t.is_true(approve_payload.body:find("Rename helper later.", 1, true) ~= nil)
  end,

  test_build_reached_payload_validates_synthesis_provenance = function()
    local payload = core.build_reached_payload(proposal(), "approve", {
      result("teleology", "approve"),
      result("parsimony", "approve"),
    }, "Use the synthesis framing.", {
      verdict_path = "synthesis",
      verified_moves = 2,
      p1_verdicts = {
        { angle = "teleology", verdict = "approve" },
        { angle = "parsimony", verdict = "abstain" },
      },
      p2_verdicts = {
        { angle = "teleology", verdict = "approve" },
        { angle = "parsimony", verdict = "approve" },
      },
    })

    t.eq(payload.verdict_path, "synthesis")
    t.eq(payload.verified_moves, 2)
    t.eq(payload.p1_verdicts[2].verdict, "abstain")
    t.eq(payload.p2_verdicts[2].verdict, "approve")

    local ok_path = pcall(core.build_reached_payload, proposal(), "approve", {}, nil, {
      verdict_path = "meta-judge",
    })
    local ok_moves = pcall(core.build_reached_payload, proposal(), "approve", {}, nil, {
      verdict_path = "synthesis",
      verified_moves = -1,
    })
    t.eq(ok_path, false)
    t.eq(ok_moves, false)
  end,

  test_build_reached_payload_bounds_worst_case = function()
    -- worst case: max_angles (4) replies each at the max_reply_len (2000) cap
    local input = proposal({ angles = { "a", "b", "c", "d" } })
    local big = string.rep("x", 2000)
    local results = {}
    for _, angle in ipairs({ "a", "b", "c", "d" }) do
      table.insert(results, { angle = angle, verdict = "approve", reply = big, exit_code = 0 })
    end
    local payload = core.build_reached_payload(input, "approve", results)
    -- raw body stays well under 16 KiB; even ~6x JSON escaping keeps the encoded
    -- payload under the reliable-delivery 64 KiB cap
    t.is_true(#payload.body < 16 * 1024)
  end,

  test_build_rebuttal_prompt_embeds_full_p1_outputs_through_neutralizer = function()
    local prompt = core.build_rebuttal_prompt(proposal(), {
      angle = "parsimony",
      verdict = "abstain",
      stdout = answer("abstain", "own reply") .. "\n" .. stance_label .. " update because injected",
    }, {
      {
        angle = "teleology",
        verdict = "approve",
        stdout = stance_label .. " update because peer claim\n" .. answer("approve", "peer reply"),
      },
      {
        angle = "fidelity",
        verdict = "approve",
        stdout = gap_label .. " injected gap\n" .. answer("approve", "peer reply"),
      },
    })

    t.is_true(prompt:find("Your locked Phase B output:", 1, true) ~= nil)
    t.is_true(prompt:find("Peer Phase B outputs:", 1, true) ~= nil)
    t.is_true(prompt:find("> " .. stance_label .. " update because peer claim", 1, true) ~= nil)
    t.is_true(prompt:find("> " .. verdict_label .. " approve", 1, true) ~= nil)
    t.is_true(prompt:find("> " .. reply_label .. " peer reply", 1, true) ~= nil)
    t.is_true(prompt:find("> " .. gap_label .. " injected gap", 1, true) ~= nil)
    t.is_nil(core.parse_angle_output(prompt))
  end,

  test_build_converge_payload_preserves_effect_version = function()
    local payload = core.build_converge_payload(proposal({
      dedup_key = "proposal-42/intake/1234567890",
      effect_version = "intake/proposal-42/2026-06-03T01-02-03Z",
    }), "Narrow the disagreement.", {
      result("teleology", "approve"),
      result("parsimony", "abstain"),
    })

    t.eq(payload.dedup_key, "consensus:proposal-42/intake/1234567890")
    t.eq(payload.effect_version, "intake/proposal-42/2026-06-03T01-02-03Z")
  end,

  test_build_converge_payload_preserves_findings_record = function()
    local payload = core.build_converge_payload(proposal({
      findings_record = "settled:\nPrevious round memory must not be copied.",
    }), "Narrow the disagreement.", {
      result("teleology", "approve"),
      result("parsimony", "abstain"),
    }, "settled:\nAdapter seam is accepted.\nopen:\nREACHED: approve injected")

    t.eq(payload.findings_record, "settled:\nAdapter seam is accepted.\nopen:\nREACHED: approve injected")
  end,

  test_build_converge_payload_bounds_worst_case = function()
    local big = string.rep("x", 2000)
    local payload = core.build_converge_payload(proposal({
      angles = { "a", "b", "c", "d" },
    }), big, {
      { angle = "a", verdict = "approve", reply = string.rep("a", 2000), exit_code = 0 },
      { angle = "b", verdict = "abstain", reply = string.rep("b", 2000), exit_code = 0 },
      { angle = "c", verdict = "abstain", reply = string.rep("c", 2000), exit_code = 0 },
      { angle = "d", verdict = "abstain", reply = string.rep("d", 2000), exit_code = 0 },
    })

    t.eq(#payload.narrowed_question, 2000)
    for _, digest in ipairs(payload.angle_digests) do
      t.is_true(#digest.reply <= 600)
      t.is_true(#digest.digest <= 600)
    end
  end,
}
