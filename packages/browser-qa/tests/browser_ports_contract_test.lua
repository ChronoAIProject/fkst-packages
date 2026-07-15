local ports = require("browser_ports")
local t = fkst.test

return {
  test_install_restores_pipeline_when_department_validation_fails = function()
    local original_pipeline = function(_event) end
    local invalid_pipeline = function(_event) end
    local old_pipeline = _G.pipeline
    _G.pipeline = original_pipeline

    local ok = pcall(ports.install, function(_handles)
      _G.pipeline = invalid_pipeline
      return {}
    end)

    local restored = _G.pipeline
    _G.pipeline = old_pipeline
    t.eq(ok, false)
    t.eq(restored, original_pipeline)
  end,
}
