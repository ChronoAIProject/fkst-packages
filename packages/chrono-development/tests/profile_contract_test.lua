local core = require("core")
local t = fkst.test

local function list_contains(list, expected)
  if type(list) ~= "table" then
    return false
  end
  for _, value in ipairs(list) do
    if value == expected then
      return true
    end
  end
  return false
end

return {
  test_default_profile_declares_the_reused_devloop_family = function()
    local profile = core.default_profile()

    t.eq(profile.schema, "chrono-development.profile.v1")
    t.eq(profile.name, "chrono-development")
    t.eq(profile.owns, "company-development-department-profile")
    t.eq(profile.work_label, "fkst-dev")
    t.eq(profile.issue_lifecycle_owner, "github-devloop")

    local packages = profile.platform_packages
    t.eq(packages[1], "github-proxy")
    t.eq(packages[2], "consensus")
    t.eq(packages[3], "github-devloop-intake")
    t.eq(packages[4], "github-devloop-intake-default")
    t.eq(packages[5], "github-devloop-decompose")
    t.eq(packages[6], "github-devloop")
    t.eq(packages[7], "github-devloop-pr")
    t.eq(packages[8], "github-devloop-ops")
    t.eq(packages[9], "github-devloop-integration")
    t.eq(packages[10], "chrono-development")
  end,

  test_intake_is_scoped_to_fkst_dev_and_excludes_siblings = function()
    local scope = core.default_profile().intake_scope

    t.eq(scope.schema, "chrono-development.intake-scope.v1")
    t.eq(scope.enabled_label, "fkst-dev:enabled")
    t.eq(scope.poll_label_prefix_env, "FKST_GITHUB_PROXY_POLL_LABEL_PREFIX")
    t.eq(scope.poll_label_prefix, "fkst-dev:")

    t.is_true(list_contains(scope.excludes_sibling_labels, "fkst-security"))
    t.is_true(list_contains(scope.excludes_sibling_labels, "fkst-finance"))
    t.is_true(list_contains(scope.excludes_sibling_labels, "fkst-marketing"))
  end,

  test_profile_conformance_errors_is_empty_for_default_profile = function()
    local errors = core.profile_conformance_errors()
    t.eq(#errors, 0)
  end,

  test_validate_profile_rejects_missing_platform_package = function()
    local profile = core.default_profile()
    table.remove(profile.platform_packages, 2)
    local errors = core.validate_profile_errors(profile)
    t.is_true(#errors > 0)
  end,

  test_validate_profile_rejects_wrong_intake_prefix = function()
    local profile = core.default_profile()
    profile.intake_scope.poll_label_prefix = "fkst-security:"
    local errors = core.validate_profile_errors(profile)
    t.is_true(#errors > 0)
  end,
}
