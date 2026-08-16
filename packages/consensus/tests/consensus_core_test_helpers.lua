local core = require("consensus.core")
local synthesis = require("consensus.synthesis")
local t = fkst.test
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local gap_label = "⟦FKST:GAP⟧"
local stance_label = "⟦FKST:STANCE⟧"
local history_directive = "Before judging, use the producer-provided context manifest below as the complete prior history of this proposal"
local prompt_preamble_language_en = "Write all output in English; quote code identifiers and cited originals verbatim."
local prompt_preamble_language_zh = "Write all prose output in Simplified Chinese; quote code identifiers and cited originals verbatim."
local prompt_preamble_judgment_harness = "Before judging, identify the established theory or industry best practice governing this problem class; treat unjustified deviation from established practice as grounds for rejection or narrowing; require proof that existing practice does not apply before accepting novelty."
local prompt_preamble_history = "Before judging, use the producer-provided context manifest below as the complete prior history of this proposal; earlier rounds recorded there are your memory. Judge what changed; do not re-litigate settled points."

local function answer(verdict, reply)
  return verdict_label .. " " .. verdict .. "\n" .. reply_label .. " " .. reply
end

local function reject_answer(reply, gap)
  return answer("reject", reply) .. "\n" .. gap_label .. " " .. gap
end

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    proposal_id = "proposal-42",
    title = "Adopt consensus package",
    body = "Create a small flat package that asks several angles to judge a proposal.",
    content_fetch = "fetch-source --ref demo/consensus/42 --full",
    context = "The package must stay silent unless all angles agree.",
    angles = { "teleology", "parsimony", "fidelity" },
    dedup_key = "proposal-42-v1",
    -- Source-agnostic sample: an opaque {kind, ref} pointer, not tied to any provider.
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/42",
    },
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function proposal_without_content_fetch(extra)
  local value = proposal(extra)
  value.content_fetch = nil
  return value
end

local function result(angle, verdict)
  return {
    angle = angle,
    verdict = verdict,
    reply = angle .. " reply",
    exit_code = 0,
  }
end

local function assert_common_preamble_slots(prompt)
  t.is_true(prompt:find("Write all output in English; quote code identifiers and cited originals verbatim.", 1, true) ~= nil)
  t.is_true(prompt:find("Before judging, identify the established theory or industry best practice governing this problem class", 1, true) ~= nil)
  t.is_nil(prompt:find("gh issue view", 1, true))
  t.is_nil(prompt:find("gh pr view", 1, true))
end

local function assert_history_directive(prompt)
  t.is_true(prompt:find(history_directive, 1, true) ~= nil)
end

local function assert_no_history_directive(prompt)
  t.is_nil(prompt:find(history_directive, 1, true))
end

local function with_real_consensus_catalog(fn)
  local original_t = _G.t
  local catalog = require("consensus.locale")
  _G.t = function(key)
    local value = catalog[key]
    if value == nil then
      error("missing real catalog key: " .. tostring(key))
    end
    return value
  end

  local ok, err = pcall(fn)
  _G.t = original_t
  if not ok then
    error(err, 0)
  end
end

local function expected_prompt(language_line, include_history)
  local lines = {
    language_line,
    prompt_preamble_judgment_harness,
  }
  if include_history then
    table.insert(lines, prompt_preamble_history)
  end
  return table.concat(lines, "\n")
end

return {
  core = core,
  synthesis = synthesis,
  t = t,
  verdict_label = verdict_label,
  reply_label = reply_label,
  gap_label = gap_label,
  stance_label = stance_label,
  history_directive = history_directive,
  prompt_preamble_language_en = prompt_preamble_language_en,
  prompt_preamble_language_zh = prompt_preamble_language_zh,
  prompt_preamble_judgment_harness = prompt_preamble_judgment_harness,
  prompt_preamble_history = prompt_preamble_history,
  answer = answer,
  reject_answer = reject_answer,
  proposal = proposal,
  proposal_without_content_fetch = proposal_without_content_fetch,
  result = result,
  assert_common_preamble_slots = assert_common_preamble_slots,
  assert_history_directive = assert_history_directive,
  assert_no_history_directive = assert_no_history_directive,
  with_real_consensus_catalog = with_real_consensus_catalog,
  expected_prompt = expected_prompt,
}
