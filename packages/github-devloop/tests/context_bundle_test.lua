local h = require("tests.devloop_core_helpers")
require("tests.context_bundle_probe_helpers")
local core = h.core
local t = h.t

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/github-devloop-context-bundle/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function run_probe(mode, root)
  local result = t.run_department("tests/context_bundle_probe_helpers.lua", {
    queue = "context_bundle_probe",
    payload = {
      mode = mode,
      root = root,
    },
  }, {
    env = {
      FKST_RUNTIME_ROOT = root,
    },
  })
  t.eq(result.exit_code, 0)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "context_bundle_probe_result" then
      return raised.payload
    end
  end
  error("missing context bundle probe result")
end

return {
  test_context_bundle_files_round_trip_from_different_cwd = function()
    local result = run_probe("round_trip", runtime_root("round-trip"))

    t.eq(#result.paths, 4)
    for _, content in ipairs(result.contents) do
      t.is_true(content:find(core._untrusted_issue_data_begin .. "\n", 1, true) == 1)
    end
  end,

  test_context_bundle_cache_hit_with_deleted_file_rebuilds = function()
    local result = run_probe("deleted_file", runtime_root("deleted-file"))

    t.eq(result.first_dir, result.second_dir)
    t.is_true(result.issue_content:find("Second issue", 1, true) ~= nil)
    t.eq(result.issue_fetch_count, 2)
  end,

  test_context_bundle_reuses_preexisting_final_dir_after_validation = function()
    local result = run_probe("preexisting", runtime_root("preexisting-final"))

    t.eq(result.dir, result.expected_dir)
    t.is_true(result.issue_content:find("preexisting issue", 1, true) ~= nil)
    t.eq(result.issue_fetch_count, 0)
  end,
}
