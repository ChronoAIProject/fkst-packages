local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local marker_builders = require("devloop.markers.builders")
local premise_correction = require("devloop.premise_correction")
local claim_contract_mocks = require("tests.claim_contract_mock_helpers")
local t = h.t

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local decline_reason = "The deployment requires a production credential."

local function source_ref()
  return entity_lib.issue_source_ref(repo, issue_number)
end

local function entity_changed()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      updated_at = "2026-07-27T10:02:00Z",
      dedup_key = "owner/repo#issue#42@2026-07-27T10:02:00Z",
      source_ref = source_ref(),
    },
    source_ref = source_ref(),
  }
end

local function mock_repo_env()
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = repo, stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', {
      stdout = "fkst-test-bot,ElonSG",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZED_LOGINS"', {
      stdout = "trusted-human",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function decline_comment(dedup_key, reason, created_at)
  local premise = premise_correction.premise_fingerprint(proposal_id, dedup_key, reason)
  return {
    id = "IC_decline_" .. tostring(dedup_key),
    body = marker_builders.intake_decision_marker(proposal_id, "decline", dedup_key, "standard", premise),
    author_login = devloop_base._test_bot_login,
    created_at = created_at,
  }, premise
end

local function correction_comment(premise, id, evidence, created_at, override)
  local correction = override or premise_correction.correction_fingerprint(id, evidence)
  return {
    id = id,
    body = evidence .. '\n\n<!-- fkst:premise-correction:v1 premise="' .. premise
      .. '" correction="' .. correction .. '" -->',
    author_login = "trusted-human",
    created_at = created_at,
  }, correction
end

local function mock_issue(comments)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = issue_number,
    title = "Automate deployment",
    body = "Use the repository fake deployment adapter.",
    updated_at = "2026-07-27T10:02:00Z",
    state = "OPEN",
    labels = {},
    comments = comments,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

local function run(comments, name)
  h.mock_bot_env()
  mock_repo_env()
  claim_contract_mocks.mock_binding(t)
  mock_issue(comments)
  return t.run_department("departments/admission/main.lua", entity_changed(), h.opts(name))
end

return {
  test_admission_emits_existing_candidate_for_matching_later_correction = function()
    local decline, premise = decline_comment("intake/decline-1", decline_reason, "2026-07-27T10:00:00Z")
    local correction_comment_value, correction = correction_comment(
      premise,
      "IC_correction_positive",
      "The production-credential premise is corrected by the repository fake adapter.",
      "2026-07-27T10:01:00Z"
    )

    local result = run({ decline, correction_comment_value }, "premise-correction-admission-positive")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.premise_fingerprint, premise)
    t.eq(result.raises[1].payload.correction_fingerprint, correction)
    t.is_nil(result.raises[1].payload.correction_evidence)
  end,

  test_admission_ignores_absent_malformed_old_and_mismatched_corrections = function()
    local decline, premise = decline_comment("intake/decline-1", decline_reason, "2026-07-27T10:00:00Z")
    local old = correction_comment(premise, "IC_old", "Old evidence.", "2026-07-27T09:59:59Z")
    local wrong = correction_comment("premise-fp-123", "IC_wrong", "Wrong premise.", "2026-07-27T10:01:00Z")
    local malformed = correction_comment(premise, "IC_malformed", "Malformed identity.", "2026-07-27T10:01:00Z", "correction-fp-1")
    local cases = {
      { name = "absent", comments = { decline, { id = "IC_ordinary", body = "Ordinary comment.", author_login = "ordinary-user", created_at = "2026-07-27T10:01:00Z" } } },
      { name = "old", comments = { decline, old } },
      { name = "wrong", comments = { decline, wrong } },
      { name = "malformed", comments = { decline, malformed } },
    }
    for _, case in ipairs(cases) do
      local result = run(case.comments, "premise-correction-admission-" .. case.name)
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
    end
  end,

  test_replay_and_redecline_do_not_reconsume_the_same_correction = function()
    local decline, premise = decline_comment("intake/decline-1", decline_reason, "2026-07-27T10:00:00Z")
    local correction_comment_value, correction = correction_comment(
      premise,
      "IC_correction_replay",
      "The premise changed.",
      "2026-07-27T10:01:00Z"
    )
    local enable = {
      id = "IC_enable_after_correction",
      body = marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        premise_correction.decision_dedup_key(devloop_base.intake_decision_dedup_key(proposal_id, {
          title = "Automate deployment",
          body = "Use the repository fake deployment adapter.",
        }), {
          premise_fingerprint = premise,
          correction_fingerprint = correction,
        }),
        "standard"
      ),
      author_login = devloop_base._test_bot_login,
      created_at = "2026-07-27T10:02:00Z",
    }
    local enabled_replay = run({ decline, correction_comment_value, enable }, "premise-correction-enabled-replay")
    t.eq(enabled_replay.exit_code, 0)
    t.eq(#enabled_replay.raises, 0)

    local redecline_dedup = premise_correction.decision_dedup_key(devloop_base.intake_decision_dedup_key(proposal_id, {
      title = "Automate deployment",
      body = "Use the repository fake deployment adapter.",
    }), {
      premise_fingerprint = premise,
      correction_fingerprint = correction,
    })
    local redecline = decline_comment(
      redecline_dedup,
      "The corrected evidence still requires production access.",
      "2026-07-27T10:02:00Z"
    )
    local declined_replay = run({ decline, correction_comment_value, redecline }, "premise-correction-redecline-replay")
    t.eq(declined_replay.exit_code, 0)
    t.eq(#declined_replay.raises, 0)
  end,
}
