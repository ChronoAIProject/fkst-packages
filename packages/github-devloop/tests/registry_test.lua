local registry = require("std.registry")
local t = fkst.test

local function fake_require_from(modules)
  return function(name)
    local loader = modules[name]
    if loader == nil then
      error("test fake require missing module " .. tostring(name))
    end
    if type(loader) == "function" then
      return loader()
    end
    return loader
  end
end

local function expect_error_contains(fn, needle)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(needle, 1, true) ~= nil, tostring(err))
end

return {
  test_indexed_map_loads_explicit_sorted_entries = function()
    local caller_require = fake_require_from({
      ["tests.fake_registry.index"] = function()
        return {
          { module = "first_entry", key = "first-entry" },
          { module = "second_entry", key = "second-entry" },
        }
      end,
      ["tests.fake_registry.first_entry"] = function()
        return { name = "first-entry", value = "a" }
      end,
      ["tests.fake_registry.second_entry"] = function()
        return { name = "second-entry", value = "b" }
      end,
    })
    local loaded = registry.load_indexed_map("tests.fake_registry.index", "name", nil, nil, "github-devloop", caller_require)
    t.eq(loaded["first-entry"].value, "a")
    t.eq(loaded["second-entry"].value, "b")
    t.eq(loaded["first-entry"].name, nil)

    local loaded_again = registry.load_indexed_map("tests.fake_registry.index", "name", nil, nil, "github-devloop", caller_require)
    t.eq(loaded_again["first-entry"].value, "a")
    t.eq(loaded_again["second-entry"].value, "b")
    t.eq(loaded_again["first-entry"].name, nil)
  end,

  test_indexed_array_rejects_unsorted_index = function()
    local caller_require = fake_require_from({
      ["tests.unsorted_registry.index"] = function()
        return { "z", "a" }
      end,
    })
    expect_error_contains(function()
      registry.load_indexed_array("tests.unsorted_registry.index", "name", nil, nil, "github-devloop", caller_require)
    end, "not sorted")
  end,

  test_indexed_array_rejects_duplicate_index_entries = function()
    local caller_require = fake_require_from({
      ["tests.duplicate_registry.index"] = function()
        return { "a", "a" }
      end,
    })
    expect_error_contains(function()
      registry.load_indexed_array("tests.duplicate_registry.index", "name", nil, nil, "github-devloop", caller_require)
    end, "duplicate registry index entry")
  end,

  test_indexed_array_rejects_entry_key_mismatch = function()
    local caller_require = fake_require_from({
      ["tests.mismatch_registry.index"] = function()
        return {
          { module = "entry", key = "expected" },
        }
      end,
      ["tests.mismatch_registry.entry"] = function()
        return { name = "actual" }
      end,
    })
    expect_error_contains(function()
      registry.load_indexed_array("tests.mismatch_registry.index", "name", nil, nil, "github-devloop", caller_require)
    end, "does not match index entry")
  end,
}
