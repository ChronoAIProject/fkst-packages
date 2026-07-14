local M = {}

-- chrono-development is the DEVELOPMENT department of an fkst "company" session.
-- It owns NO issue->PR->merge lifecycle code of its own; it is a composed PROFILE
-- that reuses the existing github-devloop package family (modeled on frontend-devloop).
-- Its whole job is a declarative composition contract plus the label-scoping wiring
-- that binds that reused family to THIS department's work label, `fkst-dev`, while
-- leaving sibling departments (`fkst-security` / `fkst-finance` / `fkst-marketing`)
-- untouched.

-- The department's work label. Sibling company departments each own a distinct label.
local work_label = "fkst-dev"

-- The devloop family opts a repo issue into the lifecycle via this label
-- (libraries/devloop/base.lua: enabled_label = "fkst-dev:enabled"; is_opted_in scans
-- issue labels for exactly this string). All lifecycle state labels share the
-- `fkst-dev:` prefix (libraries/devloop/state.lua).
local enabled_label = "fkst-dev:enabled"

-- Intake is scoped at the github-proxy poll boundary to the `fkst-dev:` label prefix.
-- github-proxy/core.lua reads FKST_GITHUB_PROXY_POLL_LABEL_PREFIX
-- (github_proxy_poll_label_prefixes) and only treats issues carrying a matching label
-- prefix as intake candidates. Setting it to `fkst-dev:` EXCLUDES the sibling
-- department labels below, so this department never contends with them in one session.
local poll_label_prefix_env = "FKST_GITHUB_PROXY_POLL_LABEL_PREFIX"
local poll_label_prefix = "fkst-dev:"

-- Sibling company-department labels this profile must NOT act on. Listed so the
-- conformance contract can assert the `fkst-dev:` prefix scoping excludes them.
local sibling_labels = {
  "fkst-security",
  "fkst-finance",
  "fkst-marketing",
}

-- The reused platform package family that provides the full issue->PR->review->merge
-- loop. chrono-development composes these via [event_deps].packages; it does not clone
-- their departments. Mirrors frontend-devloop's platform_packages list.
local platform_packages = {
  "github-proxy",
  "consensus",
  "github-devloop-intake",
  "github-devloop-intake-default",
  "github-devloop-decompose",
  "github-devloop",
  "github-devloop-pr",
  "github-devloop-ops",
  "github-devloop-integration",
  "chrono-development",
}

local function cloned(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i]
  end
  return out
end

local function includes(list, expected)
  if type(list) ~= "table" then
    return false
  end
  for i = 1, #list do
    if list[i] == expected then
      return true
    end
  end
  return false
end

function M.work_label()
  return work_label
end

function M.enabled_label()
  return enabled_label
end

function M.poll_label_prefix_env()
  return poll_label_prefix_env
end

function M.poll_label_prefix()
  return poll_label_prefix
end

function M.sibling_labels()
  return cloned(sibling_labels)
end

function M.platform_packages()
  return cloned(platform_packages)
end

-- The declarative composition + intake-scoping contract for this department.
function M.default_profile()
  return {
    schema = "chrono-development.profile.v1",
    name = "chrono-development",
    owns = "company-development-department-profile",
    work_label = work_label,
    issue_lifecycle_owner = "github-devloop",
    platform_packages = M.platform_packages(),
    intake_scope = {
      schema = "chrono-development.intake-scope.v1",
      -- opt-in label the devloop family requires on an issue before it acts
      enabled_label = enabled_label,
      -- github-proxy poll boundary env + value that fences intake to this department
      poll_label_prefix_env = poll_label_prefix_env,
      poll_label_prefix = poll_label_prefix,
      excludes_sibling_labels = cloned(sibling_labels),
      rationale = "Scoping github-proxy polling to the `fkst-dev:` label prefix, plus the "
        .. "devloop family's `fkst-dev:enabled` opt-in, confines this department to "
        .. "fkst-dev-scoped issues and never touches sibling company departments.",
    },
    non_scope = {
      "GitHub issue lifecycle state machine (owned by github-devloop)",
      "PR review + merge orchestration (owned by github-devloop-pr / github-devloop-ops)",
      "any sibling company department's work label",
    },
  }
end

local function require_field(profile, field, ctx, errors)
  if profile[field] == nil or profile[field] == "" then
    table.insert(errors, ctx .. ": missing " .. field)
    return false
  end
  return true
end

-- Validate a profile table, returning a list of error strings (empty = valid).
function M.validate_profile_errors(profile)
  local ctx = "chrono-development: invalid-profile"
  local errors = {}
  if type(profile) ~= "table" then
    return { ctx .. ": profile must be a table" }
  end
  if profile.schema ~= "chrono-development.profile.v1" then
    table.insert(errors, ctx .. ": unsupported schema")
  end
  if profile.name ~= "chrono-development" then
    table.insert(errors, ctx .. ": unsupported name")
  end
  if profile.work_label ~= work_label then
    table.insert(errors, ctx .. ": work_label must be " .. work_label)
  end
  if profile.issue_lifecycle_owner ~= "github-devloop" then
    table.insert(errors, ctx .. ": issue lifecycle owner must be github-devloop")
  end
  local packages = profile.platform_packages
  if type(packages) ~= "table" then
    table.insert(errors, ctx .. ": missing platform_packages")
  else
    for _, package_name in ipairs(platform_packages) do
      if not includes(packages, package_name) then
        table.insert(errors, ctx .. ": platform_packages missing " .. package_name)
      end
    end
  end
  local scope = profile.intake_scope
  if type(scope) ~= "table" then
    table.insert(errors, ctx .. ": missing intake_scope")
  else
    if scope.enabled_label ~= enabled_label then
      table.insert(errors, ctx .. ": intake_scope.enabled_label must be " .. enabled_label)
    end
    if scope.poll_label_prefix_env ~= poll_label_prefix_env then
      table.insert(errors, ctx .. ": intake_scope.poll_label_prefix_env must be " .. poll_label_prefix_env)
    end
    if scope.poll_label_prefix ~= poll_label_prefix then
      table.insert(errors, ctx .. ": intake_scope.poll_label_prefix must be " .. poll_label_prefix)
    end
    for _, sibling in ipairs(sibling_labels) do
      if not includes(scope.excludes_sibling_labels, sibling) then
        table.insert(errors, ctx .. ": intake_scope must exclude sibling label " .. sibling)
      end
      -- The fkst-dev prefix must not accidentally match a sibling label.
      if sibling:sub(1, #poll_label_prefix) == poll_label_prefix then
        table.insert(errors, ctx .. ": poll_label_prefix must not match sibling label " .. sibling)
      end
    end
    require_field(scope, "rationale", ctx .. ": intake_scope", errors)
  end
  return errors
end

-- fkst.toml conformance hook: function = "core.profile_conformance_errors".
-- Returns a list of error strings (empty = pass).
function M.profile_conformance_errors()
  return M.validate_profile_errors(M.default_profile())
end

return M
