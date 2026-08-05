local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local github_fake = require("forge.github_fake")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local observe_commands = require("devloop.commands.observe_lists")
local queue_starvation = require("devloop.queue_starvation")
local observability = require("departments.observability.main")

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
end

local function with_fake_observability_reads(github, fn)
  local original_issue_list_observe_opts = observe_commands.gh_issue_list_observe_opts
  local original_pr_list_observe_opts = observe_commands.gh_pr_list_observe_opts
  local originals = {
    collect_recent_merged_prs = core.collect_recent_merged_prs,
    collect_recent_merged_issues = core.collect_recent_merged_issues,
    reap_orphan_prs = core.reap_orphan_prs,
    observe_conflict_hotspots = core.observe_conflict_hotspots,
    render_observability_dashboard = core.render_observability_dashboard,
    publish_observability_dashboard = core.publish_observability_dashboard,
    observability_topology_mermaid = core.observability_topology_mermaid,
    observe_queue_starvation = queue_starvation.observe_queue_starvation,
  }

  observe_commands.gh_issue_list_observe_opts = function(repo, label, page, include_headers)
    return {
      run = function(timeout)
        return github.issue_list_observe(repo, label, page, include_headers, timeout)
      end,
    }
  end
  observe_commands.gh_pr_list_observe_opts = function(repo, page, include_headers)
    return {
      run = function(timeout)
        return github.pr_list_observe(repo, page, include_headers, timeout)
      end,
    }
  end
  core.collect_recent_merged_prs = function() return {} end
  core.collect_recent_merged_issues = function() return {} end
  core.reap_orphan_prs = function() end
  core.observe_conflict_hotspots = function()
    return { facts = 0, hotspots = 0, raised = 0 }
  end
  core.render_observability_dashboard = function()
    return { hash = "issue-sweep-dedup", body = "issue sweep dedup" }
  end
  core.publish_observability_dashboard = function() return "dry-run" end
  core.observability_topology_mermaid = function() return nil end
  queue_starvation.observe_queue_starvation = function()
    return { action = "observed" }
  end

  local ok, result = pcall(fn)
  observe_commands.gh_issue_list_observe_opts = original_issue_list_observe_opts
  observe_commands.gh_pr_list_observe_opts = original_pr_list_observe_opts
  for name, original in pairs(originals) do
    if name == "observe_queue_starvation" then
      queue_starvation.observe_queue_starvation = original
    else
      core[name] = original
    end
  end
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_collect_observability_entities_sweeps_each_distinct_label_once = function()
    t.eq(devloop_state.state_label("dependency_wait"), "fkst-dev:ready")
    t.eq(devloop_state.state_label("ready"), "fkst-dev:ready")

    local expected_labels = {}
    local distinct_label_count = 0
    local function expect_label(label)
      if label ~= nil and expected_labels[label] == nil then
        expected_labels[label] = true
        distinct_label_count = distinct_label_count + 1
      end
    end
    expect_label(devloop_base._enabled_label)
    expect_label(devloop_base._hold_label)
    for _, state in ipairs(devloop_state.lifecycle_state_order()) do
      expect_label(devloop_state.state_label(state))
    end

    local model = github_fake.model()
    local github = github_fake.new(model)
    local swept_labels = {}
    github.issue_list_observe = function(repo, label, page, include_headers, timeout)
      table.insert(swept_labels, label)
      return { stdout = "[]\n", stderr = "", exit_code = 0 }
    end
    github.pr_list_observe = function()
      return { stdout = "[]\n", stderr = "", exit_code = 0 }
    end
    local department = observability.make_department({ github = github })

    mock_env()
    with_fake_observability_reads(github, function()
      testing.run_fake(department, {
        queue = "devloop_observe_tick",
        payload = {
          schema = "github-devloop.observe-tick.v1",
          tick = "issue-sweep-dedup",
        },
      })
    end)

    local sweep_count_by_label = {}
    for _, label in ipairs(swept_labels) do
      sweep_count_by_label[label] = (sweep_count_by_label[label] or 0) + 1
    end
    t.eq(sweep_count_by_label["fkst-dev:ready"], 1)
    t.eq(#swept_labels, distinct_label_count)
    for label in pairs(expected_labels) do
      t.eq(sweep_count_by_label[label], 1)
    end
  end,
}
