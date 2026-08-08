local admission_department = require("departments.admission.main")
local replay_authorization = require("core.replay_authorization")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = h.t

local function mock_claim_identity()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
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

local function label_claim_admission_department()
  return admission_department.make_department({
    capacity = {
      authorize = function()
        return true, "label-claim-test-capacity"
      end,
      relinquish = function()
        error("initial admission must not relinquish capacity")
      end,
      reconcile = function()
        error("initial admission must not reconcile capacity")
      end,
    },
    claims = {
      claim_admission_inputs = function()
        return {}
      end,
      claim_admission_precheck = function()
        return "claimed", "label-claim-test"
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
        title = "Hosted label-claimed issue",
        body = "",
        updated_at = "2026-07-31T01:02:03Z",
        state = "OPEN",
        labels = { "fkst-dev:claimed:fkst-test-bot", "fkst-class:expedite" },
        comments = {},
      }, nil
    end,
  })
end

return {
  test_label_claim_authorizes_terminal_intake_replay = function()
    mock_claim_identity()
    local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
    local terminal = {
      queue = "github-devloop-intake.devloop_intake_candidate",
      dept = "github-devloop-intake-default.intake_judge",
      source = source_ref,
      delivery_id = "delivery-42",
      attempts = 2,
      permanent = true,
      replayable = false,
    }
    local authorization, reason = replay_authorization.authorize({
      state = "OPEN",
      labels = { "fkst-dev:claimed:fkst-test-bot" },
      comments = {},
    }, "github-devloop/issue/owner/repo/42", source_ref, {
      lineage = { terminal_dead_letter = terminal },
      terminal = terminal,
    })

    t.is_nil(reason)
    t.eq(authorization.repo, "owner/repo")
    t.eq(authorization.issue_number, "42")
    t.eq(authorization.terminal.delivery_id, "delivery-42")
  end,

  test_label_claim_preserves_initial_admission = function()
    local result = testing.run_fake_outcome(label_claim_admission_department(), changed_issue())

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "42")
  end,
}
