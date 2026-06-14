local h = require("tests.devloop_helpers")
local t = h.t

local function package_root()
  local source = package.searchpath("tests.devloop_helpers", package.path)
  return source:match("(.+)/tests/devloop_helpers%.lua$")
end

local function read_source(path)
  local handle = assert(io.open(package_root() .. "/" .. path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function line_count(body)
  local count = 0
  for _ in tostring(body or ""):gmatch("\n") do
    count = count + 1
  end
  return count
end

local function assert_module(path, install_name)
  local body = read_source(path)
  t.is_true(line_count(body) < 700)
  t.is_true(body:find("function M%.install_" .. install_name, 1, false) ~= nil)
  t.is_true(body:find("return M", 1, true) ~= nil)
  return body
end

local function assert_contains(body, needle)
  t.is_true(body:find(needle, 1, true) ~= nil)
end

local function assert_not_contains(body, needle)
  t.is_true(body:find(needle, 1, true) == nil)
end

return {
  test_observability_core_is_split_into_department_local_responsibility_modules = function()
    local core_body = read_source("core/observability.lua")
    t.is_true(line_count(core_body) < 250)
    t.is_true(core_body:find('require("departments.observability.census")', 1, true) ~= nil)
    t.is_true(core_body:find('require("departments.observability.common")', 1, true) ~= nil)
    t.is_true(core_body:find('require("departments.observability.dashboard")', 1, true) ~= nil)
    t.is_true(core_body:find('require("departments.observability.reaper")', 1, true) ~= nil)

    local common_body = assert_module("departments/observability/common.lua", "common")
    local census_body = assert_module("departments/observability/census.lua", "census")
    local dashboard_body = assert_module("departments/observability/dashboard.lua", "dashboard")
    local reaper_body = assert_module("departments/observability/reaper.lua", "reaper")

    assert_contains(common_body, "function M.fetch_issue")
    assert_contains(common_body, "function M.fetch_pr")
    assert_contains(census_body, "function core.collect_observability_entities")
    assert_contains(dashboard_body, "function core.render_observability_dashboard")
    assert_contains(dashboard_body, "function core.publish_observability_dashboard")
    assert_contains(reaper_body, "function core.reap_orphan_prs")

    assert_not_contains(core_body, "function core.collect_observability_entities")
    assert_not_contains(core_body, "function core.render_observability_dashboard")
    assert_not_contains(core_body, "function core.publish_observability_dashboard")
    assert_not_contains(core_body, "function core.reap_orphan_prs")
  end,
}
