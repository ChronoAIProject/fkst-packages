local C = {}

local rounds = require("devloop.rounds")
local max_attr_len = 240

local intake_service_class_set = {
  expedite = true,
  standard = true,
  background = true,
}

function C.valid_round(_M, value)
  return rounds.valid_round(value)
end

function C.normalize_intake_service_class(_M, value)
  local text = tostring(value or ""):lower()
  if intake_service_class_set[text] then
    return text
  end
  return "standard"
end

function C.is_intake_service_class(_M, value)
  return intake_service_class_set[tostring(value or "")] == true
end

function C.marker_attr(_M, marker, name)
  return marker:match(name .. '="([^"]*)"')
end

function C.safe_marker_attr(M, value, limit)
  local text = tostring(value or "")
  text = text:gsub("<!%-%- fkst:[^\n]*%-%->", " ")
  text = text:gsub("&lt;!%-%- fkst:[^\n]*%-%-&gt;", " ")
  text = text:gsub("%c", " "):gsub('"', "'"):gsub("[<>]", ""):gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  local cap = limit or max_attr_len
  if #text > cap then
    text = M.truncate_utf8(text, cap)
  end
  return text
end

function C.decode_marker_attr(_M, value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if value:find("%c") ~= nil or value:find("[<>]") ~= nil or value:find('"', 1, true) ~= nil then
    return nil
  end
  return value
end

return C
