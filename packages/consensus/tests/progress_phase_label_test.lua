local consensus = require("consensus")
local codex_jsonl = require("testkit_internal.codex_jsonl")
local workflow_codex = require("workflow_internal.codex")
local t = fkst.test

local function mock_codex(pattern, output)
  t.mock_command(pattern, {
    stdout = codex_jsonl.final_message(output),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_consensus_run()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/consensus-progress-label/runtime",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 6 do
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  mock_codex("consensus-angle-teleology", table.concat({
    "⟦FKST:VERDICT⟧ approve",
    "⟦FKST:REPLY⟧ Teleology approves.",
    "",
  }, "\n"))
  mock_codex("consensus-angle-parsimony", table.concat({
    "⟦FKST:VERDICT⟧ abstain",
    "⟦FKST:REPLY⟧ Parsimony needs evidence.",
    "",
  }, "\n"))
  mock_codex("consensus-rebuttal-teleology", table.concat({
    "⟦FKST:STANCE⟧ defend",
    "⟦FKST:VERDICT⟧ approve",
    "⟦FKST:REPLY⟧ Teleology still approves.",
    "",
  }, "\n"))
  mock_codex("consensus-rebuttal-parsimony", table.concat({
    "⟦FKST:STANCE⟧ defend",
    "⟦FKST:VERDICT⟧ abstain",
    "⟦FKST:REPLY⟧ Parsimony still needs evidence.",
    "",
  }, "\n"))
  mock_codex("consensus-synthesis-consensus-progress-phase-label-v1", "invalid synthesis\n")
  mock_codex("consensus-synthesis-repair-consensus-progress-phase-label-v1", table.concat({
    "converge: evidence remains unresolved + inspect the source record",
    "open: evidence remains unresolved",
    "",
  }, "\n"))
end

return {
  test_sequential_consensus_phases_receive_distinct_shared_labels = function()
    mock_consensus_run()
    local labels = {}
    local requested_phases = {}
    local original_dispatch = workflow_codex.dispatch
    workflow_codex.dispatch = function(identity, opts)
      labels[identity.angle_lane] = opts.label
      return original_dispatch(identity, opts)
    end

    local ok, result = pcall(function()
      return consensus.reach({
        schema = "consensus.proposal.v1",
        title = "Keep progress visible across consensus phases",
        body = "Each sequential phase needs its own progress cohort.",
        content_fetch = "fetch-source --ref demo/consensus-progress/42 --full",
        angles = { "teleology", "parsimony" },
        dedup_key = "consensus-progress-phase-label-v1",
        source_ref = { kind = "proposal", ref = "demo/consensus-progress/42" },
      }, {
        invocation_id = "consensus-progress-phase-label-v1",
        new_run_label = function(phase)
          table.insert(requested_phases, phase)
          return "progress-label-" .. phase
        end,
      })
    end)
    workflow_codex.dispatch = original_dispatch
    if not ok then
      error(result)
    end

    t.eq(result.status, "converge")
    t.eq(table.concat(requested_phases, ","), "blind,rebuttal,synthesis,synthesis-repair")
    t.eq(labels.teleology, "progress-label-blind")
    t.eq(labels.parsimony, "progress-label-blind")
    t.eq(labels["rebuttal-teleology"], "progress-label-rebuttal")
    t.eq(labels["rebuttal-parsimony"], "progress-label-rebuttal")
    t.eq(labels.synthesis, "progress-label-synthesis")
    t.eq(labels["synthesis-repair"], "progress-label-synthesis-repair")
  end,
}
