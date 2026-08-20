local admission_department = require("departments.admission.main")
local replay_admission_department = require("departments.replay_admission.main")
local claim_carriers = require("devloop.claim_carriers")
local entity_lib = require("devloop.entity")
local m_claims = require("devloop.claims")
local dashboard = require("devloop.dashboard")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = h.t

local owner = "fkst-test-bot"

local function with_claim_mode(mode, fn)
  local previous = m_claims.claim_mode_active
  m_claims.claim_mode_active = function()
    return mode
  end
  local ok, result = pcall(fn)
  m_claims.claim_mode_active = previous
  if not ok then
    error(result, 0)
  end
  return result
end

local function observed_issue()
  local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
  return {
    queue = "github-proxy.github_issue_observed",
    payload = {
      schema = "github-proxy.issue-observed.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      updated_at = "2026-07-31T01:02:03Z",
      dedup_key = "github-issue-observed/owner/repo/42/2026-07-31T01:02:03Z/probe",
      source_ref = source_ref,
    },
    source_ref = source_ref,
  }
end

local function terminal_row()
  return {
    delivery_id = "terminal-one",
    queue = "github-devloop-intake.devloop_intake_candidate",
    dept = "github-devloop-intake-default.intake_judge",
    source = {
      kind = "external",
      reference = "owner/repo#issue/42",
    },
    attempts = 2,
    permanent = true,
    replayable = false,
  }
end

local function mock_claim_env(mode)
  local values = {
    FKST_GITHUB_BOT_LOGIN = owner,
    FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE = "",
    FKST_GITHUB_CLAIM_MODE = mode,
    FKST_GITHUB_WRITE = "",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
  }
  for name, value in pairs(values) do
    for _ = 1, 8 do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = value,
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function replay_department(labels, reconciled)
  return replay_admission_department.make_department({
    capacity = {
      authorize = function()
        return true, "replay-claim-mode-test-capacity"
      end,
      relinquish = function()
        error("intake replay must not relinquish capacity")
      end,
      reconcile = function()
        reconciled.count = reconciled.count + 1
        return true, "replay-claim-mode-test-reconcile"
      end,
    },
    read_current_issue = function()
      return "owner/repo", 42, {
        number = 42,
        title = "Replay label-mode issue",
        body = "",
        updated_at = "2026-07-31T01:02:03Z",
        state = "OPEN",
        labels = labels,
        comments = {},
        assignees = {},
      }, nil
    end,
  })
end

local function with_immediate_once(fn)
  local previous = _G.once
  _G.once = function(_key, effect)
    return effect()
  end
  local ok, result = pcall(fn)
  _G.once = previous
  if not ok then
    error(result, 0)
  end
  return result
end

local function changed_issue()
  local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      updated_at = "2026-07-31T01:02:03Z",
      dedup_key = "owner/repo#issue#42@2026-07-31T01:02:03Z",
      source_ref = source_ref,
    },
    source_ref = source_ref,
  }
end

local function label_mode_admission_department()
  return admission_department.make_department({
    capacity = {
      authorize = function()
        return true, "label-mode-test-capacity"
      end,
      relinquish = function()
        error("label-mode initial admission must not relinquish capacity")
      end,
      reconcile = function()
        error("label-mode initial admission must not reconcile capacity")
      end,
    },
    claims = {
      claim_admission_inputs = function()
        return {}
      end,
      claim_admission_precheck = function()
        return "claimed", "label-mode-test-claim"
      end,
      claim_issue_for_management = function()
        return true
      end,
      run_if_current_claim_admission_epoch = function(_detail, fn)
        fn()
        return true
      end,
    },
    read_current_issue = function()
      return "owner/repo", 42, {
        number = 42,
        title = "Hosted label-mode issue",
        body = "",
        updated_at = "2026-07-31T01:02:03Z",
        state = "OPEN",
        labels = { "fkst-dev:claimed", "fkst-class:expedite" },
        comments = {},
        assignees = {},
      }, nil
    end,
  })
end

return {
  test_replay_skips_dashboard_anchor_before_capacity_or_raise = function()
    h.mock_bot_env()
    local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
    t.mock_observe({
      terminal_dead_letter = {
        delivery_id = "terminal-dashboard-anchor",
        queue = "github-devloop-intake.devloop_intake_candidate",
        dept = "github-devloop-intake-default.intake_judge",
        source = { kind = "External", reference = "owner/repo#issue/42" },
        attempts = 1,
        permanent = true,
        replayable = false,
      },
    })
    local capacity_calls = 0
    local department = replay_admission_department.make_department({
      capacity = {
        authorize = function()
          capacity_calls = capacity_calls + 1
          return true, "unexpected-capacity-admission"
        end,
        reconcile = function() end,
      },
      read_current_issue = function()
        return "owner/repo", 42, {
          number = 42,
          title = dashboard.title,
          body = dashboard.marker("anchor", "2026-08-08T00:00:00Z"),
          updated_at = "2026-07-31T01:02:03Z",
          state = "OPEN",
          labels = {},
          comments = {},
          assignees = { "fkst-test-bot" },
        }, nil
      end,
    })

    local result = with_claim_mode("assignee", function()
      return testing.run_fake_outcome(department, observed_issue())
    end)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(capacity_calls, 0)
  end,

  test_label_claim_mode_replays_terminal_lineage_for_held_claim = function()
    mock_claim_env("label")
    local terminal = terminal_row()
    t.mock_observe({ terminal_dead_letter = terminal })
    local reconciled = { count = 0 }
    local result = with_immediate_once(function()
      return testing.run_fake_outcome(
        replay_department({ claim_carriers.derived_label(owner, 32) }, reconciled),
        observed_issue()
      )
    end)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "42")
    t.eq(reconciled.count, 0)
  end,

  test_label_claim_mode_refuses_replay_without_held_claim = function()
    mock_claim_env("label")
    t.mock_observe({ terminal_dead_letter = terminal_row() })
    local reconciled = { count = 0 }
    local result = testing.run_fake_outcome(replay_department({}, reconciled), observed_issue())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(reconciled.count, 1)
  end,

  test_label_claim_mode_preserves_initial_admission = function()
    local result = with_claim_mode("label", function()
      return testing.run_fake_outcome(label_mode_admission_department(), changed_issue())
    end)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "42")
  end,
}
