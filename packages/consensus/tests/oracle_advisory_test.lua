local testing = require("testkit.testing")
local t = fkst.test

local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local stance_label = "⟦FKST:STANCE⟧"

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/consensus/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function opts(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = runtime_root(name),
    },
  }
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

local function decide_module_with_restored_pipeline()
  local old_pipeline = pipeline
  local module = require("departments.decide.main")
  pipeline = old_pipeline
  return module
end

local function fake_decide_department(ports)
  return decide_module_with_restored_pipeline().make_department(ports or {})
end

local function run_fake_decide(dept, event_payload)
  return testing.run_fake(dept, {
    queue = "proposal",
    payload = event_payload,
  })
end

local function codex_calls()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      table.insert(calls, call)
    end
  end
  return calls
end

local function mock_judgment_runtime()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus/runtime",
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

local function mock_angle(angle, verdict, reply)
  mock_judgment_dir()
  t.mock_command("consensus-angle-" .. tostring(angle), {
    stdout = verdict_label .. " " .. verdict .. "\n" .. reply_label .. " " .. reply .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_rebuttal(angle, stance, verdict, reply, peer_claim)
  mock_judgment_dir()
  local stance_line = stance_label .. " " .. tostring(stance)
  if stance == "update" and peer_claim ~= nil then
    stance_line = stance_line .. " because " .. tostring(peer_claim)
  end
  t.mock_command("consensus-rebuttal-" .. tostring(angle), {
    stdout = stance_line .. "\n" .. verdict_label .. " " .. verdict .. "\n" .. reply_label .. " " .. reply .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_rebuttal_defend(angle, verdict, reply)
  mock_rebuttal(angle, "defend", verdict, reply)
end

local function synthesis_stdout(line)
  local text = tostring(line or "")
  if text:find("converge:", 1, true) == 1 and text:find("\nopen:", 1, true) == nil then
    text = text .. "\nopen: unresolved synthesis disagreement"
  end
  return text .. "\n"
end

local function mock_synthesis(line)
  mock_judgment_dir()
  t.mock_command("consensus-synthesis-proposal", {
    stdout = synthesis_stdout(line),
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_phase_r_absent_oracle_is_advisory_and_carried_into_converge_payload = function()
    local oracle_calls = {}
    mock_judgment_runtime()
    mock_angle("teleology", "approve", "Teleology angle approves.")
    mock_angle("parsimony", "abstain", "Parsimony angle needs one blocker resolved.")
    mock_angle("fidelity", "approve", "Fidelity angle approves.")
    mock_rebuttal_defend("teleology", "approve", "Teleology still approves.")
    mock_rebuttal_defend("parsimony", "abstain", "Parsimony still needs one blocker resolved.")
    mock_rebuttal_defend("fidelity", "approve", "Fidelity still approves.")
    mock_synthesis("converge: parsimony concern remains unresolved + inspect the retry-boundary evidence")

    local dept = fake_decide_department({
      consult_oracle = function(request)
        table.insert(oracle_calls, request)
        return nil
      end,
    })
    local result = run_fake_decide(dept, proposal({
      dedup_key = "proposal-42-v1/split-oracle-absent",
    }))

    t.eq(#oracle_calls, 1)
    t.eq(oracle_calls[1].schema, "consensus.oracle_advisory_request.v1")
    t.eq(oracle_calls[1].phase, "R")
    t.eq(oracle_calls[1].proposal.proposal_id, "proposal-42")
    t.eq(#oracle_calls[1].p1_results, 3)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_converge")
    t.eq(result.raises[1].payload.narrowed_question, "parsimony concern remains unresolved + inspect the retry-boundary evidence")
    t.eq(result.raises[1].payload.oracle_consulted, false)
    t.eq(result.raises[1].payload.oracle_addressed, 0)
    t.eq(#codex_calls(), 7)
  end,

  test_phase_r_absent_oracle_is_carried_into_post_rebuttal_reached_payload = function()
    local oracle_calls = 0
    mock_judgment_runtime()
    mock_angle("teleology", "approve", "Teleology approves because the purpose forces it.")
    mock_angle("parsimony", "abstain", "Parsimony needs the retry boundary named.")
    mock_angle("fidelity", "approve", "Fidelity approves because source_ref is direct.")
    mock_rebuttal_defend("teleology", "approve", "Teleology still approves.")
    mock_rebuttal("parsimony", "update", "approve", "Parsimony now approves after teleology named the purpose.", "teleology purpose claim")
    mock_rebuttal_defend("fidelity", "approve", "Fidelity still approves.")

    local dept = fake_decide_department({
      consult_oracle = function()
        oracle_calls = oracle_calls + 1
        error("oracle unavailable", 0)
      end,
    })
    local result = run_fake_decide(dept, proposal({
      dedup_key = "proposal-42-v1/rebuttal-oracle-absent",
    }))

    t.eq(oracle_calls, 1)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.eq(result.raises[1].payload.decision, "approve")
    t.eq(result.raises[1].payload.verdict_path, "post-rebuttal-unanimity")
    t.eq(result.raises[1].payload.oracle_consulted, false)
    t.eq(result.raises[1].payload.oracle_addressed, 0)
    t.eq(#codex_calls(), 6)
  end,

  test_blind_unanimity_fast_path_does_not_consult_oracle = function()
    local oracle_calls = 0
    mock_judgment_runtime()
    mock_angle("teleology", "approve", "Teleology angle approves.")
    mock_angle("parsimony", "approve", "Parsimony angle approves.")
    mock_angle("fidelity", "approve", "Fidelity angle approves.")

    local dept = fake_decide_department({
      consult_oracle = function()
        oracle_calls = oracle_calls + 1
        return nil
      end,
    })
    local result = run_fake_decide(dept, proposal({
      dedup_key = "proposal-42-v1/blind-unanimity-no-oracle",
    }))

    t.eq(oracle_calls, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "consensus_reached")
    t.is_nil(result.raises[1].payload.oracle_consulted)
    t.is_nil(result.raises[1].payload.oracle_addressed)
    t.eq(#codex_calls(), 3)
  end,
}
