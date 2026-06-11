package.loaded["locales.en"] = {
  ["prompt_preamble.language"] = "polluted consensus locale",
}

local core = require("core")
local t = fkst.test

return {
  test_catalog_loader_ignores_global_require_cache = function()
    local preamble = core.prompt_preamble(nil)
    t.is_nil(preamble:find("polluted consensus locale", 1, true))
    t.is_true(preamble:find("Write all output in English", 1, true) ~= nil)
  end,
}
