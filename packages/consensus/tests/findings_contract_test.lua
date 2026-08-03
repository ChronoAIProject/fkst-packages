local core = require("consensus.core")
local synthesis_contract = require("consensus.synthesis_contract")
local t = fkst.test

local function proposal(findings_record)
  return {
    schema = "consensus.proposal.v1",
    proposal_id = "proposal-42",
    title = "Adopt consensus package",
    body = "Create a source-agnostic consensus library.",
    angles = { "teleology", "parsimony" },
    dedup_key = "proposal-42-v1",
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/42",
    },
    findings_record = findings_record,
  }
end

local function angle_results()
  return {
    { angle = "teleology", verdict = "approve", reply = "Teleology approves.", exit_code = 0 },
    { angle = "parsimony", verdict = "abstain", reply = "Parsimony needs evidence.", exit_code = 0 },
  }
end

return {
  test_is_eligible_accepts_findings_record_at_contract_limit = function()
    local findings = string.rep("x", synthesis_contract.findings_record_max_bytes)
    t.eq(core.is_eligible(proposal(findings)), true)
  end,

  test_is_eligible_rejects_overlong_findings_record = function()
    local findings = string.rep("x", synthesis_contract.findings_record_max_bytes + 1)
    t.eq(core.is_eligible(proposal(findings)), false)
  end,

  test_is_eligible_measures_multibyte_findings_in_bytes = function()
    local two_byte_character = "é"
    local findings = string.rep(two_byte_character, synthesis_contract.findings_record_max_bytes / 2)

    t.eq(#findings, synthesis_contract.findings_record_max_bytes)
    t.eq(core.is_eligible(proposal(findings)), true)
    t.eq(core.is_eligible(proposal(findings .. "x")), false)
  end,

  test_build_converge_payload_preserves_findings_record_at_contract_limit = function()
    local findings = string.rep("x", synthesis_contract.findings_record_max_bytes)
    local payload = core.build_converge_payload(
      proposal("settled:\nPrevious round memory must not be copied."),
      "Narrow the disagreement.",
      angle_results(),
      findings
    )

    t.eq(payload.findings_record, findings)
  end,

  test_build_converge_payload_measures_multibyte_findings_in_bytes = function()
    local two_byte_character = "é"
    local findings = string.rep(two_byte_character, synthesis_contract.findings_record_max_bytes / 2)
    local payload = core.build_converge_payload(
      proposal(nil),
      "Narrow the disagreement.",
      angle_results(),
      findings
    )

    t.eq(#payload.findings_record, synthesis_contract.findings_record_max_bytes)
    t.eq(payload.findings_record, findings)
  end,

  test_build_converge_payload_rejects_overlong_findings_record = function()
    local findings = string.rep("x", synthesis_contract.findings_record_max_bytes + 1)
    local ok, failure = pcall(function()
      core.build_converge_payload(
        proposal(nil),
        "Narrow the disagreement.",
        angle_results(),
        findings
      )
    end)

    t.eq(ok, false)
    t.is_true(tostring(failure):find("consensus: findings-record-invalid: findings_record is overlong", 1, true) ~= nil)
  end,
}
