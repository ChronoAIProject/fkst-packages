-- #2275 branch-distinctness: a replacement generation reached through the
-- awaiting-pr `closed-unmerged -> ready` path carries version
-- "<base>/reimplement/N". `implementation_base_version` STRIPS that suffix (so an
-- in-place impl_retry_attempt reuses one branch), which would name the
-- replacement branch identically to the abandoned original branch. The new
-- `implementation_branch_version` PRESERVES the trailing round so the replacement
-- branch is provably distinct. These are direct unit tests over the accessor and
-- `implement_branch`; the existing accessor semantics are unchanged.
local devloop_base = require("devloop.base")
local payloads_builders = require("devloop.payloads.builders")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

local repo = "owner/repo"
local issue_number = "42"
local base_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local replacement_version = base_version .. "/reimplement/1"

return {
  test_branch_version_preserves_reimplement_round_1 = function()
    -- The abandoned-branch accessor collapses round 1 back to the base ...
    t.eq(core.implementation_base_version(replacement_version), base_version)
    -- ... but the branch-naming accessor keeps the round.
    t.eq(core.implementation_branch_version(replacement_version), replacement_version)
    -- So the two accessors are provably different for a round-1 replacement.
    t.is_true(core.implementation_base_version(replacement_version)
      ~= core.implementation_branch_version(replacement_version))
  end,

  test_replacement_branch_differs_from_abandoned_branch = function()
    local abandoned_branch = devloop_base.implement_branch(
      repo, issue_number, core.implementation_base_version(replacement_version))
    local replacement_branch = devloop_base.implement_branch(
      repo, issue_number, core.implementation_branch_version(replacement_version))
    -- The replacement branch must NOT reuse the abandoned original branch.
    t.is_true(abandoned_branch ~= replacement_branch)
    -- The abandoned branch is exactly the original generation's branch, so the
    -- distinctness is against the real history the stale PR was built on.
    t.eq(abandoned_branch, devloop_base.implement_branch(repo, issue_number, base_version))
  end,

  test_original_generation_branch_is_unchanged = function()
    -- An original ready version (no trailing /reimplement/N) is untouched: the
    -- branch-naming version equals the base version, so original implementation
    -- and in-place impl_retry_attempt runs keep their existing branch.
    t.eq(core.implementation_branch_version(base_version), base_version)
    t.eq(core.implementation_branch_version(base_version), core.implementation_base_version(base_version))
    t.eq(
      devloop_base.implement_branch(repo, issue_number, core.implementation_branch_version(base_version)),
      devloop_base.implement_branch(repo, issue_number, core.implementation_base_version(base_version))
    )
  end,

  test_branch_version_preserves_higher_rounds_and_is_bounded = function()
    -- A later round is preserved too ...
    t.eq(core.implementation_branch_version(base_version .. "/reimplement/2"), base_version .. "/reimplement/2")
    -- ... and a version whose trailing suffix is not a reimplement round falls
    -- back to the base (bounded, no crash).
    t.eq(core.implementation_branch_version(base_version .. "/review-loop/3"),
      core.implementation_base_version(base_version .. "/review-loop/3"))
  end,

  -- Production payload shape: build the exact devloop_ready payload the awaiting-pr
  -- `closed-unmerged -> ready` replacement flows into `implement` -- the replayer
  -- names the ready state at next_reimplement(<original ready version>), and the
  -- ready hand-off carries that version into ready.dedup_key. Prove the fix
  -- activates on that REAL payload, not just a literal string.
  test_replacement_ready_payload_yields_a_distinct_branch = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local replacement_marker_version = transition_version.next_reimplement(base_version)
    t.is_true(replacement_marker_version:find("/reimplement/1", 1, true) ~= nil)

    local replacement_ready = payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = proposal_id,
      dedup_key = replacement_marker_version,
      source_ref = h.source_ref(),
    })
    -- The devloop_ready payload that `implement` consumes still carries the
    -- trailing round that `implement_branch` names the branch from.
    t.is_true(tostring(replacement_ready.dedup_key):find("/reimplement/1", 1, true) ~= nil)

    -- OLD branch computation (implementation_base_version, implement/main.lua before
    -- #2275) strips the round; NEW (implementation_branch_version) preserves it, so
    -- the replacement branch is provably different from the abandoned base branch.
    local old_branch = devloop_base.implement_branch(repo, issue_number, core.implementation_base_version(replacement_ready.dedup_key))
    local new_branch = devloop_base.implement_branch(repo, issue_number, core.implementation_branch_version(replacement_ready.dedup_key))
    t.is_true(old_branch ~= new_branch)
    -- The OLD branch is exactly the abandoned base branch (round stripped away).
    t.eq(old_branch, devloop_base.implement_branch(repo, issue_number,
      transition_version.strip_trailing_reimplement(replacement_ready.dedup_key)))
  end,
}
