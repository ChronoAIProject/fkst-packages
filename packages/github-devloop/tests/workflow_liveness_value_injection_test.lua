local t = fkst.test
local contract_time = require("contract.time")

local function install_shared(model, resolved)
  return require("workflow_internal.liveness.shared").install(model, resolved)
end

return {
  test_shared_signal_age_uses_contract_time_age_minutes = function()
    local original = contract_time.iso_timestamp_age_minutes
    contract_time.iso_timestamp_age_minutes = function(timestamp, now_seconds)
      t.eq(timestamp, "2026-08-12T01:00:00Z")
      t.eq(now_seconds, 17)
      return 23
    end
    local shared = install_shared({}, {
      liveness_signal_producers = {},
    })
    local ok, age = pcall(shared.signal_age_from_created_at, "2026-08-12T01:00:00Z", 17)
    contract_time.iso_timestamp_age_minutes = original
    if not ok then
      error(age, 0)
    end
    t.eq(age, 23)
  end,

  test_shared_uses_resolved_restart_package_name_value_for_defaulted_error_context = function()
    local ok, err = pcall(function()
      install_shared({}, {
        restart_package_name = "resolved-package",
      })
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("resolved-package: missing resolved liveness_signal_producers", 1, true) ~= nil, tostring(err))
  end,

  test_shared_uses_resolved_restart_source_root_value_for_source_contains = function()
    local shared = install_shared({}, {
      restart_source_root = "packages/github-devloop/",
      liveness_signal_producers = {},
    })

    t.eq(shared.source_contains("core.lua", "local restart_policy = wiring.restart_policy(restart_runtime)"), true)
  end,
}
