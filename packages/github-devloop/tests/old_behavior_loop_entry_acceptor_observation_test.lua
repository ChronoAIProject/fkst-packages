local ra = require("tests.entry_acceptor_observation_helpers")
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local core = require("core")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local github_author_policy = require("devloop.github_author_policy")
local github_fake = require("forge.github_fake")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local _workflow_codex = require("workflow_internal.codex")
local loop_department = require("departments.loop.main")

local t = h.t
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local QUESTION = "Which source-verifiable fact resolves the remaining gap?"
local ANGLES = { { angle = "minimal", verdict = "abstain", digest = "same-evidence-gap" } }
local PREFIX = "entry-loop-"
local SITE = {
  path = "packages/github-devloop/departments/loop/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:consensus.consensus_converge",
}
local COMMENT = "comment:issue:converge-round"
local PROPOSAL = "queue:consensus.proposal"

local FIXTURES = ra.json_array({
  { disposition = "skip-foreign-payload", status = "rejected", reason = "unsupported-event-payload",
    cas = "skip-foreign(proposal_id)", target = "reject", source_line = 48,
    payload = { schema = "unsupported.converge.v1", proposal_id = PROPOSAL_ID, dedup_key = VERSION } },
  { disposition = "skip-non-whitelisted-author", status = "rejected", reason = "non-whitelisted-author",
    cas = "skip-non-whitelisted-author", target = "reject", source_line = 78, author_login = "ordinary-user",
    current_state = "thinking", current_version = VERSION },
  { disposition = "skip-idempotent-already-blocked", status = "rejected", reason = "already-at-target",
    cas = "skip-idempotent(already at to_state)", target = "reject", source_line = 83,
    current_state = "blocked", current_version = VERSION },
  { disposition = "skip-state-advanced", status = "rejected", reason = "advanced-or-diverged",
    cas = "skip-advanced-or-diverged", target = "reject", source_line = 83,
    current_state = "ready", current_version = VERSION },
  { disposition = "retry-thinking-marker-pending", status = "error", reason = "thinking-marker-pending",
    cas = "retry-pending(from-state marker not yet visible)", target = "retry", source_line = 88,
    error = "state-marker-pending" },
  { disposition = "lineage-terminal-external-evidence", status = "admitted", reason = "lineage-external-evidence",
    cas = "applied", target = "reconcile", source_line = 122, round = 1,
    prior = { { round = 0, findings_record = "open:\nexternal evidence remains", essence_stall = true } },
    effects = ra.json_array({ COMMENT }) },
  { disposition = "lineage-terminal-continuation-budget", status = "admitted", reason = "lineage-continuation-budget",
    cas = "applied", target = "reconcile", source_line = 122, round = 2,
    prior = { { round = 1, findings_record = "open:\nsecond resolvable finding" } },
    effects = ra.json_array({ COMMENT }) },
  { disposition = "lineage-terminal-no-semantic-progress", status = "admitted", reason = "lineage-no-semantic-progress",
    cas = "applied", target = "reconcile", source_line = 122, round = 4,
    prior = {
      { round = 1, findings_record = "open:\nfirst unchanged finding" },
      { round = 2, findings_record = "open:\nsecond unchanged finding" },
      { round = 3, findings_record = "open:\nthird unchanged finding" },
    }, effects = ra.json_array({ COMMENT }) },
  { disposition = "skip-round-lineage-already-advanced", status = "rejected", reason = "incoming-round-not-newer",
    cas = "skip-stale(converge round lineage already advanced)", target = "reject", source_line = 128, round = 0,
    prior = { { round = 0 } } },
  { disposition = "skip-converge-round-gap", status = "rejected", reason = "incoming-round-gap",
    cas = "skip-stale(converge round gap)", target = "reject", source_line = 133, round = 2,
    prior = { { round = 0 } } },
  { disposition = "current-terminal-external-evidence", status = "admitted", reason = "current-external-evidence",
    cas = "applied", target = "reconcile", source_line = 164, round = 0,
    findings_record = "open:\nno source-verifiable evidence remains", essence_stall = true,
    effects = ra.json_array({ COMMENT }) },
  { disposition = "current-terminal-continuation-budget", status = "admitted", reason = "current-continuation-budget",
    cas = "applied", target = "reconcile", source_line = 164, round = 1,
    findings_record = "open:\nsecond resolvable finding",
    prior = { { round = 0, findings_record = "open:\nfirst resolvable finding" } },
    effects = ra.json_array({ COMMENT }) },
  { disposition = "current-terminal-no-semantic-progress", status = "admitted", reason = "current-no-semantic-progress",
    cas = "applied", target = "reconcile", source_line = 164, round = 4,
    findings_record = "open:\nfourth unchanged finding",
    prior = {
      { round = 1, findings_record = "open:\nfirst unchanged finding" },
      { round = 2, findings_record = "open:\nsecond unchanged finding" },
      { round = 3, findings_record = "open:\nthird unchanged finding" },
    }, effects = ra.json_array({ COMMENT }) },
  { disposition = "admitted-reraise-narrowed-proposal", status = "admitted", reason = "continue-convergence",
    cas = "applied", target = "proposal", source_line = 195, round = 0,
    effects = ra.json_array({ PROPOSAL, COMMENT }) },
})

