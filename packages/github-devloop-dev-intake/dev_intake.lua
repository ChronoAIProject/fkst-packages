-- github-devloop-dev-intake: the label-scoped dev intake logic.
--
-- This holds the candidate reuse points and the per-issue admission orchestration,
-- kept OUT of departments/ so the department wrappers stay thin (no require("core") /
-- core.X reads). The candidate PAYLOAD and its effect_id are built by the SHARED devloop
-- library exactly as github-devloop-intake/core/admission.lua builds a FRESH admission
-- candidate -- this module hand-rolls NOTHING about the candidate shape.
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local m_facts = require("devloop.markers.facts")
local payloads_builders = require("devloop.payloads.builders")

local M = {}

-- The single work label this dev intake polls. A constant here -- NOT read from env or
-- from devloop config; github-issue.scopes.list asserts it is non-empty.
M.LABEL = "fkst-dev"

-- The EXISTING candidate seam github-devloop-workflow.workflow_select consumes.
M.CANDIDATE_QUEUE = "github-devloop-intake.devloop_intake_candidate"

-- Build the fresh intake-admission candidate for one discovered issue. Mirrors
-- github-devloop-intake/core/admission.lua build_intake_admission_candidate (fresh,
-- command == nil path): compute effect_id via the shared intake_decision_dedup_key, then
-- call the shared build_devloop_intake_candidate_payload. There is no reintake command on
-- the poll path, so no reintake_* fields and no delivery_version -- the delivery dedup_key
-- stays content-stable across polls so repeated polls before the intake decision marker
-- lands dedup naturally at the seam.
function M.build_candidate(repo, current, issue_number)
  local proposal_id = base_ids.proposal_id(repo, tostring(issue_number))
  local effect_id = devloop_base.intake_decision_dedup_key(proposal_id, {
    title = current.title,
    body = current.body,
  }, nil, nil)
  return payloads_builders.build_devloop_intake_candidate_payload(repo, tostring(issue_number), current.updated_at, {
    effect_id = effect_id,
  })
end

-- The intake skip guard, matching github-devloop-intake admission: skip a non-OPEN issue,
-- an issue already in a known devloop state (core.should_skip_known_intake_issue), or one
-- that already carries a trusted intake-decision marker for this proposal.
function M.should_skip(core, current, proposal_id)
  if tostring(current.state or ""):upper() ~= "OPEN" then
    return true
  end
  if core.should_skip_known_intake_issue(current.labels) then
    return true
  end
  if m_facts.has_intake_decision_marker(current.comments, proposal_id) then
    return true
  end
  return false
end

-- Per-tick orchestration over the discovered fkst-dev scopes. For each scope it runs the
-- SAME per-issue sequence github-devloop-intake admission runs: fetch rich view (via the
-- injected read_current) -> skip-guard -> claim -> build candidate -> raise. The
-- collaborators (read_current / claim / emit) are injected so the reuse points stay
-- VERBATIM (bindings.lua wires the real gh view read, devloop.claims claim, and
-- devloop.logging raise) while the orchestration stays unit-testable.
function M.admit_scopes(deps)
  local core = deps.core
  local dept = deps.dept
  local repo = deps.repo
  local read_current = deps.read_current
  local claim = deps.claim
  local emit = deps.emit
  for _, scope in ipairs(deps.scopes or {}) do
    local issue_number = tostring(scope.number)
    local proposal_id = base_ids.proposal_id(repo, issue_number)
    local current = read_current(scope.number)
    if not M.should_skip(core, current, proposal_id) then
      if claim(core, dept, repo, issue_number, current, proposal_id) then
        emit(dept, proposal_id, M.CANDIDATE_QUEUE, M.build_candidate(repo, current, issue_number))
      end
    end
  end
end

return M
