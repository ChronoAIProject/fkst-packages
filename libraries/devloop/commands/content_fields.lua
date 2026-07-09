local M = {}

local function split_fields(fields)
  local result = {}
  for field in tostring(fields or ""):gmatch("[^,]+") do
    result[#result + 1] = field
  end
  return result
end

function M.fields_include_content(fields)
  for _, field in ipairs(split_fields(fields)) do
    if field == "body" or field == "comments" then
      return true
    end
  end
  return false
end

return M
