local t = fkst.test
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local harvest = require("departments.implement.harvest")

local proposal_id = "github-devloop/issue/owner/repo/42"
local lineage = "ready/github-devloop/issue/owner/repo/42/intake/123"
local branch = "devloop-owner-repo-42"
local head_sha = "1111111111111111111111111111111111111111"
local base_sha = "2222222222222222222222222222222222222222"

local function checkpoint(version, attempt, reason)
  return m_builders.implement_checkpoint_marker(
    proposal_id, version, branch, head_sha, "dev", base_sha, attempt, reason)
end

return {
  test_first_indeterminate_checkpoint_remains_recoverable = function()
    local outcome = harvest.bound_verification_checkpoint({
      kind = "implement-checkpoint",
      reason = "verification-indeterminate",
      ready = { proposal_id = proposal_id, dedup_key = lineage },
      detail = "verification unavailable",
    }, {})

    t.eq(outcome.kind, "implement-checkpoint")
    t.is_true(outcome.detail:find("consecutive_indeterminate_checkpoints=1/2", 1, true) ~= nil)
  end,

  test_consecutive_indeterminate_checkpoints_are_lineage_scoped = function()
    local comments = {
      checkpoint("other-lineage", 1, "verification-indeterminate"),
      checkpoint(lineage, 1, "verification-indeterminate"),
      checkpoint(lineage, 2, "codex-failed"),
      checkpoint(lineage, 3, "verification-indeterminate"),
      checkpoint(lineage, 4, "verification-indeterminate"),
    }

    t.eq(m_facts.consecutive_implement_checkpoint_count(
      comments, proposal_id, lineage, "verification-indeterminate"), 2)
    t.eq(m_facts.consecutive_implement_checkpoint_count(
      comments, proposal_id, "other-lineage", "verification-indeterminate"), 1)
  end,

  test_untrusted_checkpoint_does_not_enter_the_streak = function()
    local comments = {
      checkpoint(lineage, 1, "verification-indeterminate"),
      {
        body = checkpoint(lineage, 2, "verification-indeterminate"),
        author_login = "untrusted-user",
      },
    }

    t.eq(m_facts.consecutive_implement_checkpoint_count(
      comments, proposal_id, lineage, "verification-indeterminate"), 1)
  end,
}
