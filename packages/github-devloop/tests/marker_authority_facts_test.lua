local h = require("tests.devloop_core_helpers")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/marker-authority"

return {
  test_pr_delegation_fact_distinguishes_conflict_from_absence = function()
    local delegation_marker = m_builders.pr_delegation_marker(
      proposal_id,
      "github-devloop/pr/owner/repo/7",
      7,
      version,
      "g1"
    )
    local valid_delegation, valid_status = m_facts.pr_delegation_fact({
      delegation_marker,
    }, proposal_id)
    local absent_delegation, absent_status = m_facts.pr_delegation_fact({}, proposal_id)
    local conflicting_delegation, conflict_status = m_facts.pr_delegation_fact({
      delegation_marker,
      m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/8",
        8,
        version,
        "g2"
      ),
    }, proposal_id)

    t.eq(valid_delegation.pr_number, 7)
    t.eq(valid_status, "valid")
    t.eq(absent_delegation, nil)
    t.eq(absent_status, "absent")
    t.eq(conflicting_delegation, nil)
    t.eq(conflict_status, "conflict")
  end,
}
