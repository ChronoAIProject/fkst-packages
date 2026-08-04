local devloop_base = require("devloop.base")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local base_ids = require("devloop.base_ids")
local entity_highwater = require("devloop.entity_highwater")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local m_facts = require("devloop.markers.facts")
local parsers_issue = require("devloop.parsers.issue")
local parsers_pr = require("devloop.parsers.pr")
local testing = require("testkit_internal.testing")
local observe_issue = require("departments.observe_issue.main")

local t = h.t
local repo = "owner/repo"
local issue_number = 3093
local source_ref = entity_lib.issue_source_ref(repo, issue_number)
local highwater_key = entity_highwater.key("github-devloop/observe_issue", source_ref)

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
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Observe latest issue",
      updated_at = updated_at,
      dedup_key = repo .. "#issue#" .. issue_number .. "@" .. updated_at,
      source_ref = source_ref,
    },
  }
end

local function pr_event(number, updated_at)
  local pr_ref = entity_lib.pr_source_ref(repo, number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = number,
      title = "Observe latest child PR",
      state = "OPEN",
      updated_at = updated_at,
      dedup_key = repo .. "#pr#" .. number .. "@" .. updated_at,
      source_ref = pr_ref,
    },
  }
end

return {
  test_observe_issue_skips_a_version_superseded_by_the_fetched_issue = function()
    local v432 = version(432)
    local reads = 0
    cache_set(highwater_key, "")

    local original_assert = devloop_base.assert_trusted_bot_configured
    local original_fetch = devloop_entity_view.fetch_issue_view_state
    local original_parse = parsers_issue.parse_issue_view_state
    devloop_base.assert_trusted_bot_configured = function() end
    devloop_entity_view.fetch_issue_view_state = function()
      reads = reads + 1
      return { stdout = "{}", stderr = "", exit_code = 0 }
    end
    parsers_issue.parse_issue_view_state = function()
      return { state = "CLOSED", updated_at = v432, labels = {}, comments = {}, assignees = {} }
    end

    local ok, err = pcall(function()
      testing.run_fake(observe_issue, event(version(1)))
      for number = 2, 431 do
        testing.run_fake(observe_issue, event(version(number)))
      end
    end)
    parsers_issue.parse_issue_view_state = original_parse
    devloop_entity_view.fetch_issue_view_state = original_fetch
    devloop_base.assert_trusted_bot_configured = original_assert
    if not ok then
      error(err, 0)
    end

    t.eq(reads, 1, "V1 fetching current V432 must make V2 through V431 zero-fetch no-ops")
    t.eq(cache_get(highwater_key), v432)
  end,

  test_observe_issue_checkpoints_a_child_pr_without_advancing_its_parent_issue = function()
    local pr_number = 3094
    local parent_number = 3095
    local v432 = version(432)
    local pr_key = entity_highwater.key(
      "github-devloop/observe_issue",
      entity_lib.pr_source_ref(repo, pr_number)
    )
    local parent_key = entity_highwater.key(
      "github-devloop/observe_issue",
      entity_lib.issue_source_ref(repo, parent_number)
    )
    cache_set(pr_key, "")
    cache_set(parent_key, "")
    local pr_reads = 0
    local issue_reads = 0

    local original_assert = devloop_base.assert_trusted_bot_configured
    local original_fetch_issue = devloop_entity_view.fetch_issue_view_state
    local original_fetch_pr = devloop_entity_view.fetch_pr_view_origin
    local original_origin = m_facts.pr_origin_fact
    local original_parse_issue = parsers_issue.parse_issue_view_state
    local original_parse_pr = parsers_pr.parse_pr_view_origin
    devloop_base.assert_trusted_bot_configured = function() end
    devloop_entity_view.fetch_pr_view_origin = function()
      pr_reads = pr_reads + 1
      return { stdout = "{}", stderr = "", exit_code = 0 }
    end
    devloop_entity_view.fetch_issue_view_state = function()
      issue_reads = issue_reads + 1
      return { stdout = "{}", stderr = "", exit_code = 0 }
    end
    parsers_pr.parse_pr_view_origin = function()
      return {
        state = "OPEN",
        updated_at = v432,
        comments = {},
        head_ref_name = "fix/entity-highwater",
        base_ref_name = "dev",
      }
    end
    parsers_issue.parse_issue_view_state = function()
      return { state = "CLOSED", updated_at = v432, labels = {}, comments = {}, assignees = {} }
    end
    m_facts.pr_origin_fact = function()
      return {
        proposal_id = base_ids.proposal_id(repo, parent_number),
        repo = repo,
        issue_number = parent_number,
        branch = "fix/entity-highwater",
        base_branch = "dev",
      }
    end

    local ok, err = pcall(function()
      testing.run_fake(observe_issue, pr_event(pr_number, version(1)))
      for number = 2, 431 do
        testing.run_fake(observe_issue, pr_event(pr_number, version(number)))
      end
    end)
    m_facts.pr_origin_fact = original_origin
    parsers_pr.parse_pr_view_origin = original_parse_pr
    parsers_issue.parse_issue_view_state = original_parse_issue
    devloop_entity_view.fetch_pr_view_origin = original_fetch_pr
    devloop_entity_view.fetch_issue_view_state = original_fetch_issue
    devloop_base.assert_trusted_bot_configured = original_assert
    if not ok then
      error(err, 0)
    end

    t.eq(pr_reads, 1, "V1 fetching current V432 must make V2 through V431 zero-fetch no-ops")
    t.eq(issue_reads, 1)
    t.eq(cache_get(pr_key), v432)
    t.eq(cache_get(parent_key), "")
  end,
}
