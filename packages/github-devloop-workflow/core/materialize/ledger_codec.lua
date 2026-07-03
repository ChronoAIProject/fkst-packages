local M = {}

M.GENERATED_SPEC_BEGIN = "<!-- fkst:github-devloop-workflow:generated-spec:v2 -->"
M.GENERATED_SPEC_END = "<!-- /fkst:github-devloop-workflow:generated-spec:v2 -->"

local function append_field(parts, name, value)
  local text = tostring(value or "")
  parts[#parts + 1] = "field:" .. name
  parts[#parts + 1] = tostring(#text)
  parts[#parts + 1] = text
end

function M.encode_generated_spec(generated_spec)
  local parts = { M.GENERATED_SPEC_BEGIN }
  append_field(parts, "title", generated_spec and generated_spec.title)
  append_field(parts, "body", generated_spec and generated_spec.body)
  parts[#parts + 1] = M.GENERATED_SPEC_END
  return table.concat(parts, "\n")
end

local function read_line(text, pos)
  local next_newline = text:find("\n", pos, true)
  if next_newline == nil then
    return nil, nil
  end
  return text:sub(pos, next_newline - 1), next_newline + 1
end

local function read_field(text, pos, expected_name)
  local header
  header, pos = read_line(text, pos)
  if header ~= "field:" .. expected_name then
    return nil, nil
  end

  local length_text
  length_text, pos = read_line(text, pos)
  local length = tonumber(length_text)
  if length == nil or length < 0 or math.floor(length) ~= length then
    return nil, nil
  end

  local end_pos = pos + length - 1
  if end_pos > #text then
    return nil, nil
  end
  local value = text:sub(pos, end_pos)
  pos = end_pos + 1
  if text:sub(pos, pos) ~= "\n" then
    return nil, nil
  end
  return value, pos + 1
end

function M.decode_generated_spec_block(body)
  local text = tostring(body or "")
  local start_pos = text:find(M.GENERATED_SPEC_BEGIN, 1, true)
  if start_pos == nil then
    return nil
  end

  local pos = start_pos + #M.GENERATED_SPEC_BEGIN
  if text:sub(pos, pos) ~= "\n" then
    return nil
  end
  pos = pos + 1

  local title
  title, pos = read_field(text, pos, "title")
  if title == nil then
    return nil
  end

  local generated_body
  generated_body, pos = read_field(text, pos, "body")
  if generated_body == nil then
    return nil
  end

  if text:sub(pos, pos + #M.GENERATED_SPEC_END - 1) ~= M.GENERATED_SPEC_END then
    return nil
  end

  return {
    title = title,
    body = generated_body,
  }
end

return M
