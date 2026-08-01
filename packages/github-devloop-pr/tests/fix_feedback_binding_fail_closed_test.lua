-- Regression harness for #2991: a partially bound fix-feedback must FAIL CLOSED, not skip silently.
--
-- `packages/github-devloop-pr/core/pr_review_replayer.lua:272` drops a fix-feedback that lacks any of
-- `review_proposal_id` / `review_dedup_key` / `reviewed_head_sha` as `skip-foreign(fix-feedback-binding)`.
-- The marker being dropped is this bot's own, on this PR, for this proposal, in this domain -- it is an
-- own-domain fact that is INCOMPLETE, not a schema/domain/wrong-queue mismatch. CLAUDE.md reserves
-- `skip-foreign` for the latter and requires the former to fail closed so a handler that understands the
-- root cause can act.
--
-- Live consequence (PR#2915, frozen 39h): the liveness sweep redrives the `fixing` row forever -- correct,
-- #2725 forbids terminalizing on a timeout -- while this replay silently drops it every pass. Redrive plus
-- silent skip is a stable, permanent no-op that emits ZERO error facts, so neither the dead-letter path nor
-- any liveness assertion can see it.
--
-- Measured while writing this test, and worth recording because it contradicts a plausible reading:
-- the sibling guard at `libraries/devloop/replayer.lua:251` checks only TWO of the three fields, but it is
-- never reached from this package -- with no review registry the shared replayer bails out earlier as
-- `skip-foreign(replayer)`. So the two guards do not race; the drifted 2-field copy is unreachable here.
-- Collapsing them is cleanup, not the fix. The fix is the disposition below.

local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local m_builders = require("devloop.markers.builders")
local replay_fields = require("devloop.replay_fields")
local replayer = require("devloop.replayer")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"
local BINDING_FIELDS = { "review_proposal_id", "review_dedup_key", "reviewed_head_sha" }

local function complete_feedback(fix)
  return {
    review_proposal_id = fix.review_proposal_id,
    review_dedup_key = fix.review_dedup_key,
    reviewed_head_sha = HEAD_SHA,
  }
end

local function feedback_without(fix, field)
  local partial = {}
  for key, value in pairs(complete_feedback(fix)) do
    if key ~= field then
      partial[key] = value
    end
  end
  return partial
end

-- Returns the replay's own classification. A feedback treated as bound goes on to issue cross-package
-- effects that this unit harness cannot execute; that attempt is collapsed to one token, because the
-- subject here is the disposition, not which effect happened to be reached first.
local function classify(fix, feedback)
  local branch = devloop_base.implement_branch("owner/repo", "42", fix.version)
  local issue = {
    repo = "owner/repo",
    number = 42,
    source_ref = entity_lib.issue_source_ref("owner/repo", 42),
  }
  local state = { state = "fixing", version = fix.version, proposal_id = fix.proposal_id }
  local link = {
    proposal_id = fix.proposal_id,
    pr_number = fix.pr_number,
    branch = branch,
    impl_version = fix.version,
    base_branch = "dev",
  }
  local current_pr = {
    number = fix.pr_number,
    state = "OPEN",
    head_ref_name = branch,
    base_ref_name = "dev",
    head_sha = HEAD_SHA,
    comments = {},
  }
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), "fixing")
  local ok, result = pcall(replayer.replay_from_table_classified, core, "observe_pr", issue, state, row, {
    proposal_id = fix.proposal_id,
    source_ref = entity_lib.pr_source_ref("owner/repo", fix.pr_number),
    link = link,
    current_pr = current_pr,
    feedback = feedback,
    fix_feedback = feedback,
    snapshot = {
      comments = {
        core.state_marker(fix.proposal_id, "fixing", fix.version),
        m_builders.pr_link_marker(fix.proposal_id, fix.pr_number, branch, fix.version, "dev"),
      },
      prs = { { number = fix.pr_number, current = current_pr } },
      state = state,
    },
  })
  if not ok then
    return { kind = "raised", outcome = "proceeded-or-failed-closed", detail = tostring(result) }
  end
  return result
end

return {
  -- THE CONTRACT. An own-domain feedback that is missing a binding field must not be dropped as
  -- `skip-foreign`. Silently skipping it is what makes PR#2915's redrive loop invisible.
  test_partially_bound_fix_feedback_must_not_skip_foreign = function()
    local fix = h.fixing()
    local silent_drops = {}
    for _, field in ipairs(BINDING_FIELDS) do
      local classified = classify(fix, feedback_without(fix, field))
      if tostring(classified.outcome or ""):find("skip%-foreign") ~= nil then
        table.insert(silent_drops, string.format("missing %s -> %s", field, tostring(classified.outcome)))
      end
    end
    t.eq(table.concat(silent_drops, " | "), "",
      "an incomplete own-domain fix feedback must fail closed, not skip-foreign (#2991)")
  end,

  -- Non-vacuity control. If the complete feedback ALSO stopped proceeding, the assertion above could
  -- pass for the wrong reason -- a path that never reaches the binding check at all.
  test_complete_fix_feedback_still_proceeds = function()
    local fix = h.fixing()
    local classified = classify(fix, complete_feedback(fix))
    t.eq(tostring(classified.outcome or ""):find("fix%-feedback%-binding") == nil, true,
      "a fully bound feedback must not trip the binding guard; otherwise this suite proves nothing")
  end,
}
