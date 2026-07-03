local catalog = require("core.catalog")
local default_catalog = require("core.default_catalog")
local t = fkst.test

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function test_root()
  local token = tostring({}):gsub("[^A-Za-z0-9]", "")
  return "/tmp/fkst-workflow-catalog-test-" .. token
end

local function valid_json(id)
  return [[{
    "schema": "fkst.workflow.v1",
    "id": "]] .. id .. [[",
    "version": "2026-07-02",
    "summary": "A bounded workflow.",
    "applies_when": "The origin issue asks for this workflow.",
    "steps": [
      {"id":"first","title":"First step","content":{"kind":"static","intent":"Do the first bounded step."}}
    ]
  }]]
end

local function cleanup(root)
  os.remove(root .. "/alpha.json")
  os.remove(root .. "/bad.json")
  os.remove(root .. "/dup-a.json")
  os.remove(root .. "/ignored.txt")
  os.remove(root .. "/nested/beta.json")
  os.remove(root .. "/nested/dup-b.json")
  os.execute("rmdir " .. shell_quote(root .. "/nested") .. " >/dev/null 2>&1")
  os.execute("rmdir " .. shell_quote(root) .. " >/dev/null 2>&1")
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if ok ~= true and ok ~= 0 then
    error("failed to create temp catalog directory")
  end
end

local function prepare(root)
  cleanup(root)
  mkdir_p(root .. "/nested")
  file.write(root .. "/alpha.json", valid_json("alpha"))
  file.write(root .. "/nested/beta.json", valid_json("beta"))
  file.write(root .. "/dup-a.json", valid_json("dup"))
  file.write(root .. "/nested/dup-b.json", valid_json("dup"))
  file.write(root .. "/bad.json", [[{"schema":"wrong","id":"bad","version":"1","summary":"bad","applies_when":"bad","steps":[]}]] )
  file.write(root .. "/ignored.txt", valid_json("ignored"))
end

local function with_temp_root(fn)
  local root = test_root()
  local ok, err = pcall(function()
    fn(root)
  end)
  cleanup(root)
  if not ok then
    error(err, 0)
  end
end

local function error_with_code(errors, code)
  for _, item in ipairs(errors) do
    if item.error ~= nil and item.error.code == code then
      return item
    end
  end
  return nil
end

local tests = {
  test_load_catalog_keeps_valid_rejects_invalid_and_records_duplicates = function()
    with_temp_root(function(root)
      prepare(root)

      local loaded = catalog.load_catalog(root)

      t.eq(loaded.valid.alpha.blueprint.id, "alpha")
      t.is_true(loaded.valid.alpha.path:sub(-10) == "alpha.json")
      t.eq(loaded.valid.beta.blueprint.id, "beta")
      t.is_true(loaded.valid.beta.path:sub(-16) == "nested/beta.json")
      t.is_nil(loaded.valid.dup)
      t.is_nil(loaded.valid.ignored)
      t.eq(#loaded.duplicates, 1)
      t.eq(loaded.duplicates[1].id, "dup")
      t.eq(#loaded.duplicates[1].paths, 2)
      t.is_true(error_with_code(loaded.errors, "invalid_schema") ~= nil)
      local duplicate = error_with_code(loaded.errors, "duplicate_id")
      t.is_true(duplicate ~= nil)
      t.eq(duplicate.error.meta.id, "dup")
      t.eq(#duplicate.error.meta.peers, 2)
    end)
  end,

  test_validate_records_is_shared_by_builtin_catalog = function()
    local records = default_catalog.records()
    local loaded = catalog.validate_records(records)
    local record = loaded.valid["software-dev-flow"]

    t.eq(#loaded.errors, 0)
    t.eq(#loaded.duplicates, 0)
    t.eq(record.path, "builtin:software-dev-flow")
    t.eq(record.blueprint.id, "software-dev-flow")
  end,

  test_builtin_software_dev_flow_steps_are_generated_code_increments = function()
    local loaded = catalog.validate_records(default_catalog.records())
    local blueprint = loaded.valid["software-dev-flow"].blueprint
    local expected = {
      scaffold = "MERGED result of the previous step",
      implement = "MERGED result of the previous step",
      test = "MERGED result of the previous step",
    }

    t.eq(#blueprint.steps, 3)
    for _, step in ipairs(blueprint.steps) do
      t.eq(step.content.kind, "generated")
      t.is_true(step.content.generator:find("Implement", 1, true) ~= nil)
      t.is_true(step.content.generator:find(expected[step.id], 1, true) ~= nil)
    end
    t.eq(blueprint.steps[1].id, "scaffold")
    t.eq(blueprint.steps[2].id, "implement")
    t.eq(blueprint.steps[3].id, "test")
  end,

  test_validate_records_rejects_duplicate_ids_across_sources = function()
    local records = default_catalog.records()
    table.insert(records, {
      path = "external/software-dev-flow.json",
      blueprint = records[1].blueprint,
    })

    local loaded = catalog.validate_records(records)

    t.is_nil(loaded.valid["software-dev-flow"])
    t.eq(#loaded.duplicates, 1)
    t.eq(loaded.duplicates[1].id, "software-dev-flow")
    t.eq(loaded.duplicates[1].paths[1], "builtin:software-dev-flow")
    t.eq(loaded.duplicates[1].paths[2], "external/software-dev-flow.json")
    t.eq(error_with_code(loaded.errors, "duplicate_id").error.meta.id, "software-dev-flow")
  end,

  test_rejects_invalid_root_dir = function()
    local loaded = catalog.load_catalog("")
    t.eq(#loaded.errors, 1)
    t.eq(loaded.errors[1].error.code, "invalid_root_dir")
  end,

  test_records_file_list_failure = function()
    local previous_list = file.list
    file.list = function(_path)
      error("forced list failure")
    end
    local ok, loaded = pcall(function()
      return catalog.load_catalog("/tmp/fkst-workflow-catalog-test-list-failure")
    end)
    file.list = previous_list
    if not ok then
      error(loaded, 0)
    end
    t.eq(#loaded.errors, 1)
    t.eq(loaded.errors[1].error.code, "file_list_failed")
  end,

  test_records_file_read_failure = function()
    with_temp_root(function(root)
      mkdir_p(root)
      file.write(root .. "/gone.json", valid_json("gone"))
      local previous_read = file.read
      file.read = function(path)
        if path:sub(-9) == "gone.json" then
          error("forced read failure")
        end
        return previous_read(path)
      end
      local ok, loaded = pcall(function()
        return catalog.load_catalog(root)
      end)
      file.read = previous_read
      if not ok then
        error(loaded, 0)
      end
      t.eq(#loaded.errors, 1)
      t.eq(loaded.errors[1].error.code, "file_read_failed")
    end)
  end,

  test_rejects_over_max_catalog_files = function()
    with_temp_root(function(root)
      mkdir_p(root)
      for index = 1, catalog.MAX_CATALOG_FILES + 1 do
        file.write(root .. "/wf-" .. tostring(index) .. ".json", valid_json("wf-" .. tostring(index)))
      end
      local loaded = catalog.load_catalog(root)
      t.eq(#loaded.errors, 1)
      t.eq(loaded.errors[1].error.code, "too_many_files")
    end)
  end,
}

return tests
