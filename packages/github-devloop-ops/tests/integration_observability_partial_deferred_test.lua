local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local testing = require("testkit_internal.testing")
local failure_triage_cap = require("failure_triage_cap")
local queue_starvation = require("devloop.queue_starvation")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
require("departments.observability.main")

local function mock_env()
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
  end
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  end
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    t.mock_command('if [ -n "${' .. name .. ':-}" ]; then printf present; fi', { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function issue_list_first(label)
  return core.gh_issue_list_observe_cmd("owner/repo", label, 1, true)
end

local function run_pipeline()
  local old_pipeline = pipeline
  local module = require("departments.observability.main")
  local run = module.pipeline or pipeline
  pipeline = old_pipeline
  if type(run) ~= "function" then error("github-devloop: observability department pipeline missing") end
  run({ queue = "devloop_observe_tick", payload = { schema = "github-devloop.observe-tick.v1" } })
end

local function capture_logs()
  local captured = {}
  local old_log = log
  log = {
    info = function(message) table.insert(captured, tostring(message)) end,
    warn = function(message) table.insert(captured, tostring(message)) end,
    error = function(message) table.insert(captured, tostring(message)) end,
  }
  local ok, err = pcall(run_pipeline)
  log = old_log
  if not ok then error(err) end
  return table.concat(captured, "\n")
end

return {
  test_display_read_timeout_renders_partial_observability_dashboard = function()
    mock_env()
    t.mock_command(issue_list_first(core._enabled_label), { stdout = "", stderr = "timed out", exit_code = 124 })
    for _, state in ipairs(core.issue_state_order()) do
      t.mock_command(issue_list_first(core.state_label(state)), { stdout = "[]\n", stderr = "", exit_code = 0 })
    end
    t.mock_command(core.gh_pr_list_observe_cmd("owner/repo", 1, true), { stdout = "[]\n", stderr = "", exit_code = 0 })
    t.mock_command(core.gh_pr_list_recent_merged_cmd("owner/repo", core.observability_limits().entity_cap), { stdout = "[]\n", stderr = "", exit_code = 0 })
    t.mock_command(core.gh_issue_list_recent_closed_cmd("owner/repo", core.observability_limits().entity_cap), { stdout = "[]\n", stderr = "", exit_code = 0 })

    local logs = capture_logs()

    t.is_true(logs:find("tag=OBSERVE_READ_DEFERRED reason=timeout", 1, true) ~= nil)
    t.is_true(logs:find("tag=OBSERVE_DEFERRED reason=timeout", 1, true) ~= nil)
    t.is_true(logs:find("## Partial observations", 1, true) ~= nil)
    t.is_true(logs:find("- reason=timeout", 1, true) ~= nil)
  end,

  test_partial_observations_do_not_drive_control_effects = function()
    mock_env()
    local department = require("departments.observability.main")
    local calls = {
      reaper = 0,
      queue_starvation = 0,
      blocked_obligation_patrol = 0,
      conflict_hotspot = 0,
      render = 0,
      publish = 0,
    }
    local originals = {
      collect_observability_entities = core.collect_observability_entities,
      collect_recent_merged_prs = core.collect_recent_merged_prs,
      collect_recent_merged_issues = core.collect_recent_merged_issues,
      reap_orphan_prs = core.reap_orphan_prs,
      observe_conflict_hotspots = core.observe_conflict_hotspots,
      render_observability_dashboard = core.render_observability_dashboard,
      publish_observability_dashboard = core.publish_observability_dashboard,
      observability_topology_mermaid = core.observability_topology_mermaid,
      observe_queue_starvation = queue_starvation.observe_queue_starvation,
      blocked_obligation_patrol_once = failure_triage_cap.blocked_obligation_patrol_once,
    }

    core.collect_observability_entities = function()
      return {
        list = {
          {
            proposal_id = "github-devloop/issue/owner/repo/42",
            repo = "owner/repo",
            number = 42,
            comments = {},
            current_state = { state = "blocked" },
          },
        },
        counts = { blocked = 1 },
        stalls = {},
        state_gap_report = { edges = {} },
        now_seconds = now(),
        observability_deferred = { reason = "timeout" },
      }
    end
    core.collect_recent_merged_prs = function() return {} end
    core.collect_recent_merged_issues = function() return {} end
    core.reap_orphan_prs = function() calls.reaper = calls.reaper + 1 end
    queue_starvation.observe_queue_starvation = function()
      calls.queue_starvation = calls.queue_starvation + 1
      return { action = "called" }
    end
    failure_triage_cap.blocked_obligation_patrol_once = function()
      calls.blocked_obligation_patrol = calls.blocked_obligation_patrol + 1
      return {
        {
          queue = "github-proxy.github_issue_create_request",
          payload = { schema = "github-proxy.issue-create.v1" },
          fact = { proposal_id = "github-devloop/issue/owner/repo/42" },
        },
      }
    end
    core.observe_conflict_hotspots = function()
      calls.conflict_hotspot = calls.conflict_hotspot + 1
      return { facts = 1, hotspots = 1, raised = 1 }
    end
    core.render_observability_dashboard = function(args)
      calls.render = calls.render + 1
      t.eq(args.observability_deferred.reason, "timeout")
      return { hash = "partial-dashboard", body = "partial dashboard" }
    end
    core.publish_observability_dashboard = function()
      calls.publish = calls.publish + 1
      return "dry-run"
    end
    core.observability_topology_mermaid = function() return nil end

    local ok, result = pcall(function()
      return testing.run_fake(department, {
        queue = "devloop_observe_tick",
        payload = { schema = "github-devloop.observe-tick.v1" },
      })
    end)
    for name, original in pairs(originals) do
      if name == "observe_queue_starvation" then
        queue_starvation.observe_queue_starvation = original
      elseif name == "blocked_obligation_patrol_once" then
        failure_triage_cap.blocked_obligation_patrol_once = original
      else
        core[name] = original
      end
    end
    if not ok then error(result) end

    t.eq(calls.reaper, 0)
    t.eq(calls.queue_starvation, 0)
    t.eq(calls.blocked_obligation_patrol, 0)
    t.eq(calls.conflict_hotspot, 0)
    t.eq(calls.render, 1)
    t.eq(calls.publish, 1)
    t.eq(#result.raises, 0)
  end,

  test_incomplete_recent_merged_gates_patrol_without_gating_complete_census = function()
    mock_env()
    local department = require("departments.observability.main")
    local calls = { reaper = 0, queue_starvation = 0, blocked_obligation_patrol = 0 }
    local originals = {
      collect_observability_entities = core.collect_observability_entities,
      collect_recent_merged_prs = core.collect_recent_merged_prs,
      collect_recent_merged_issues = core.collect_recent_merged_issues,
      reap_orphan_prs = core.reap_orphan_prs,
      observe_conflict_hotspots = core.observe_conflict_hotspots,
      render_observability_dashboard = core.render_observability_dashboard,
      publish_observability_dashboard = core.publish_observability_dashboard,
      observability_topology_mermaid = core.observability_topology_mermaid,
      observe_queue_starvation = queue_starvation.observe_queue_starvation,
      blocked_obligation_patrol_once = failure_triage_cap.blocked_obligation_patrol_once,
    }

    -- Census is COMPLETE (no observability_deferred): the census-partial bulkhead
    -- must NOT fire, so reap/queue_starvation run normally.
    core.collect_observability_entities = function()
      return {
        list = {
          {
            proposal_id = "github-devloop/issue/owner/repo/42",
            repo = "owner/repo",
            number = 42,
            comments = {},
            current_state = { state = "blocked" },
          },
        },
        counts = { blocked = 1 },
        stalls = {},
        state_gap_report = { edges = {} },
        now_seconds = now(),
        observability_deferred = nil,
      }
    end
    -- recent-merged issue scan is INCOMPLETE (a per-issue view timed out mid-scan),
    -- so collect_recent_merged_issues returns nil. A partial recent-merged list must
    -- NOT drive the drain-edge patrol (absence-of-evidence != evidence-of-absence),
    -- which would otherwise raise a spurious github_issue_create_request (#2432/#2441).
    core.collect_recent_merged_prs = function() return {} end
    core.collect_recent_merged_issues = function() return nil end
    core.reap_orphan_prs = function() calls.reaper = calls.reaper + 1 end
    queue_starvation.observe_queue_starvation = function()
      calls.queue_starvation = calls.queue_starvation + 1
      return { action = "called" }
    end
    failure_triage_cap.blocked_obligation_patrol_once = function()
      calls.blocked_obligation_patrol = calls.blocked_obligation_patrol + 1
      return {
        {
          queue = "github-proxy.github_issue_create_request",
          payload = { schema = "github-proxy.issue-create.v1" },
          fact = { proposal_id = "github-devloop/issue/owner/repo/42" },
        },
      }
    end
    core.observe_conflict_hotspots = function() return { facts = 0, hotspots = 0, raised = 0 } end
    core.render_observability_dashboard = function() return { hash = "x", body = "x" } end
    core.publish_observability_dashboard = function() return "dry-run" end
    core.observability_topology_mermaid = function() return nil end

    local ok, result = pcall(function()
      return testing.run_fake(department, {
        queue = "devloop_observe_tick",
        payload = { schema = "github-devloop.observe-tick.v1" },
      })
    end)
    for name, original in pairs(originals) do
      if name == "observe_queue_starvation" then
        queue_starvation.observe_queue_starvation = original
      elseif name == "blocked_obligation_patrol_once" then
        failure_triage_cap.blocked_obligation_patrol_once = original
      else
        core[name] = original
      end
    end
    if not ok then error(result) end

    -- Census complete: reap + queue_starvation run.
    t.eq(calls.reaper, 1)
    t.eq(calls.queue_starvation, 1)
    -- Incomplete recent-merged gates the drain-edge patrol: no spurious escalation.
    t.eq(calls.blocked_obligation_patrol, 0)
    t.eq(#result.raises, 0)
  end,

  test_collect_recent_merged_issues_returns_nil_when_a_view_times_out = function()
    mock_env()
    -- Direct reproduction of the fidelity blocker: without the fix, a per-issue view
    -- timeout mid-scan returns a PARTIAL (non-nil) recent-merged list, which drives the
    -- drain-edge patrol on incomplete data. The fix returns nil on an incomplete scan.
    local selector = "title,body,comments,state,stateReason,assignees,author"
    entity_read_mocks.mock_issue_list_command(t, core.gh_issue_list_recent_closed_cmd("owner/repo", core.observability_limits().entity_cap), {
      { number = 1001, title = "merged A", closed_at = "2026-06-29T03:44:36Z", labels = { "fkst-dev:enabled", "fkst-dev:merged" } },
      { number = 1002, title = "merged B", closed_at = "2026-06-29T03:45:00Z", labels = { "fkst-dev:enabled", "fkst-dev:merged" } },
    })
    entity_read_mocks.mock_issue_view_raw_selector(t, { repo = "owner/repo", number = 1001 }, selector, {
      stdout = "", stderr = "timed out", exit_code = 124,
    })

    local result = core.collect_recent_merged_issues("owner/repo", core.observability_limits(), now() + 90)

    -- Incomplete scan -> nil (not a partial list that would fool completeness checks).
    t.eq(result, nil)
  end,

  test_observability_result_timeout_uses_timed_out_ground_truth = function()
    -- Engine timed_out field is authoritative when present.
    t.is_true(core.observability_result_timeout({ timed_out = true, exit_code = 124 }) == true)
    -- A genuine failure that reports timed_out=false must NOT be treated as a timeout,
    -- even if it exits 124 -- it must fail-close.
    t.is_true(core.observability_result_timeout({ timed_out = false, exit_code = 124 }) == false)
    -- Fallback (field absent, e.g. current fkst.test mock): exit 124 is a timeout.
    t.is_true(core.observability_result_timeout({ exit_code = 124 }) == true)
    t.is_true(core.observability_result_timeout({ exit_code = 1 }) == false)
  end,
}
