local claim_carriers = require("devloop.claim_carriers")

local M = {}

function M.mock_binding(t, repo, owner, times)
  local spec = claim_carriers.active_label_spec({ kind = "derived" }, owner or "fkst-test-bot")
  for _ = 1, times or 1 do
    t.mock_command("gh api repos/" .. tostring(repo or "owner/repo") .. "/labels/" .. spec.name, {
      stdout = '{"name":"' .. spec.name .. '","description":"' .. spec.description .. '"}\n',
      stderr = "",
      exit_code = 0,
    })
  end
  return spec
end

return M
