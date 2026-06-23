local contract_registry = require("contract.registry")
local t = fkst.test

local function expect_error_contains(fn, needle)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(needle, 1, true) ~= nil, tostring(err))
end

return {
  test_indexed_map_loads_explicit_sorted_entries = function()
    local index = {
      { module = "first_entry", key = "first-entry" },
      { module = "second_entry", key = "second-entry" },
    }
    local entries = {
      { name = "first-entry", value = "a" },
      { name = "second-entry", value = "b" },
    }
    local loaded = contract_registry.build_indexed_map("tests.fake_registry.index", index, entries, "name", nil, nil, "github-devloop")
    t.eq(loaded["first-entry"].value, "a")
    t.eq(loaded["second-entry"].value, "b")
    t.eq(loaded["first-entry"].name, nil)

    local loaded_again = contract_registry.build_indexed_map("tests.fake_registry.index", index, entries, "name", nil, nil, "github-devloop")
    t.eq(loaded_again["first-entry"].value, "a")
    t.eq(loaded_again["second-entry"].value, "b")
    t.eq(loaded_again["first-entry"].name, nil)
  end,

  test_indexed_array_rejects_unsorted_index = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.unsorted_registry.index", { "z", "a" }, {}, "name", nil, nil, "github-devloop")
    end, "not sorted")
  end,

  test_indexed_array_rejects_duplicate_index_entries = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.duplicate_registry.index", { "a", "a" }, {}, "name", nil, nil, "github-devloop")
    end, "duplicate registry index entry")
  end,

  test_indexed_array_rejects_entry_key_mismatch = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.mismatch_registry.index", {
        { module = "entry", key = "expected" },
      }, {
        { name = "actual" },
      }, "name", nil, nil, "github-devloop")
    end, "does not match index entry")
  end,

  test_contract_registry_rejects_unsorted_module_index = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.unsorted_reason_registry.index", {
        { module = "z_reason", key = "z-reason" },
        { module = "a_reason", key = "a-reason" },
      }, {
        { reason = "z-reason" },
        { reason = "a-reason" },
      }, "reason", nil, nil, "forge.merge")
    end, "not sorted")
  end,

  test_contract_registry_rejects_duplicate_module_index_entries = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.duplicate_reason_registry.index", {
        { module = "same_reason", key = "first-reason" },
        { module = "same_reason", key = "second-reason" },
      }, {
        { reason = "first-reason" },
        { reason = "second-reason" },
      }, "reason", nil, nil, "forge.merge")
    end, "duplicate registry index entry")
  end,

  test_contract_registry_rejects_missing_module_index_entry = function()
    expect_error_contains(function()
      contract_registry.build_indexed_array("tests.bad_reason_registry.index", {
        { key = "first-reason" },
      }, {
        { reason = "first-reason" },
      }, "reason", nil, nil, "forge.merge")
    end, "non-empty string")
  end,

  test_forge_reason_registry_uses_contract_registry = function()
    local source = file.read("libraries/forge/merge/shared.lua")
    t.is_true(source:find('require("contract.registry")', 1, true) ~= nil)
    t.eq(source:find("local function build_reason_class_map", 1, true), nil)
  end,
}
