local devloop_base = require("devloop.base")

local M = {}

M.prefix = "FKST_LOCAL_ITERATION_FAILURE_IDENTITY:v1:"

function M.validate_line(line)
  return type(line) == "string"
    and line:sub(1, #M.prefix) == M.prefix
    and line:find("[\r\n]") == nil
    and line:find("<", 1, true) == nil
    and #line <= devloop_base._max_meta_reason_len
end

function M.validate_set(lines)
  if type(lines) ~= "table" then
    return false, "invalid-line"
  end
  local count = 0
  for key in pairs(lines) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, "invalid-line"
    end
    count = count + 1
  end

  local size = 0
  for index = 1, count do
    local line = lines[index]
    if not M.validate_line(line) then
      return false, "invalid-line"
    end
    size = size + #line + (index > 1 and 1 or 0)
    if size > devloop_base._max_body_len then
      return false, "set-too-large"
    end
  end
  return true
end

return M
