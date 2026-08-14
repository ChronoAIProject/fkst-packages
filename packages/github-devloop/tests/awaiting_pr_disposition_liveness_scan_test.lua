local fixture = require("tests.integration_liveness_scan_helpers")

local core = fixture.core
local entity_lib = fixture.entity_lib
local entity_read_mocks = fixture.entity_read_mocks
local h = fixture.h
local m_builders = fixture.m_builders
local proposal_id = fixture.proposal_id
local repo = fixture.repo
local t = fixture.t
local version = fixture.version

local PR_NUMBER = 7
local CHILD_PROPOSAL_ID = entity_lib.pr_proposal_id(repo, PR_NUMBER)

local function awaiting_pr_row()
  for _, row in ipairs(core.restart_transition_table()) do
    if row.from_state == "awaiting-pr" then return row end
  end
  error("awaiting-pr restart row is missing")
end

local function over_budget_iso()
  local budget_minutes = assert(awaiting_pr_row().budget.minutes)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now() - ((budget_minutes + 1) * 60))
end

local CASES = {
  { name = "merged", state = "merged", disposition = "terminal" },
  { name = "closed-unmerged", state = "closed-unmerged", disposition = "terminal" },
  { name = "blocked", state = "blocked", disposition = "terminal" },
  { name = "reviewing", state = "reviewing", disposition = "in-flight" },
  { name = "unknown", state = "vendor-paused", disposition = "unknown" },
  { name = "missing", disposition = "missing" },
  { name = "stale", state = "blocked", disposition = "stale", state_version = "v0" },
  {
    name = "identity-mismatch",
    state = "reviewing",
    disposition = "identity-mismatch",
    child_proposal_id = entity_lib.pr_proposal_id("other/repo", PR_NUMBER),
  },
}

local function timeout_attempt_raise(result)
  return fixture.find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload and payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
  end)
end

local function trusted_comment(body, created_at)
  return {
    author_login = "fkst-test-bot",
    body = body,
    created_at = created_at,
  }
end

local function state_marker(state, state_version)
  if core.is_state(state) then
    return core.state_marker(proposal_id, state, state_version)
  end
  return '<!-- fkst:github-devloop:state:v1 proposal="' .. proposal_id
    .. '" state="' .. state .. '" version="' .. state_version .. '" -->'
end

local function parent_comments(case)
  local created_at = over_budget_iso()
  return {
    trusted_comment(core.state_marker(proposal_id, "awaiting-pr", version), created_at),
    trusted_comment(m_builders.pr_delegation_marker(
      proposal_id,
      case.child_proposal_id or CHILD_PROPOSAL_ID,
      PR_NUMBER,
      version,
      "g1"
    ), created_at),
  }
end

local function child_comments(case)
  if case.state == nil then return {} end
  return {
    trusted_comment(state_marker(case.state, case.state_version or (version .. "/fix/1")), over_budget_iso()),
  }
end

local function run_liveness_case(case)
  fixture.mock_repo()
  fixture.mock_issue_list({{
    number = 42,
    state = "open",
    updated_at = "2026-06-03T01:02:03Z",
  }})
  fixture.mock_issue_state_number(42, {
    "fkst-dev:enabled",
    "fkst-dev:awaiting-pr",
  }, "OPEN", parent_comments(case))
  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = PR_NUMBER,
    head = "devloop-owner-repo-42",
    head_sha = "0123456789abcdef0123456789abcdef01234567",
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
    comments = child_comments(case),
    times = 1,
  })

  local result = fixture.run_liveness_scan(
    "awaiting-pr-disposition-liveness-" .. case.name,
    fixture.opts("awaiting-pr-disposition-liveness-" .. case.name)
  )
  t.eq(result.exit_code, 0, case.name .. ": liveness scan exit")
  return result
end

return {
  test_liveness_scan_consumes_production_derived_child_disposition = function()
    for _, case in ipairs(CASES) do
      local result = run_liveness_case(case)
      local reinjection = fixture.find_raise(result.raises, fixture.ISSUE_REDRIVE_QUEUE)
      t.is_true(reinjection ~= nil, case.name .. ": nonterminal parent remains level-triggered")
      if case.disposition == "in-flight" then
        t.eq(timeout_attempt_raise(result), nil, case.name .. ": live child defers timeout redrive")
      else
        t.is_true(timeout_attempt_raise(result) ~= nil, case.name .. ": non-live disposition redrives after budget")
      end
      t.eq(fixture.find_raise(result.raises, "devloop_timeout_reconcile"), nil,
        case.name .. ": liveness observation does not transition the parent")
    end
  end,
}
