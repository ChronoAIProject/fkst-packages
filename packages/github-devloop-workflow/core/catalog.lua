local blueprint = require("core.blueprint")
local fail = require("core.errors").fail

local M = {}

M.MAX_CATALOG_FILES = 128

local function empty_result()
  return {
    valid = {},
    errors = {},
    duplicates = {},
  }
end

local function is_json_path(path)
  return type(path) == "string" and path:sub(-5) == ".json"
end

local function add_error(result, path, why)
  table.insert(result.errors, {
    path = path,
    error = why,
  })
end

local function duplicate_record(id, records)
  local paths = {}
  for index, record in ipairs(records) do
    paths[index] = record.path
  end
  return {
    id = id,
    paths = paths,
  }
end

function M.load_catalog(root_dir)
  local result = empty_result()
  if type(root_dir) ~= "string" or root_dir == "" then
    add_error(result, tostring(root_dir), fail("root_dir", "invalid_root_dir", "must be a non-empty string"))
    return result
  end

  local ok, listed = pcall(file.list, root_dir)
  if not ok then
    add_error(result, root_dir, fail("root_dir", "file_list_failed", "file.list failed", {
      error = tostring(listed),
    }))
    return result
  end

  local json_paths = {}
  for _, path in ipairs(listed) do
    if is_json_path(path) then
      table.insert(json_paths, path)
    end
  end
  table.sort(json_paths)
  if #json_paths > M.MAX_CATALOG_FILES then
    add_error(result, root_dir, fail("catalog", "too_many_files", "catalog exceeds MAX_CATALOG_FILES", {
      max_count = M.MAX_CATALOG_FILES,
      actual_count = #json_paths,
    }))
    return result
  end

  local by_id = {}
  local id_order = {}
  for _, path in ipairs(json_paths) do
    local read_ok, source = pcall(file.read, path)
    if not read_ok then
      add_error(result, path, fail("file", "file_read_failed", "file.read failed", {
        error = tostring(source),
      }))
    else
      local parsed, why = blueprint.parse_blueprint(source)
      if parsed == nil then
        add_error(result, path, why)
      else
        if by_id[parsed.id] == nil then
          by_id[parsed.id] = {}
          table.insert(id_order, parsed.id)
        end
        table.insert(by_id[parsed.id], {
          path = path,
          blueprint = parsed,
        })
      end
    end
  end

  for _, id in ipairs(id_order) do
    local records = by_id[id]
    if #records == 1 then
      result.valid[id] = {
        path = records[1].path,
        blueprint = records[1].blueprint,
      }
    else
      local duplicate = duplicate_record(id, records)
      table.insert(result.duplicates, duplicate)
      add_error(result, duplicate.paths[1], fail("catalog." .. id, "duplicate_id", "duplicate workflow id", {
        id = id,
        peers = duplicate.paths,
      }))
    end
  end

  return result
end

function M.install(target)
  target.catalog = M
end

return M