local function event_for(fixture)
  local payload = fixture.payload and ra.copy_value(fixture.payload) or h.unresolved({
    dedup_key = fixture.round and VERSION .. "/loop/" .. tostring(fixture.round) or VERSION,
    round = fixture.round or 0,
    narrowed_question = QUESTION,
    angle_digests = ANGLES,
    findings_record = fixture.findings_record,
    essence_stall = fixture.essence_stall,
  })
  return { queue = "consensus.consensus_converge", ts = "2026-06-03T02:03:04Z", payload = payload }
end

local function round_marker(event, fact)
  local round = fact.round
  local dedup = round == 0 and VERSION or VERSION .. "/loop/" .. tostring(round)
  return conv_rounds.converge_round_marker(event.payload.proposal_id, VERSION,
    convergence_shared.source_ref_digest(event.payload.source_ref), round, dedup,
    QUESTION, ANGLES, fact.findings_record, fact.essence_stall == true)
end

local function capture(fixture)
  h.mock_bot_env()
  local event = event_for(fixture)
  if fixture.target == "proposal" then h.mock_context_bundle(event.payload) end
  local comments = ra.json_array()
  if fixture.current_state then
    table.insert(comments, core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version))
  elseif fixture.payload == nil and fixture.error == nil then
    table.insert(comments, core.state_marker(PROPOSAL_ID, "thinking", VERSION))
  end
  for _, fact in ipairs(fixture.prior or {}) do table.insert(comments, round_marker(event, fact)) end
  local model = github_fake.model({ author_policy = { mode = "whitelist", logins = { "fkst-test-bot" } } })
  local github = github_fake.new(model)
  function github.issue_view(repo, number, fields, timeout)
    table.insert(model.writes, { kind = "issue_view", repo = repo, number = number, fields = fields, timeout = timeout })
    return { stdout = entity_read_mocks.issue_view_stdout({ repo = repo, number = number,
      labels = { "fkst-dev:" .. tostring(fixture.current_state or "thinking") }, comments = comments,
      author_login = fixture.author_login or "fkst-test-bot" }), stderr = "", exit_code = 0 }
  end
  local restorations = {}
  local captured = ra.capture_logging("loop", devloop_logging, restorations)
  ra.replace(devloop_commands, "gh_issue_view_loop", function(repo, number, timeout)
    return github.issue_view(repo, number, "title,updatedAt,labels,comments,state,author", timeout)
  end, restorations)
  ra.replace(github_author_policy, "from_handle_policy", function()
    return github_author_policy.from_logins({ "fkst-test-bot" })
  end, restorations)
  ra.replace(_G, "with_lock", function(_, fn) return fn() end, restorations)
  local result = fixture.error and testing.run_fake_expecting_failure(loop_department, event)
    or testing.run_fake(loop_department, event)
  ra.restore_all(restorations)
  if fixture.error then
    t.is_true(tostring(result.failure.error):find(fixture.error, 1, true) ~= nil,
      fixture.disposition .. ": exact fail-closed error")
  else
    local selected = nil
    for _, decision in ipairs(captured.decisions) do
      if decision.outcome == fixture.cas then selected = decision break end
    end
    t.is_true(selected ~= nil, fixture.disposition .. ": observable admission decision " .. ra.canonical_json(captured.decisions))
  end
  fixture.current_fact = { state = ra.nullable(fixture.current_state or (fixture.payload == nil and "thinking" or nil)),
    version = ra.nullable(fixture.current_version or (fixture.payload == nil and VERSION or nil)),
    lineage_rounds = #(fixture.prior or {}), author_login = fixture.author_login or "fkst-test-bot" }
  fixture.effect_version = event.payload.dedup_key
  fixture.issue_number = 42
  return ra.record({ dept = "loop", fixture = fixture, result = result, captured = captured,
    event = event, prefix = PREFIX, site = SITE, source_state = "thinking" })
end

return {
  test_loop_entry_acceptor_old_behavior_is_real_dispatch_and_bidirectional = function()
    ra.assert_site(t, { dept = "loop", fixtures = FIXTURES, capture = capture, prefix = PREFIX, site = SITE })
  end,
}
