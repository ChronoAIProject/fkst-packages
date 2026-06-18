local core = require("core")

local M = {}

M.spec = {
  consumes = { "entity_view_probe" },
}

local function lua_quote(value)
  return string.format("%q", tostring(value or ""))
end

local function lua_literal(value)
  local kind = type(value)
  if kind == "nil" then
    return "nil"
  end
  if kind == "boolean" or kind == "number" then
    return tostring(value)
  end
  if kind == "string" then
    return lua_quote(value)
  end
  if kind ~= "table" then
    error("github-proxy test probe: unsupported result field type")
  end
  local parts = {}
  local index = 1
  for key, field in pairs(value) do
    if key == index then
      table.insert(parts, lua_literal(field))
      index = index + 1
    else
      table.insert(parts, "[" .. lua_literal(key) .. "]=" .. lua_literal(field))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function write_result(path, payload)
  if path == nil or tostring(path) == "" then
    error("github-proxy test probe: missing result path")
  end
  file.write(path, "return " .. lua_literal(payload) .. "\n")
end

function pipeline(event)
  local payload = event.payload or {}
  local kind = tostring(payload.kind or "issue")
  local result
  if kind == "pr" then
    if payload.named_marker_reader then
      result = core.fetch_marker_pr_view(payload.repo, payload.number, payload.updated_at, {
        consumer = payload.consumer,
      })
    else
      result = core.fetch_pr_view(payload.repo, payload.number, payload.updated_at, {
        consumer = payload.consumer,
        fresh = payload.fresh,
        marker_bearing = payload.marker_bearing,
      })
    end
  else
    if payload.named_marker_reader then
      result = core.fetch_marker_issue_view(payload.repo, payload.number, payload.updated_at, {
        consumer = payload.consumer,
      })
    else
      result = core.fetch_issue_view(payload.repo, payload.number, payload.updated_at, {
        consumer = payload.consumer,
        fresh = payload.fresh,
        marker_bearing = payload.marker_bearing,
      })
    end
  end
  write_result(payload.result_path, {
    exit_code = result.exit_code,
    stdout = result.stdout,
    stderr = result.stderr,
  })
end

return M
