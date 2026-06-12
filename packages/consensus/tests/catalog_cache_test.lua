package.loaded["locales.en"] = {
  ["prompt_preamble.language"] = "polluted consensus locale",
}

local source = package.searchpath("tests.catalog_cache_test", package.path)
local sibling_root = source:gsub("/consensus/tests/catalog_cache_test%.lua$", "/github-devloop")
local original_package_path = package.path

local core = require("core")
local t = fkst.test

return {
  test_engine_i18n_ignores_global_require_cache_and_package_path = function()
    package.path = sibling_root .. "/?.lua;" .. sibling_root .. "/?/init.lua;" .. original_package_path
    local preamble = core.prompt_preamble(nil)
    package.path = original_package_path
    t.is_nil(preamble:find("polluted consensus locale", 1, true))
    t.is_true(preamble:find("Before judging, identify the established theory", 1, true) ~= nil)
  end,
}
