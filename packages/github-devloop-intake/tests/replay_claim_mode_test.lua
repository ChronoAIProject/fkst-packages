local admission_department = require("departments.admission.main")
local replay_admission_department = require("departments.replay_admission.main")
local entity_lib = require("devloop.entity")
local m_claims = require("devloop.claims")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = h.t

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
      authorize_reintake = function()
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
      with_current_claim_admission_epoch = function(_detail, fn)
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
  test_label_claim_mode_skips_impossible_intake_replay_before_observe = function()
    local observe_calls = 0
    local previous_observe = fkst.observe
    fkst.observe = function()
      observe_calls = observe_calls + 1
      error("label-mode replay must not inspect delivery facts")
    end
    local ok, result = pcall(function()
      return with_claim_mode("label", function()
        return testing.run_fake_outcome(replay_admission_department.make_department(), observed_issue())
      end)
    end)
    fkst.observe = previous_observe
    if not ok then
      error(result, 0)
    end

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(observe_calls, 0)
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
