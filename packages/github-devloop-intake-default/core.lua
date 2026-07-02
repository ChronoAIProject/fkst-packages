local saga_conformance = require("devloop.saga_conformance")
local intake_install = require("devloop.intake.install")
local M

-- fkst.toml conformance hook: function = "core.saga_conformance_errors" (delegates to typed devloop.saga_conformance.errors)
local function saga_conformance_errors()
  return saga_conformance.errors(M)
end

M = {
  saga_conformance_errors = saga_conformance_errors,
}

intake_install.install(M)

return M
