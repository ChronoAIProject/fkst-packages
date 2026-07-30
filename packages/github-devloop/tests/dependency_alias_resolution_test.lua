local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local repo = "owner/repo"

local function encode_json_string(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function issue_projection_json(issue, include_duplicate)
  local duplicate = include_duplicate and ',"duplicateOf":null' or ""
  if include_duplicate and type(issue.duplicate_of) == "table" then
    duplicate = ',"duplicateOf":' .. issue_projection_json(issue.duplicate_of, false)
  end
  return string.format(
    '{"number":%d,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}%s}',
    tonumber(issue.number),
    encode_json_string(issue.state or "OPEN"),
    encode_json_string(issue.state_reason or ""),
    encode_json_string(issue.repo or repo),
    duplicate
  )
end

local function blocked_by_json(issue_number, blockers, issue)
  local rendered = {}
  for _, blocker in ipairs(blockers or {}) do
    table.insert(rendered, issue_projection_json(blocker, true))
  end
  local root_issue = issue or {
    number = issue_number,
    state = "OPEN",
    repo = repo,
  }
  local projection = issue_projection_json(root_issue, true)
  projection = projection:sub(1, -2)
  return '{"data":{"repository":{"issue":' .. projection
    .. ',"blockedBy":{"totalCount":' .. tostring(#rendered)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",") .. ']}}}}}\n'
end

local function mock_dependency_graph(issue_number, blockers, issue)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = blocked_by_json(issue_number, blockers, issue),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_canonical_issue(issue_number, state_name)
  local comments = ""
  if state_name ~= nil then
    local marker = core.state_marker(
      base_ids.proposal_id(repo, issue_number),
      state_name,
      "v-" .. tostring(issue_number)
    )
    comments = '{"body":"' .. encode_json_string(marker)
      .. '","author":{"login":"fkst-test-bot"},"createdAt":"2026-07-30T00:00:00Z"}'
  end
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"OPEN","comments":[' .. comments
      .. '],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_canonical_issue_failure(issue_number)
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = "",
    stderr = "issue view failed",
    exit_code = 1,
  })
end

local function duplicate(number, canonical)
  return {
    number = number,
    state = "CLOSED",
    state_reason = "DUPLICATE",
    duplicate_of = canonical,
  }
end

local function open_issue(number, target_repo)
  return {
    number = number,
    state = "OPEN",
    repo = target_repo or repo,
  }
end

local function completed_issue(number)
  return {
    number = number,
    state = "CLOSED",
    state_reason = "COMPLETED",
    repo = repo,
  }
end

return {
  test_duplicate_alias_holds_while_canonical_issue_is_open = function()
    mock_dependency_graph(42, { duplicate(11, open_issue(12)) })
    mock_canonical_issue(12, "ready")

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "waiting")
    t.eq(gate.reason, "waiting-on-dependency")
    t.eq(gate.unmet[1], 12)
  end,

  test_duplicate_alias_releases_after_canonical_issue_is_merged = function()
    mock_dependency_graph(42, { duplicate(21, open_issue(22)) })
    mock_canonical_issue(22, "ready")
    local waiting = core.dependency_gate(repo, 42)
    t.eq(core.dependency_gate_is_satisfied(waiting), false)
    t.eq(waiting.unmet[1], 22)

    mock_dependency_graph(42, { duplicate(21, completed_issue(22)) })
    mock_canonical_issue(22, "merged")
    local satisfied = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(satisfied), true)
    t.eq(satisfied.kind, "satisfied")
  end,

  test_duplicate_alias_without_canonical_target_fails_closed = function()
    mock_dependency_graph(42, { duplicate(31, nil) })

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "duplicate-target-missing")
    t.eq(gate.unmet[1], 31)
  end,

  test_duplicate_alias_with_unreadable_canonical_target_fails_closed = function()
    mock_dependency_graph(42, { duplicate(31, open_issue(32)) })
    mock_canonical_issue_failure(32)

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "duplicate-target-unreadable")
    t.eq(gate.unmet[1], 32)
  end,

  test_duplicate_alias_with_cross_repo_target_fails_closed = function()
    mock_dependency_graph(42, { duplicate(51, open_issue(52, "other/repo")) })

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "cross-repo-duplicate-target")
    t.eq(gate.unmet[1], 52)
  end,

  test_duplicate_alias_cycle_uses_dependency_cycle_guard = function()
    mock_dependency_graph(42, {
      duplicate(61, duplicate(62, nil)),
    })
    mock_dependency_graph(62, {}, duplicate(62, duplicate(61, nil)))

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "verified_cannot_proceed")
    t.eq(core.dependency_gate_is_verified_cannot_proceed(gate, repo, 42), true)
    t.eq(gate.reason, "dependency-cycle")
    t.eq(gate.unmet[1], 61)
  end,

  test_duplicate_alias_chain_uses_existing_dependency_depth_cap = function()
    mock_dependency_graph(42, {
      duplicate(100, duplicate(101, nil)),
    })
    for number = 101, 131 do
      mock_dependency_graph(number, {}, duplicate(number, duplicate(number + 1, nil)))
    end

    local gate = core.dependency_gate(repo, 42)

    t.eq(core.dependency_gate_is_satisfied(gate), false)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "depth-cap-exceeded")
    t.eq(gate.unmet[1], 132)
  end,
}
