local devloop_base = require("devloop.base")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local entity_lib = require("devloop.entity")
local github_author_policy = require("devloop.github_author_policy")
local h = require("tests.devloop_helpers")
local liveness_scan = require("devloop.liveness_scan")
local parsers_issue = require("devloop.parsers.issue")
local sweep_bounds = require("devloop.sweep_bounds")
local testing = require("testkit_internal.testing")

local department = require("departments.liveness_scan.main")
local t = h.t

local repo = "owner/liveness-scan-fairness"
local cursor_key = liveness_scan.liveness_scan_cursor_key(
  repo,
  "github-devloop/liveness-scan/issue-cursor/"
)

local function with_patches(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.key]
    patch.target[patch.key] = patch.value
  end
  local ok, result = pcall(fn)
  for index = #patches, 1, -1 do
    local patch = patches[index]
    patch.target[patch.key] = originals[index]
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local function issue_items(numbers)
  local items = {}
  for _, number in ipairs(numbers or { 1, 2, 3 }) do
    table.insert(items, {
      number = number,
      state = "open",
      updated_at = "2026-07-30T01:00:00Z",
    })
  end
  return items
end

return {
  test_under_cap_partial_ticks_resist_append_churn = function()
    local viewed = {}
    local reinjected = {}
    local budget_checks = 0
    local list_calls = 0
    cache_set(cursor_key, "v1/3/4")

    with_patches({
      {
        target = devloop_base,
        key = "assert_trusted_bot_configured",
        value = function() end,
      },
      {
        target = liveness_scan,
        key = "liveness_scan_read_repo",
        value = function()
          return repo
        end,
      },
      {
        target = liveness_scan,
        key = "liveness_scan_list_open_issues",
        value = function()
          list_calls = list_calls + 1
          local numbers = { 2 }
          for number = 4, 3 + list_calls do
            table.insert(numbers, number)
          end
          return issue_items(numbers), nil
        end,
      },
      {
        target = devloop_entity_view,
        key = "fetch_issue_view_state",
        value = function(_, number)
          table.insert(viewed, tonumber(number))
          return { stdout = "{}", stderr = "", exit_code = 0 }
        end,
      },
      {
        target = parsers_issue,
        key = "parse_issue_view_state",
        value = function()
          return { author_login = "trusted-author", state = "OPEN", comments = {} }
        end,
      },
      {
        target = github_author_policy,
        key = "from_handle_policy",
        value = function()
          return {}
        end,
      },
      {
        target = github_author_policy,
        key = "is_authorized",
        value = function()
          return true
        end,
      },
      {
        target = entity_lib,
        key = "current_entity_state",
        value = function(_, proposal_id)
          return { state = "implementing", proposal_id = proposal_id, version = "implementing/v1" }
        end,
      },
      {
        target = liveness_scan,
        key = "liveness_scan_should_reinject_state",
        value = function()
          return true
        end,
      },
      {
        target = liveness_scan,
        key = "liveness_scan_maybe_timeout_action",
        value = function()
          return nil
        end,
      },
      {
        target = liveness_scan,
        key = "liveness_scan_reinject",
        value = function(_, entity)
          table.insert(reinjected, tonumber(entity.number))
        end,
      },
      {
        target = sweep_bounds,
        key = "sweep_has_budget",
        value = function()
          budget_checks = budget_checks + 1
          return budget_checks <= 2
        end,
      },
    }, function()
      for tick = 1, 4 do
        budget_checks = 0
        local outcome = testing.run_fake(department, {
          queue = "github-devloop.devloop_liveness_tick",
          payload = { schema = "github-devloop.tick.v1" },
          ts = "tick-" .. tostring(tick),
        })
        t.eq(outcome.failure, nil)
      end
    end)

    t.eq(viewed[1], 4)
    t.eq(viewed[2], 2)
    for index = 1, 4 do
      t.eq(reinjected[index], viewed[index])
    end
  end,
}
