local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")

local core = h.core
local t = h.t

local REPO = "owner/repo"
local OTHER_REPO = "other/repo"
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local SOURCE_REF = { kind = "external", ref = REPO .. "#issue/42" }

local function encode_json_string(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function blocked_by_json(nodes, opts)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%s,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tostring(node.number),
      encode_json_string(node.state or "OPEN"),
      encode_json_string(node.state_reason or ""),
      encode_json_string(node.repo or REPO)
    ))
  end
  local total = opts and opts.total_count or #rendered
  local has_next_page = opts and opts.has_next_page == true and "true" or "false"
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(total)
    .. ',"pageInfo":{"hasNextPage":'
    .. has_next_page
    .. '},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function mock_managed_repos(value)
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_MANAGED_SIBLING_REPOS"), {
    stdout = value or "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocked_by(repo, issue_number, nodes, opts)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = blocked_by_json(nodes, opts),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocked_by_failure(repo, issue_number)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = "",
    stderr = "graphql failed",
    exit_code = 1,
  })
end

local function mock_blocker_issue(repo, issue_number)
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"OPEN","comments":[],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function with_replaced(target, key, replacement, fn)
  local original = target[key]
  target[key] = replacement
  local ok, result = pcall(fn)
  target[key] = original
  if not ok then
    error(result)
  end
  return result
end

local function capture_replay(gate)
  local raised = {}
  local original_log_raise = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, result = pcall(core.replay_dependency_wait_state,
    "dependency_proof_status_test",
    {
      repo = REPO,
      number = 42,
      source_ref = SOURCE_REF,
    },
    {
      state = "dependency_wait",
      version = VERSION,
      proposal_id = PROPOSAL_ID,
    },
    nil,
    {
      proposal_id = PROPOSAL_ID,
      current = {
        labels = { "fkst-dev:ready", "fkst-dev:blocked-on-dependency" },
        comments = {},
      },
      dependency_gate = gate,
    }
  )
  devloop_logging.log_raise = original_log_raise
  if not ok then
    error(result)
  end
  return raised
end

