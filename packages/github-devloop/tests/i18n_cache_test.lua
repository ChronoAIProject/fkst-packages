package.loaded["locales.en"] = {
  ["dashboard.title"] = "polluted devloop locale",
}

local source = package.searchpath("tests.i18n_cache_test", package.path)
local sibling_root = source:gsub("/github%-devloop/tests/i18n_cache_test%.lua$", "/consensus")
local original_package_path = package.path

local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

return {
  test_catalog_loader_ignores_global_require_cache_and_package_path = function()
    package.path = sibling_root .. "/?.lua;" .. sibling_root .. "/?/init.lua;" .. original_package_path
    local title = core.dashboard_string("title")
    package.path = original_package_path
    t.eq(title, "fkst-dev board")
  end,
}
