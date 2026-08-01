local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local run_observe = h.run_observe
local mock_issue_state = h.mock_issue_state
local mock_pr_origin_for = h.mock_pr_origin_for
local find_raise = h.find_raise
local count_calls = h.count_calls

local package_root = "packages/github-devloop"

local function read_source(path)
  local handle = assert(io.open(package_root .. "/" .. path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function read_repo_source(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function production_lua_paths()
  local paths = {}
  local find = assert(io.popen(
    "find packages/github-devloop/core packages/github-devloop/departments packages/github-devloop/raisers libraries/devloop"
      .. " -type f -name '*.lua' | sort"
  ))
  for path in find:lines() do
    table.insert(paths, path)
  end
  local ok = find:close()
  if ok ~= true then
    error("github-devloop: production source discovery failed")
  end
  return paths
end

local function normalize_expression(value)
  return (tostring(value or ""):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function state_marker_call_arguments(body, open_index)
  local arguments = {}
  local argument_start = open_index + 1
  local stack = { ")" }
  local index = argument_start
  local quote = nil
  while index <= #body do
    local char = body:sub(index, index)
    if quote ~= nil then
      if char == "\\" then
        index = index + 2
      elseif char == quote then
        quote = nil
        index = index + 1
      else
        index = index + 1
      end
    elseif char == '"' or char == "'" then
      quote = char
      index = index + 1
    elseif body:sub(index, index + 1) == "--" then
      local newline = body:find("\n", index + 2, true)
      index = newline or (#body + 1)
    elseif char == "(" or char == "[" or char == "{" then
      local close_by_open = { ["("] = ")", ["["] = "]", ["{"] = "}" }
      table.insert(stack, close_by_open[char])
      index = index + 1
    elseif char == stack[#stack] then
      if #stack == 1 then
        table.insert(arguments, normalize_expression(body:sub(argument_start, index - 1)))
        return arguments, index
      end
      table.remove(stack)
      index = index + 1
    elseif char == "," and #stack == 1 then
      table.insert(arguments, normalize_expression(body:sub(argument_start, index - 1)))
      argument_start = index + 1
      index = index + 1
    else
      index = index + 1
    end
  end
  error("github-devloop: state-marker-source-scan-unclosed-call")
end

local function state_marker_calls(body)
  local calls = {}
  local cursor = 1
  while true do
    local call_start, call_end = body:find("[%a_][%w_]*%.state_marker%s*%(", cursor)
    if call_start == nil then
      return calls
    end
    local line_start = (body:sub(1, call_start - 1):match(".*()\n") or 0) + 1
    local prefix = body:sub(line_start, call_start - 1)
    local open_index = body:find("(", call_start, true)
    local arguments, close_index = state_marker_call_arguments(body, open_index)
    if not prefix:match("^%s*function%s*$") then
      if #arguments < 2 then
        error("github-devloop: state-marker-source-scan-missing-state-argument")
      end
      local quote, literal = arguments[2]:match("^([\"'])(.-)%1$")
      table.insert(calls, {
        state_expression = arguments[2],
        literal_state = quote ~= nil and literal or nil,
      })
    end
    cursor = math.max(call_end + 1, close_index + 1)
  end
end

local function writes_ready_or_dynamic_state_marker(body)
  for _, call in ipairs(state_marker_calls(body)) do
    if call.literal_state == "ready" or call.literal_state == "dependency_wait" or call.literal_state == nil then
      return true
    end
  end
  return false
end

local dynamic_state_marker_policies = {
  ["libraries/devloop/hidden_state_conformance.lua"] = {
    ["row.from_state"] = { "local function base_entity", "devloop_state.state_label(row.from_state)" },
    ["child_state"] = { "local function child_pr", "if child_state ~= nil then" },
  },
  ["libraries/devloop/requests/lifecycle.lua"] = {
    ["canonical_state"] = { "function C.build_result_comment_request", 'local canonical_state = state_name or "ready"' },
  },
  ["libraries/devloop/requests/review.lua"] = {
    ["to_state"] = {
      'reached.reflection_checkpoint and "review-meta"',
      'reached.decision == "approve" and "merge-ready"',
      'or "fixing"',
    },
  },
  [package_root .. "/core/awaiting_pr_replayer.lua"] = {
    ["next_state.to_state"] = { "devloop_state.state_label_changes(next_state.to_state)" },
  },
  [package_root .. "/core/ready_split.lua"] = {
    ["to_state"] = { "function M.build_ready_split_transition_requests", "requests_labels.build_state_label_request" },
  },
}

local function department_main_paths()
  local root = package_root
  local paths = {}
  local find = assert(io.popen("find " .. root .. "/departments -mindepth 2 -maxdepth 2 -name main.lua | sort"))
  for path in find:lines() do
    table.insert(paths, path:sub(#root + 2))
  end
  local ok = find:close()
  if ok == false then
    error("github-devloop: department discovery failed")
  end
  return paths
end

local function writes_direct_pr_open_issue_label(body)
  return body:find('build_state_label_request%([^%)]-"pr%-open"', 1, false) ~= nil
    or body:find('build_reconcile_state_label_request%([^%)]-"pr%-open"', 1, false) ~= nil
    or body:find('state_label_changes%("pr%-open"%)', 1, false) ~= nil
    or body:find('state_label_reconcile_changes%([^%)]-"pr%-open"', 1, false) ~= nil
end

local function contains_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

return {
  test_observe_issue_reconciles_pr_open_label_when_backing_pr_exists = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local impl_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, "OPEN", {
      core.state_marker(proposal_id, "pr-open", impl_version),
      m_builders.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", impl_version, "dev"),
    })
    mock_pr_origin_for({
      comments = {
        m_builders.pr_origin_marker(proposal_id, "42", "devloop-owner-repo-42-01HY", impl_version, "dev"),
      },
      times = 2,
    })

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:implementing" } }), opts("observe-pr-open-label-authority"))
    t.eq(result.exit_code, 0)
    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      return tostring(payload.target_kind or "issue") == "issue"
    end)
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:awaiting-pr")
    t.is_true(contains_value(label_raise.payload.remove_labels, "fkst-dev:implementing"))
    t.eq(count_calls("--json body"), 0)
  end,

  test_pr_open_issue_state_label_authority_stays_in_observe_issue = function()
    for _, path in ipairs(department_main_paths()) do
      local body = read_source(path)
      if path ~= "departments/observe_issue/main.lua" then
        t.eq(writes_direct_pr_open_issue_label(body), false)
      end
    end

    local observe_body = read_source("departments/observe_issue/main.lua")
    t.is_true(observe_body:find("linked_entity_snapshot", 1, true) == nil)
    t.is_true(observe_body:find("linked_snapshot_issue_state", 1, true) == nil)
    t.is_true(observe_body:find("linked_pr_surface_snapshot", 1, true) ~= nil)
    t.is_true(observe_body:find("issue_label_projection_state(issue_state, link, snapshot)", 1, true) ~= nil)
    t.is_true(observe_body:find('issue_state.state == "pr-open"', 1, true) ~= nil)
    t.is_true(observe_body:find("linked_open_pr(snapshot, link.pr_number)", 1, true) ~= nil)
    t.is_true(observe_body:find("state_label_reconcile_changes", 1, true) ~= nil)
    t.is_true(observe_body:find("github-proxy.github_issue_label_request", 1, true) ~= nil)
  end,


  test_ready_and_dependency_wait_marker_producers_use_guarded_projection_capabilities = function()
    local ready_split = read_source("core/ready_split.lua")
    local seen_dynamic_policies = {}

    t.is_true(writes_ready_or_dynamic_state_marker(
      'local marker = devloop_state.state_marker(proposal_id, "ready", version)'
    ))
    t.is_true(writes_ready_or_dynamic_state_marker(
      'local marker = devloop_state.state_marker(\n  proposal_id,\n  "dependency_wait",\n  version\n)'
    ))
    t.is_true(writes_ready_or_dynamic_state_marker([[
      local to_state = gate.ok and "ready" or "dependency_wait"
      local marker = devloop_state.state_marker(proposal_id, to_state, version)
    ]]))
    t.is_true(writes_ready_or_dynamic_state_marker(
      "local marker = devloop_state.state_marker(proposal_id, select_target(gate), version)"
    ))
    t.eq(writes_ready_or_dynamic_state_marker(
      'local marker = devloop_state.state_marker(proposal_id, "blocked", version)'
    ), false)
    t.is_true(ready_split:find("local function ready_split_canonicalized_marker", 1, true) ~= nil)
    t.is_true(ready_split:find("local function build_ready_split_canonicalized_comment_request", 1, true) ~= nil)
    t.is_true(ready_split:find("function M.build_ready_split_transition_requests", 1, true) ~= nil)
    t.is_true(ready_split:find("requests_labels.build_state_label_request", 1, true) ~= nil)
    t.is_true(ready_split:find("M._blocked_on_dependency_label", 1, true) ~= nil)

    for _, path in ipairs(production_lua_paths()) do
      local body = read_repo_source(path)
      if path ~= package_root .. "/core/ready_split.lua" then
        t.eq(body:find("ready_split_canonicalized_marker", 1, true), nil, path)
        t.eq(body:find("return '<!-- fkst:github-devloop:ready-split-canonicalized:v1", 1, true), nil, path)
      end
      t.eq(body:find("build_result_label_request", 1, true), nil, path)
      for _, call in ipairs(state_marker_calls(body)) do
        if call.literal_state == "ready" or call.literal_state == "dependency_wait" then
          error(path .. ": ready/dependency_wait state_marker must use a guarded projection capability")
        elseif call.literal_state == nil then
          local policies = dynamic_state_marker_policies[path]
          local proofs = policies and policies[call.state_expression] or nil
          local policy_key = path .. "::" .. call.state_expression
          t.is_true(proofs ~= nil, policy_key .. " must declare projection or closed-domain evidence")
          t.eq(seen_dynamic_policies[policy_key], nil, policy_key .. " must identify exactly one dynamic producer")
          seen_dynamic_policies[policy_key] = true
          for _, proof in ipairs(proofs) do
            t.is_true(body:find(proof, 1, true) ~= nil, policy_key .. " missing evidence " .. proof)
          end
        end
      end
      if body:find("requests_lifecycle.build_result_comment_request", 1, true) ~= nil then
        t.is_true(body:find("requests_labels.build_result_state_label_request", 1, true) ~= nil, path)
      end
    end
    for path, policies in pairs(dynamic_state_marker_policies) do
      for expression in pairs(policies) do
        local policy_key = path .. "::" .. expression
        t.eq(seen_dynamic_policies[policy_key], true, policy_key .. " must match a discovered dynamic producer")
      end
    end
  end,
}
