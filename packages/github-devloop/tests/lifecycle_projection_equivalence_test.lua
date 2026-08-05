local t = fkst.test
local issue_core = require("core")
local restart_metadata = require("devloop.restart_metadata")
local partition = require("devloop.restart.issue.pr_partition_contract")
local state_labels = require("devloop.state_labels")

local function set_from_list(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end

local function set_from_keys(values)
  local result = {}
  for key in pairs(values or {}) do
    result[key] = true
  end
  return result
end

local function union(left, right)
  local result = set_from_keys(left)
  for value in pairs(right or {}) do
    result[value] = true
  end
  return result
end

local function difference(left, right)
  local result = {}
  for value in pairs(left or {}) do
    if right[value] ~= true then
      table.insert(result, value)
    end
  end
  table.sort(result)
  return result
end

local function display(values)
  return "[" .. table.concat(values, ",") .. "]"
end

local function assert_same_set(left_code, left_site, left, right_code, right_site, right)
  local missing_from_left = difference(right, left)
  local extra_in_left = difference(left, right)
  t.is_true(#missing_from_left == 0 and #extra_in_left == 0,
    left_code .. " " .. left_site .. " disagrees with " .. right_code .. " " .. right_site
      .. ": missing_from_" .. left_code .. "=" .. display(missing_from_left)
      .. "; extra_in_" .. left_code .. "=" .. display(extra_in_left))
end

-- Execute a sibling package's production modules with the same local-first
-- module resolution shape as the engine's owner-scoped loader.
local function package_loader(root)
  local loaded = {}
  local function load_module(module_name)
    if loaded[module_name] ~= nil then
      return loaded[module_name]
    end
    local relative = module_name == "core" and "core.lua" or module_name:gsub("%.", "/") .. ".lua"
    local path = root .. "/" .. relative
    local readable, source = pcall(file.read, path)
    if not readable then
      return require(module_name)
    end
    loaded[module_name] = true
    local environment = setmetatable({ require = load_module }, { __index = _ENV })
    environment._G = environment
    local chunk = assert(load(source, "@" .. path, "t", environment))
    local value = chunk(module_name)
    loaded[module_name] = value == nil and true or value
    return loaded[module_name]
  end
  return load_module
end

local function milestone_domains()
  local path = "libraries/devloop/restart_metadata.lua"
  local source = file.read(path)
  local opening = "local milestone_domains = {"
  local closing = "\n}\n\nlocal function domain_allows_state"
  local opening_start, opening_end = assert(source:find(opening, 1, true))
  local closing_start, closing_end = assert(source:find(closing, opening_end + 1, true))
  local captured
  local instrumented = source:sub(1, opening_start - 1)
    .. "local milestone_domains = capture_milestone_domains({"
    .. source:sub(opening_end + 1, closing_start - 1)
    .. "\n})\n\nlocal function domain_allows_state"
    .. source:sub(closing_end + 1)
  local environment = setmetatable({
    capture_milestone_domains = function(value)
      captured = value
      return value
    end,
    require = require,
  }, { __index = _ENV })
  environment._G = environment
  assert(load(instrumented, "@" .. path, "t", environment))("devloop.restart_metadata")
  return assert(captured)
end

local function normalized_transition_modules(index, site)
  local result = {}
  for row_number, row in ipairs(index or {}) do
    local normalized = tostring(row.module)
    if tostring(row.key):find("-", 1, true) ~= nil then
      normalized = normalized:gsub("_", "-")
    end
    t.eq(normalized, row.key,
      site .. " module/key normalization disagrees at row " .. tostring(row_number))
    t.is_true(result[normalized] ~= true,
      site .. " has duplicate normalized module state at row " .. tostring(row_number) .. ": " .. normalized)
    result[normalized] = true
  end
  return result
end

return {
  test_lifecycle_projection_declarations_are_equivalent = function()
    local load_pr = package_loader("packages/github-devloop-pr")
    local pr_core = load_pr("core")
    local issue_index = require("core.restart.transitions.index")
    local pr_index = load_pr("core.restart.transitions.index")

    local graph_states = set_from_keys(state_labels.state_graph)
    local issue_states = set_from_list(issue_core.restart_lifecycle_states)
    local pr_states = set_from_list(pr_core.restart_lifecycle_states)
    local package_states = union(issue_states, pr_states)
    package_states.unmanaged = true

    assert_same_set("A", "libraries/devloop/state_labels.lua state_graph", graph_states,
      "B+C", "package restart_lifecycle_states union plus unmanaged", package_states)
    assert_same_set("G.ISSUE_STATES", "devloop.restart.issue.pr_partition_contract issue_states()",
      set_from_list(partition.issue_states()), "B", "packages/github-devloop/core.lua restart_lifecycle_states", issue_states)
    assert_same_set("G.PR_STATES", "devloop.restart.issue.pr_partition_contract PR phase+terminal states",
      union(set_from_list(partition.pr_phase_states()), set_from_list(partition.pr_terminal_states())),
      "C", "packages/github-devloop-pr/core.lua restart_lifecycle_states", pr_states)

    local domains = milestone_domains()
    assert_same_set("D.issue", "libraries/devloop/restart_metadata.lua milestone_domains[github-devloop-issue]",
      set_from_keys(domains["github-devloop-issue"]), "B", "packages/github-devloop/core.lua restart_lifecycle_states", issue_states)
    assert_same_set("D.pr", "libraries/devloop/restart_metadata.lua milestone_domains[github-devloop-pr]",
      set_from_keys(domains["github-devloop-pr"]), "C", "packages/github-devloop-pr/core.lua restart_lifecycle_states", pr_states)
    assert_same_set("E", "packages/github-devloop/core/restart/transitions/index.lua normalized module rows",
      normalized_transition_modules(issue_index, "E issue transition index"),
      "B", "packages/github-devloop/core.lua restart_lifecycle_states", issue_states)
    assert_same_set("F", "packages/github-devloop-pr/core/restart/transitions/index.lua normalized module rows",
      normalized_transition_modules(pr_index, "F PR transition index"),
      "C", "packages/github-devloop-pr/core.lua restart_lifecycle_states", pr_states)

    t.is_true(restart_metadata._domain_allows_state("github-devloop-issue", "unmanaged") == false,
      "D.issue milestone domain must not absorb A's unmanaged entry state")
  end,
}
