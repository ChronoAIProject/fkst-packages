local config = require("devloop.config")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local entity_highwater = require("devloop.entity_highwater")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local parsers_pr = require("devloop.parsers.pr")
local testing = require("testkit_internal.testing")
local observe_pr = require("departments.observe_pr.main")

local t = h.t
local repo = "owner/repo"
local pr_number = 3093
local source_ref = entity_lib.pr_source_ref(repo, pr_number)
local highwater_key = entity_highwater.key("github-devloop-pr/observe_pr", source_ref)
local view_cache_key = devloop_entity_view.entity_view_cache_key(repo, "pr", pr_number)

local function json_string(value)
  local encoded = tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
  return '"' .. encoded .. '"'
end

local function seed_cached_pr_view(updated_at)
  local stdout = entity_read_mocks.pr_view_stdout({
    repo = repo,
    number = pr_number,
    updated_at = updated_at,
  })
  cache_set(view_cache_key, '{"updated_at":' .. json_string(updated_at)
    .. ',"producer":"test","stdout":' .. json_string(stdout) .. "}")
end

local function count_pr_rest_reads()
  local expected = "gh api repos/" .. repo .. "/pulls/" .. pr_number
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):gsub("'", "") == expected then
      count = count + 1
    end
  end
  return count
end

local function version(number)
  local offset = number - 1
  local minute = math.floor(offset / 60)
  local second = offset % 60
  return string.format("2026-08-04T00:%02d:%02dZ", minute, second)
end

local function event(updated_at)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      title = "Observe latest PR",
      updated_at = updated_at,
      dedup_key = repo .. "#pr#" .. pr_number .. "@" .. updated_at,
      source_ref = source_ref,
    },
  }
end

return {
  test_observe_pr_skips_a_version_superseded_by_the_fetched_pr = function()
    local v432 = version(432)
    cache_set(highwater_key, "")
    seed_cached_pr_view(version(1))
    entity_read_mocks.mock_pr_read_forms(t, {
      repo = repo,
      number = pr_number,
      updated_at = v432,
      times = 1,
    })
    local cached = devloop_entity_view.fetch_pr_view_origin(repo, pr_number, version(1))
    t.is_true(cached.stdout:find('"updatedAt":"' .. version(1) .. '"', 1, true) ~= nil)
    t.eq(count_pr_rest_reads(), 0, "the test precondition must be a matching cached V1")

    local original_assert = parsers_misc.assert_trusted_bot_configured
    local original_branches = config.branch_config
    local original_parse = parsers_pr.parse_pr_view_origin
    parsers_misc.assert_trusted_bot_configured = function() end
    config.branch_config = function()
      return { upstream = "dev", integration = "dev" }
    end
    parsers_pr.parse_pr_view_origin = function(stdout)
      local current = original_parse(stdout)
      current.head_ref_name = nil
      current.base_ref_name = nil
      return current
    end

    local ok, err = pcall(function()
      testing.run_fake(observe_pr, event(version(1)))
      t.eq(count_pr_rest_reads(), 1, "the authority watermark read must bypass a matching cached validator")
      t.eq(cache_get(highwater_key), v432)
      for number = 2, 431 do
        testing.run_fake(observe_pr, event(version(number)))
      end
      t.eq(count_pr_rest_reads(), 1, "V2 through V431 must not fetch after V1 checkpoints current V432")
    end)
    parsers_pr.parse_pr_view_origin = original_parse
    config.branch_config = original_branches
    parsers_misc.assert_trusted_bot_configured = original_assert
    if not ok then
      error(err, 0)
    end
  end,
}
