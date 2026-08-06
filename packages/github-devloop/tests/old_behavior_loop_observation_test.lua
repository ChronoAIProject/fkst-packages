local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local SITE_PATH = "packages/github-devloop/departments/loop/main.lua"
local OBSERVATION_PREFIX = "writer:github-devloop:loop-thinking-blocked/"
local BASE_VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local QUESTION = "Which source-verifiable fact resolves the remaining gap?"
local ANGLES = {
  { angle = "minimal", verdict = "abstain", digest = "same-evidence-gap" },
}

local CONTINUATION_OBSERVATION_IDS = {
  OBSERVATION_PREFIX
    .. "current-terminal-continuation-budget/blocked/apply/current-terminal-continuation-budget/none",
  OBSERVATION_PREFIX
    .. "lineage-terminal-continuation-budget/blocked/apply/lineage-terminal-continuation-budget/none",
}

local function round_marker(event, round, extra)
  extra = extra or {}
  return conv_rounds.converge_round_marker(
    event.proposal_id,
    BASE_VERSION,
    convergence_shared.source_ref_digest(event.source_ref),
    round,
    extra.dedup_key or (round == 0 and BASE_VERSION or BASE_VERSION .. "/loop/" .. tostring(round)),
    extra.narrowed_question or QUESTION,
    extra.angle_digests or ANGLES,
    extra.findings_record,
    extra.essence_stall == true
  )
end

local function protected_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local records = {}
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local site = type(record) == "table" and record.site or nil
    if type(site) == "table"
      and site.path == SITE_PATH
      and type(record.observation_id) == "string"
      and record.observation_id:sub(1, #OBSERVATION_PREFIX) == OBSERVATION_PREFIX then
      records[#records + 1] = record
    end
  end
  return records
end

local function find_record(records, observation_id)
  for _, record in ipairs(records) do
    if record.observation_id == observation_id then
      return record
    end
  end
  return nil
end

local REDRIVE_FIXTURES = {
  {
    name = "current-continuation-budget",
    event = function()
      return h.unresolved({
        dedup_key = BASE_VERSION .. "/loop/1",
        round = 1,
        narrowed_question = QUESTION,
        angle_digests = ANGLES,
        findings_record = "open:\nsecond resolvable finding",
      })
    end,
    comments = function(event)
      return {
        core.state_marker(event.proposal_id, "thinking", BASE_VERSION),
        round_marker(event, 0, { findings_record = "open:\nfirst resolvable finding" }),
      }
    end,
    next_round = 2,
  },
  {
    name = "lineage-continuation-budget",
    event = function()
      return h.unresolved({
        dedup_key = BASE_VERSION .. "/loop/2",
        round = 2,
        narrowed_question = QUESTION,
        angle_digests = ANGLES,
      })
    end,
    comments = function(event)
      return {
        core.state_marker(event.proposal_id, "thinking", BASE_VERSION),
        round_marker(event, 1, { findings_record = "open:\nsecond resolvable finding" }),
      }
    end,
    next_round = 3,
  },
}

return {
  test_loop_baseline_is_pinned_by_the_protected_observation_artifact = function()
    local records = protected_records()
    t.eq(#records, 11, "complete protected loop baseline")
    for _, record in ipairs(records) do
      t.eq(record.schema, "restart-old-behavior-observation.v2")
      t.eq(record.owner, "github-devloop")
      t.eq(record.boundary, "writer")
      t.eq(type(record.old_inputs), "table")
      t.eq(type(record.old_outcome), "table")
    end

    for _, observation_id in ipairs(CONTINUATION_OBSERVATION_IDS) do
      local record = find_record(records, observation_id)
      t.is_true(record ~= nil, observation_id .. ": protected continuation baseline")
      local effects = record.old_outcome.emitted_effects
      t.eq(#effects, 2, observation_id .. ": proposal and convergence comment")
      t.eq(effects[1].effect_id, "queue:consensus.proposal")
      t.eq(effects[2].effect_id, "comment:issue:converge-round")
    end
  end,

  test_loop_continuation_budget_baselines_redrive_without_terminal_handoff = function()
    for _, fixture in ipairs(REDRIVE_FIXTURES) do
      local event = fixture.event()
      h.mock_issue_loop({ "fkst-dev:thinking" }, fixture.comments(event))

      local result = h.run_loop(event, h.opts("old-behavior-loop-" .. fixture.name))
      t.eq(result.exit_code, 0, fixture.name .. ": production run")
      t.eq(#result.raises, 2, fixture.name .. ": exactly continuation result and convergence comment")

      local proposal = h.take_consensus_proposal()
      t.is_true(proposal ~= nil, fixture.name .. ": next consensus proposal")
      t.eq(proposal.round, fixture.next_round, fixture.name .. ": next round")
      t.eq(
        proposal.dedup_key,
        "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/" .. tostring(fixture.next_round),
        fixture.name .. ": next-round dedup"
      )
      t.is_true(
        h.find_raise(result.raises, "devloop_consensus_request") ~= nil,
        fixture.name .. ": renamed consensus proposal request"
      )

      local comment = h.find_raise(result.raises, "github-proxy.github_issue_comment_request")
      t.is_true(comment ~= nil, fixture.name .. ": convergence comment")
      t.is_nil(comment.payload.handoff, fixture.name .. ": no terminal reconcile handoff")
      t.eq(h.find_raise(result.raises, "devloop_reconcile"), nil, fixture.name .. ": no terminal event")
    end
  end,
}
