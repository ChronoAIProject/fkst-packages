local authorization_cache = require("forge.github.authorization_cache")
local content_filter = require("forge.github.content_filter")
local t = fkst.test

local function with_now(clock, fn)
  local original_now = now
  now = function()
    return clock.value
  end
  local ok, result = pcall(fn)
  now = original_now
  if not ok then
    error(result, 0)
  end
  return result
end

local function reset_org(org)
  cache_set(authorization_cache.cache_key(org), "")
end

local function build_policy(org, fetch, repo_name)
  local env = {
    FKST_GITHUB_AUTHORIZE_ORG_MEMBERS = "1",
    FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS = "",
    FKST_GITHUB_REPO = org .. "/" .. tostring(repo_name or "repo"),
  }
  return content_filter.author_policy_from_options({
    bot_login = "fkst-test-bot",
    read_env = function(name)
      return env[name]
    end,
    github_handle = {
      api_paginate_slurp = fetch,
    },
  })
end

local function authorized(policy, login)
  return content_filter.is_authorized(login, content_filter.policy_whitelist(policy))
end

local function successful_member_fetch(counter, login)
  return function(path)
    counter.calls = counter.calls + 1
    counter.paths[#counter.paths + 1] = path
    return {
      stdout = '[[{"login":"' .. login .. '"}]]',
      stderr = "",
      exit_code = 0,
    }
  end
end

return {
  test_invalid_cache_inputs_expose_stable_error_classes = function()
    local cases = {
      {
        run = function()
          authorization_cache.cache_key("")
        end,
        error_class = "invalid-organization",
      },
      {
        run = function()
          authorization_cache.epoch_at(-1)
        end,
        error_class = "invalid-current-time",
      },
      {
        run = function()
          authorization_cache.get("cache-invalid-fetch-org", nil)
        end,
        error_class = "invalid-fetch-logins",
      },
    }

    for _, case in ipairs(cases) do
      local ok, err = pcall(case.run)
      t.eq(ok, false)
      t.is_true(tostring(err):find(
        "forge-github-authorization-cache: " .. case.error_class .. ":",
        1,
        true
      ) ~= nil)
    end
  end,

  test_authorization_epoch_changes_exactly_at_the_revocation_boundary = function()
    local bound = authorization_cache.REVOCATION_BOUND_SECONDS

    t.eq(authorization_cache.epoch_at(bound - 1), 0)
    t.eq(authorization_cache.epoch_at(bound), 1)
    t.eq(authorization_cache.epoch_at((2 * bound) - 1), 1)
  end,

  test_success_is_shared_across_independent_handles_in_one_epoch = function()
    local org = "cache-success-org"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 10 }
    local counter = { calls = 0, paths = {} }
    reset_org(org)

    with_now(clock, function()
      local first = build_policy(org, successful_member_fetch(counter, "first-member"), "first-repo")
      local second = build_policy(org, successful_member_fetch(counter, "second-member"), "second-repo")

      t.eq(authorized(first, "first-member"), true)
      t.eq(authorized(second, "first-member"), true)
      t.eq(authorized(second, "second-member"), false)
    end)

    t.eq(counter.calls, 1)
    t.eq(counter.paths[1], "orgs/" .. org .. "/members?per_page=100")
  end,

  test_unavailable_outcome_is_shared_without_becoming_an_empty_member_set = function()
    local org = "cache-unavailable-org"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 20 }
    local calls = 0
    reset_org(org)

    with_now(clock, function()
      local function unavailable_fetch()
        calls = calls + 1
        return { stdout = "", stderr = "rate limited", exit_code = 1 }
      end
      local first = build_policy(org, unavailable_fetch)
      local second = build_policy(org, successful_member_fetch({ calls = 0, paths = {} }, "later-member"))

      t.eq(authorized(first, "fkst-test-bot"), true)
      t.eq(authorized(first, "later-member"), false)
      t.eq(authorized(second, "later-member"), false)
    end)

    t.eq(calls, 1)
    local encoded = tostring(cache_get(authorization_cache.cache_key(org)) or "")
    t.is_true(encoded:find('"tag":"unavailable"', 1, true) ~= nil)
    t.is_true(encoded:find('"tag":"available"', 1, true) == nil)
  end,

  test_empty_member_set_is_cached_as_available = function()
    local org = "cache-empty-org"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 30 }
    local calls = 0
    reset_org(org)

    with_now(clock, function()
      local policy = build_policy(org, function()
        calls = calls + 1
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end)
      t.eq(authorized(policy, "unlisted-member"), false)
    end)

    t.eq(calls, 1)
    local encoded = tostring(cache_get(authorization_cache.cache_key(org)) or "")
    t.is_true(encoded:find('"tag":"available"', 1, true) ~= nil)
    t.is_true(encoded:find('"tag":"unavailable"', 1, true) == nil)
  end,

  test_unavailable_outcome_is_refetched_in_the_next_epoch = function()
    local org = "cache-unavailable-refresh-org"
    local bound = authorization_cache.REVOCATION_BOUND_SECONDS
    local clock = { value = (bound * 35) + bound - 1 }
    local calls = 0
    reset_org(org)

    with_now(clock, function()
      local first = build_policy(org, function()
        calls = calls + 1
        return { stdout = "", stderr = "rate limited", exit_code = 1 }
      end)
      t.eq(authorized(first, "restored-member"), false)

      clock.value = clock.value + 1
      local second = build_policy(org, function()
        calls = calls + 1
        return { stdout = '[[{"login":"restored-member"}]]', stderr = "", exit_code = 0 }
      end)
      t.eq(authorized(second, "restored-member"), true)
    end)

    t.eq(calls, 2)
  end,

  test_unexpected_fetch_error_is_exposed_and_not_cached = function()
    local org = "cache-fetch-error-org"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 38 }
    reset_org(org)

    with_now(clock, function()
      local ok, err = pcall(authorization_cache.get, org, function()
        error("unexpected-fetch-defect")
      end)

      t.eq(ok, false)
      t.is_true(tostring(err):find("unexpected-fetch-defect", 1, true) ~= nil)
    end)

    t.eq(cache_get(authorization_cache.cache_key(org)), "")
  end,

  test_next_authorization_epoch_refetches_membership = function()
    local org = "cache-refresh-org"
    local bound = authorization_cache.REVOCATION_BOUND_SECONDS
    local clock = { value = (bound * 40) + bound - 1 }
    local counter = { calls = 0, paths = {} }
    reset_org(org)

    with_now(clock, function()
      local first = build_policy(org, successful_member_fetch(counter, "old-member"))
      t.eq(authorized(first, "old-member"), true)

      clock.value = clock.value + 1
      local second = build_policy(org, successful_member_fetch(counter, "new-member"))
      t.eq(authorized(second, "old-member"), false)
      t.eq(authorized(second, "new-member"), true)
    end)

    t.eq(counter.calls, 2)
  end,

  test_cache_is_isolated_by_organization = function()
    local first_org = "cache-isolation-one"
    local second_org = "cache-isolation-two"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 50 }
    local counter = { calls = 0, paths = {} }
    reset_org(first_org)
    reset_org(second_org)

    with_now(clock, function()
      local first = build_policy(first_org, successful_member_fetch(counter, "first-member"))
      local second = build_policy(second_org, successful_member_fetch(counter, "second-member"))

      t.eq(authorized(first, "first-member"), true)
      t.eq(authorized(first, "second-member"), false)
      t.eq(authorized(second, "first-member"), false)
      t.eq(authorized(second, "second-member"), true)
    end)

    t.eq(counter.calls, 2)
  end,

  test_cold_miss_rechecks_the_cache_after_acquiring_the_lock = function()
    local org = "cache-single-flight-org"
    local clock = { value = authorization_cache.REVOCATION_BOUND_SECONDS * 60 }
    local counter = { calls = 0, paths = {} }
    local fetch = successful_member_fetch(counter, "shared-member")
    local original_with_lock = with_lock
    local competing_policy = nil
    local injected = false
    local replacement
    reset_org(org)

    replacement = function(key, fn)
      if not injected then
        injected = true
        with_lock = original_with_lock
        competing_policy = build_policy(org, fetch)
        with_lock = replacement
      end
      return original_with_lock(key, fn)
    end

    with_lock = replacement
    local ok, first_policy = pcall(function()
      return with_now(clock, function()
        return build_policy(org, fetch)
      end)
    end)
    with_lock = original_with_lock
    if not ok then
      error(first_policy, 0)
    end

    t.eq(authorized(first_policy, "shared-member"), true)
    t.eq(authorized(competing_policy, "shared-member"), true)
    t.eq(counter.calls, 1)
  end,
}
