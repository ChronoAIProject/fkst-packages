local t = fkst.test

local M = {}

-- Recorded commands whose rendered form invokes codex. Twelve suites across seven packages
-- each carried this definition.
function M.codex_calls()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      table.insert(calls, call)
    end
  end
  return calls
end

return M
