local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local entity_highwater = require("devloop.entity_highwater")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local parsers_pr = require("devloop.parsers.pr")
local testing = require("testkit_internal.testing")
local observe_pr = require("departments.observe_pr.main")

local t = h.t
local repo = "owner/repo"
local pr_number = 3093
local source_ref = entity_lib.pr_source_ref(repo, pr_number)
local highwater_key = entity_highwater.key("github-devloop-pr/observe_pr", source_ref)

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
    local reads = 0
    cache_set(highwater_key, "")

    local original_assert = devloop_base.assert_trusted_bot_configured
    local original_branches = config.branch_config
    local original_fetch = devloop_entity_view.fetch_pr_view_origin
    local original_parse = parsers_pr.parse_pr_view_origin
    devloop_base.assert_trusted_bot_configured = function() end
    config.branch_config = function()
      return { upstream = "dev", integration = "dev" }
    end
    devloop_entity_view.fetch_pr_view_origin = function()
      reads = reads + 1
      return { stdout = "{}", stderr = "", exit_code = 0 }
    end
    parsers_pr.parse_pr_view_origin = function()
      return { state = "OPEN", updated_at = v432, labels = {}, comments = {} }
    end

    local ok, err = pcall(function()
      testing.run_fake(observe_pr, event(version(1)))
      for number = 2, 431 do
        testing.run_fake(observe_pr, event(version(number)))
      end
    end)
    parsers_pr.parse_pr_view_origin = original_parse
    devloop_entity_view.fetch_pr_view_origin = original_fetch
    config.branch_config = original_branches
    devloop_base.assert_trusted_bot_configured = original_assert
    if not ok then
      error(err, 0)
    end

    t.eq(reads, 1, "V1 fetching current V432 must make V2 through V431 zero-fetch no-ops")
    t.eq(cache_get(highwater_key), v432)
  end,
}