local function has_marker(raises, marker)
  for _, item in ipairs(raises or {}) do
    local body = item.payload and item.payload.body
    if type(body) == "string" and body:find(marker, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function cycle_proof(issue_number, target_issue_number)
  return {
    kind = "dependency-cycle",
    repo = REPO,
    issue_number = issue_number,
    target_repo = REPO,
    target_issue_number = target_issue_number or issue_number,
  }
end

return {
  test_dependency_gate_returns_closed_status_without_boolean_alias = function()
    mock_managed_repos("")
    mock_blocked_by(REPO, 42, {})

    local gate = core.dependency_gate(REPO, 42)

    t.eq(gate.kind, "satisfied")
    t.eq(gate.ok, nil)
    t.eq(core.dependency_gate_is_satisfied(gate), true)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate), false)
  end,

  test_dependency_cycle_carries_validated_terminal_proof = function()
    mock_managed_repos("")
    mock_blocked_by(REPO, 42, { { number = 43 } })
    mock_blocked_by(REPO, 43, { { number = 42 } })

    local gate = core.dependency_gate(REPO, 42)

    t.eq(gate.kind, "verified_cannot_proceed")
    t.eq(gate.reason, "dependency-cycle")
    t.eq(gate.proof.kind, "dependency-cycle")
    t.eq(gate.proof.repo, REPO)
    t.eq(gate.proof.issue_number, 42)
    t.eq(gate.proof.target_repo, REPO)
    t.eq(gate.proof.target_issue_number, 42)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate, REPO, 42), true)
  end,

  test_nested_cycle_proof_is_bound_to_the_root_dependency_target = function()
    mock_managed_repos("")
    mock_blocked_by(REPO, 44, { { number = 45 } })
    mock_blocked_by(REPO, 45, { { number = 46 } })
    mock_blocked_by(REPO, 46, { { number = 45 } })

    local gate = core.dependency_gate(REPO, 44)

    t.eq(gate.kind, "verified_cannot_proceed")
    t.eq(gate.proof.issue_number, 45)
    t.eq(gate.proof.target_repo, REPO)
    t.eq(gate.proof.target_issue_number, 44)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate, REPO, 44), true)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate, REPO, 45), false)
  end,

  test_unmanaged_cross_repo_blocker_carries_validated_terminal_proof = function()
    mock_managed_repos("")
    mock_blocked_by(REPO, 42, { { number = 77, repo = OTHER_REPO } })

    local gate = core.dependency_gate(REPO, 42)

    t.eq(gate.kind, "verified_cannot_proceed")
    t.eq(gate.reason, "cross-repo-blocker")
    t.eq(gate.proof.kind, "cross-repo-blocker")
    t.eq(gate.proof.repo, REPO)
    t.eq(gate.proof.issue_number, 42)
    t.eq(gate.proof.blocker_repo, OTHER_REPO)
    t.eq(gate.proof.blocker_number, 77)
    t.eq(gate.proof.target_repo, REPO)
    t.eq(gate.proof.target_issue_number, 42)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate, REPO, 42), true)
  end,

  test_depth_cap_is_unavailable_without_fabricated_unmet_dependency = function()
    local root_issue = 91000
    mock_managed_repos("")
    for issue_number = root_issue, root_issue + 32 do
      mock_blocked_by(REPO, issue_number, { { number = issue_number + 1 } })
    end

    local gate = core.dependency_gate(REPO, root_issue)

    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "depth-cap-exceeded")
    t.eq(#gate.unmet, 0)
    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate), false)
  end,

  test_repeated_read_failures_hold_until_a_fresh_successful_derivation = function()
    mock_managed_repos("")

    mock_blocked_by_failure(REPO, 42)
    local first = core.dependency_gate(REPO, 42)
    t.eq(first.kind, "unavailable")
    t.eq(first.reason, "gh-failed")
    t.eq(#first.unmet, 0)
    local first_held = capture_replay(first)
    t.eq(has_marker(first_held, "fkst:github-devloop:dependency-unresolvable:v1"), true)
    t.eq(has_marker(first_held, 'state="blocked"'), false)

    mock_blocked_by_failure(REPO, 42)
    local second = core.dependency_gate(REPO, 42)
    t.eq(second.kind, "unavailable")
    t.eq(second.reason, "gh-failed")
    local second_held = capture_replay(second)
    t.eq(has_marker(second_held, "fkst:github-devloop:dependency-unresolvable:v1"), true)
    t.eq(has_marker(second_held, 'state="blocked"'), false)

    mock_blocked_by(REPO, 42, {})
    local recovered = core.dependency_gate(REPO, 42)
    t.eq(recovered.kind, "satisfied")
    t.eq(core.dependency_gate_is_satisfied(recovered), true)
    local released = capture_replay(recovered)
    t.eq(has_marker(released, 'state="ready"'), true)
    t.eq(has_marker(released, 'state="blocked"'), false)
  end,

  test_invalid_unknown_and_exception_observations_are_unavailable = function()
    local unknown_root = 92000
    local unknown_blocker = unknown_root + 1
    local invalid = core.dependency_gate("invalid", 42)
    t.eq(invalid.kind, "unavailable")
    t.eq(invalid.reason, "invalid-target")

    mock_managed_repos("")
    mock_blocked_by(REPO, unknown_root, { { number = unknown_blocker } })
    mock_blocked_by(REPO, unknown_blocker, {})
    mock_blocker_issue(REPO, unknown_blocker)
    local unknown = with_replaced(core, "delegated_blocker_merged", function()
      return nil, nil
    end, function()
      return core.dependency_gate(REPO, unknown_root)
    end)
    t.eq(unknown.kind, "unavailable")
    t.eq(unknown.reason, "unknown-blocker")
    t.eq(#unknown.unmet, 0)

    mock_managed_repos("")
    local caught = with_replaced(core, "gh_blocked_by", function()
      error("forced dependency read exception")
    end, function()
      return core.dependency_gate(REPO, 42)
    end)
    t.eq(caught.kind, "unavailable")
    t.eq(caught.reason, "dependency-gate-exception")
    t.eq(core.dependency_gate_is_verified_cannot_proceed(caught), false)
  end,

  test_consumer_exhaustively_holds_releases_or_blocks_by_proof_status = function()
    h.mock_bot_env()

    local waiting = capture_replay({
      kind = "waiting",
      hold_kind = "waiting",
      reason = "waiting-on-dependency",
      unmet = { 43 },
    })
    t.eq(has_marker(waiting, "fkst:github-devloop:dependency-wait:v1"), true)
    t.eq(has_marker(waiting, 'state="blocked"'), false)

    local unavailable = capture_replay({
      kind = "unavailable",
      hold_kind = "unresolvable",
      reason = "gh-failed",
      unmet = {},
    })
    t.eq(has_marker(unavailable, "fkst:github-devloop:dependency-unresolvable:v1"), true)
    t.eq(has_marker(unavailable, 'state="blocked"'), false)

    local proofless = capture_replay({
      kind = "verified_cannot_proceed",
      hold_kind = "cycle",
      reason = "dependency-cycle",
      unmet = { 42 },
    })
    t.eq(has_marker(proofless, "fkst:github-devloop:dependency-cycle:v1"), true)
    t.eq(has_marker(proofless, 'state="blocked"'), false)

    local mismatched_proof = capture_replay({
      kind = "verified_cannot_proceed",
      hold_kind = "cycle",
      reason = "dependency-cycle",
      unmet = { 42 },
      proof = {
        kind = "cross-repo-blocker",
        repo = REPO,
        issue_number = 42,
        blocker_repo = OTHER_REPO,
        blocker_number = 77,
      },
    })
    t.eq(has_marker(mismatched_proof, 'state="blocked"'), false)

    local wrong_target = capture_replay({
      kind = "verified_cannot_proceed",
      hold_kind = "cycle",
      reason = "dependency-cycle",
      unmet = { 42 },
      proof = cycle_proof(42, 99),
    })
    t.eq(has_marker(wrong_target, 'state="blocked"'), false)

    local unknown = capture_replay({
      kind = "future-status",
      hold_kind = "unresolvable",
      reason = "unproven-future-observation",
      unmet = {},
    })
    t.eq(has_marker(unknown, "fkst:github-devloop:dependency-unresolvable:v1"), true)
    t.eq(has_marker(unknown, 'state="blocked"'), false)

    local verified = capture_replay({
      kind = "verified_cannot_proceed",
      hold_kind = "cycle",
      reason = "dependency-cycle",
      unmet = { 42 },
      proof = cycle_proof(42),
    })
    t.eq(has_marker(verified, 'state="blocked"'), true)

    local recovered = capture_replay({
      kind = "satisfied",
      reason = "satisfied",
      unmet = {},
    })
    t.eq(has_marker(recovered, 'state="ready"'), true)
    t.eq(has_marker(recovered, 'state="blocked"'), false)
  end,
}
