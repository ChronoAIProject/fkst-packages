local t = fkst.test

local function run_department_with_logs(path, event)
  local result = t.run_department(path, event)
  t.is_true(type(result) == "table")
  return result.exit_code == 0, tostring(result.error or ""), table.concat({
    tostring(result.error or ""),
  }, "\n")
end

return {
  test_scan_accepts_production_namespaced_queue = function()
    local ok, err, logs = run_department_with_logs("departments/external_pr_intake/main.lua", {
      queue = "github-external-pr-intake.external_pr_scan",
      payload = {
        schema = "github-external-pr-intake.v1",
      },
    })
    local text = tostring(err or "") .. "\n" .. tostring(logs or "")

    t.eq(ok, false)
    t.is_true(text:find("FKST_GITHUB_REPO is required", 1, true) ~= nil)
    t.is_nil(text:find("unsupported event payload", 1, true))
    t.is_nil(text:find("skip-foreign", 1, true))
  end,

  test_candidate_non_table_payload_fails_closed = function()
    local ok, err, logs = run_department_with_logs("departments/external_pr_intake/main.lua", {
      queue = "external_pr_candidate",
      payload = "foreign-payload",
    })
    local text = tostring(err or "") .. "\n" .. tostring(logs or "")

    t.eq(ok, false)
    t.is_true(text:find("invalid-payload", 1, true) ~= nil)
    t.is_nil(text:find("skip-foreign", 1, true))
  end,
}
