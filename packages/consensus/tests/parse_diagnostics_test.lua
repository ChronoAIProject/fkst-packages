local core = require("core")
local error_facts = require("contract.error_facts")
local rebuttal = require("departments.decide.rebuttal")
local synthesis = require("departments.decide.synthesis")
local t = fkst.test

local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local stance_label = "⟦FKST:STANCE⟧"

local function angle_answer(verdict, reply)
  return verdict_label .. " " .. verdict .. "\n" .. reply_label .. " " .. reply
end

local angle_caps = {
  parse_angle_output = core.parse_angle_output,
  stance_label = stance_label,
}

return {
  test_angle_parser_returns_typed_rejection_reason_without_relaxing_grammar = function()
    local parsed, reason = core.parse_angle_output(
      verdict_label .. " approve.\n" .. reply_label .. " trailing punctuation remains invalid"
    )
    t.is_nil(parsed)
    t.eq(reason, "verdict-missing-or-invalid")

    local valid, valid_reason = core.parse_angle_output(angle_answer("approve", "The strict pair is valid."))
    t.eq(valid.verdict, "approve")
    t.is_nil(valid_reason)
  end,

  test_rebuttal_parser_identifies_stance_and_angle_rejections = function()
    local missing_stance, stance_reason = rebuttal.parse_output(
      angle_answer("approve", "No stance was emitted."),
      nil,
      angle_caps
    )
    t.is_nil(missing_stance)
    t.eq(stance_reason, "stance-missing")

    local invalid_verdict, verdict_reason = rebuttal.parse_output(
      stance_label .. " defend\n" .. angle_answer("approve.", "The verdict remains strict."),
      nil,
      angle_caps
    )
    t.is_nil(invalid_verdict)
    t.eq(verdict_reason, "verdict-missing-or-invalid")
  end,

  test_synthesis_parser_returns_content_free_reason_classes = function()
    local plan, plan_reason = synthesis.parse_output("⟦FKST:PLAN⟧ do not treat this as a decision")
    t.is_nil(plan)
    t.eq(plan_reason, "plan-sentinel")

    local unexpected, unexpected_reason = synthesis.parse_output("unrecognized synthesis prose")
    t.is_nil(unexpected)
    t.eq(unexpected_reason, "unexpected-line")

    local valid, valid_reason = synthesis.parse_output("reached:approve use the bounded framing")
    t.eq(valid.kind, "reached")
    t.is_nil(valid_reason)
  end,

  test_parse_rejection_fact_correlates_run_without_logging_stdout = function()
    local stdout = "attacker-controlled proposal content must not enter logs"
    local fact = core.parse_rejection_fact({
      identity = {
        role = "consensus",
        proposal_id = "proposal-42",
        dedup_key = "convergence:consensus:proposal-42:g0:r0:teleology",
        angle_lane = "teleology",
      },
      error_class = "angle-output-unparseable",
      phase = "blind",
      reason = "verdict-missing-or-invalid",
      stdout = stdout,
    })

    t.is_true(fact:find("tag=PARSE_REJECTION", 1, true) ~= nil)
    t.is_true(fact:find("error_class=angle-output-unparseable", 1, true) ~= nil)
    t.is_true(fact:find("phase=blind", 1, true) ~= nil)
    t.is_true(fact:find("proposal_id=proposal-42", 1, true) ~= nil)
    t.is_true(fact:find("run_key=convergence%3Aconsensus%3Aproposal-42%3Ag0%3Ar0%3Ateleology", 1, true) ~= nil)
    t.is_true(fact:find("angle_lane=teleology", 1, true) ~= nil)
    t.is_true(fact:find("parse_reason=verdict-missing-or-invalid", 1, true) ~= nil)
    t.is_true(fact:find("stdout_bytes=" .. tostring(#stdout), 1, true) ~= nil)
    t.is_true(fact:find("stdout_fingerprint=" .. error_facts.stable_hash(stdout), 1, true) ~= nil)
    t.is_nil(fact:find(stdout, 1, true))
  end,

  test_parse_rejection_fact_encodes_hostile_correlation_as_single_tokens = function()
    local fact = core.parse_rejection_fact({
      identity = {
        role = "consensus",
        proposal_id = "proposal-42",
        dedup_key = "convergence:proposal\n role=forged-run",
        angle_lane = "teleology\n role=forged-angle",
      },
      error_class = "angle-output-unparseable",
      phase = "blind",
      reason = "verdict-missing-or-invalid",
      stdout = "malformed",
    })

    t.is_nil(fact:find("\n", 1, true))
    t.is_nil(fact:find(" role=forged-run", 1, true))
    t.is_nil(fact:find(" role=forged-angle", 1, true))
    t.is_true(fact:find("run_key=convergence%3Aproposal%0A%20role%3Dforged-run", 1, true) ~= nil)
    t.is_true(fact:find("angle_lane=teleology%0A%20role%3Dforged-angle", 1, true) ~= nil)
  end,

  test_rebuttal_collection_reports_each_successful_unparseable_worker = function()
    local rejected = {}
    local results = rebuttal.collect({
      { angle = "teleology" },
    }, {
      { exit_code = 0, stdout = angle_answer("approve", "Missing stance."), stderr = "" },
    }, nil, {
      parse_angle_output = core.parse_angle_output,
      stance_label = stance_label,
      on_parse_rejected = function(angle_result, stdout, reason)
        table.insert(rejected, {
          angle = angle_result.angle,
          stdout = stdout,
          reason = reason,
        })
      end,
    })

    t.is_nil(results[1].verdict)
    t.eq(#rejected, 1)
    t.eq(rejected[1].angle, "teleology")
    t.eq(rejected[1].reason, "stance-missing")
  end,

  test_synthesis_reports_rejected_first_attempt_before_bounded_repair = function()
    local calls = 0
    local rejected = {}
    local parsed = synthesis.parse_or_retry({
      p1_results = {},
      p2_results = {},
      build_prompt = function(repair)
        return repair and "repair" or "first"
      end,
      spawn_sync = function()
        calls = calls + 1
        if calls == 1 then
          return { exit_code = 0, stdout = "malformed synthesis output", stderr = "" }
        end
        return { exit_code = 0, stdout = "reached:approve use repaired output", stderr = "" }
      end,
      on_parse_rejected = function(phase, stdout, reason)
        table.insert(rejected, { phase = phase, stdout = stdout, reason = reason })
      end,
    })

    t.eq(parsed.kind, "reached")
    t.eq(calls, 2)
    t.eq(#rejected, 1)
    t.eq(rejected[1].phase, "synthesis")
    t.eq(rejected[1].reason, "unexpected-line")
  end,

  test_synthesis_reports_both_rejected_attempts_before_fail_closed_error = function()
    local calls = 0
    local rejected = {}
    local ok, err = pcall(function()
      synthesis.parse_or_retry({
        p1_results = {},
        p2_results = {},
        build_prompt = function(repair)
          return repair and "repair" or "first"
        end,
        spawn_sync = function()
          calls = calls + 1
          return { exit_code = 0, stdout = "malformed synthesis output", stderr = "" }
        end,
        on_parse_rejected = function(phase, stdout, reason)
          table.insert(rejected, { phase = phase, stdout = stdout, reason = reason })
        end,
      })
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("consensus: synthesis-unparseable: phase=synthesis-repair", 1, true) ~= nil)
    t.eq(calls, 2)
    t.eq(#rejected, 2)
    t.eq(rejected[1].phase, "synthesis")
    t.eq(rejected[1].reason, "unexpected-line")
    t.eq(rejected[2].phase, "synthesis-repair")
    t.eq(rejected[2].reason, "unexpected-line")
  end,
}
