local t = fkst.test
local reach_test_helper = require("tests.reach_test_helpers")
local codex_jsonl = require("testkit_internal.codex_jsonl")

local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local default_seats = {
  "teleology",
  "parsimony",
  "fidelity",
  "natural-ownership",
  "proportional-containment",
}

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/consensus-locus-dyad/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function opts(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = runtime_root(name),
    },
  }
end

local function default_proposal()
  return {
    schema = "consensus.proposal.v1",
    proposal_id = "locus-dyad-default-proposal",
    title = "Exercise the default consensus core",
    body = "Drive a default proposal through the decision department.",
    context = "The test must prove every default seat is invoked by the end-to-end path.",
    dedup_key = "locus-dyad-default-proposal-v1",
    source_ref = {
      kind = "proposal",
      ref = "demo/consensus/locus-dyad",
    },
  }
end

local function run_decide(event_payload, run_opts)
  return reach_test_helper.run(event_payload, run_opts)
end

local function mock_judgment_runtime()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus-locus-dyad/runtime",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_judgment_dir()
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_angle(angle)
  mock_judgment_dir()
  t.mock_command("consensus-angle-" .. tostring(angle), {
    stdout = codex_jsonl.final_message(
      verdict_label .. " approve\n" .. reply_label .. " " .. tostring(angle) .. " approves.\n"),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_default_seats()
  mock_judgment_runtime()
  for _, seat in ipairs(default_seats) do
    mock_angle(seat)
  end
end

local codex_calls = require("testkit_internal.command_calls").codex_calls

local function judgment_call(seat)
  local needle = "/judgment-worktrees/consensus-angle-" .. tostring(seat)
  for _, call in ipairs(codex_calls()) do
    if call.rendered:find(needle, 1, true) ~= nil then
      return call
    end
  end
  return nil
end

local function raised_result_for_seat(result, seat)
  for _, item in ipairs(result.raises[1].payload.angle_results or {}) do
    if item.angle == seat then
      return item
    end
  end
  return nil
end

return {
  test_default_consensus_decision_spawns_locus_dyad_with_core_seats = function()
    mock_default_seats()
    local proposal = default_proposal()
    t.eq(proposal.angles, nil)

    local result = run_decide(proposal, opts("default-five-seat-approval"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.eq(result.raises[1].payload.decision, "approve")
    t.eq(#result.raises[1].payload.angle_results, #default_seats)
    t.eq(#codex_calls(), #default_seats)

    for _, seat in ipairs(default_seats) do
      local call = judgment_call(seat)
      t.is_true(call ~= nil)
      t.is_true(call.stdin:find("Angle: " .. seat, 1, true) ~= nil)
      local item = raised_result_for_seat(result, seat)
      t.is_true(item ~= nil)
      t.eq(item.verdict, "approve")
    end
  end,
}
