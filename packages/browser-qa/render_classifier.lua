local M = {}

local function nonnegative_integer(value, field)
  local number = tonumber(value)
  if number == nil or number < 0 or number % 1 ~= 0 then
    error("browser-qa: browser-adapter-invalid-result: invalid " .. field, 0)
  end
  return number
end

function M.blank_render(observation)
  if type(observation) ~= "table" then
    error("browser-qa: browser-adapter-invalid-result: missing render observation", 0)
  end
  local visible_text_chars = nonnegative_integer(observation.visible_text_chars, "visible_text_chars")
  local visible_visual_count = nonnegative_integer(observation.visible_visual_count, "visible_visual_count")
  return visible_text_chars == 0 and visible_visual_count == 0
end

return M
