package.loaded["locales.en"] = {
  ["dashboard.title"] = "polluted devloop locale",
}

local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

return {
  test_catalog_loader_ignores_global_require_cache = function()
    t.eq(core.dashboard_string("title"), "fkst-dev board")
  end,
}
