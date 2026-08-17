local replay_authorization = require("core.replay_authorization")
local claim_carriers = require("devloop.claim_carriers")
local t = fkst.test

local owner = "fkst-test-bot"

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function terminal_row()
  return {
    delivery_id = "terminal-one",
    queue = "github-devloop-intake.devloop_intake_candidate",
    dept = "github-devloop-intake-default.intake_judge",
    source = {
      kind = "External",
      reference = "owner/repo#issue/42",
    },
    attempts = 2,
    permanent = true,
    replayable = false,
    dead_at_ms = 1781830861000,
  }
end

local function mock_claim_env(mode)
  local values = {
    FKST_GITHUB_BOT_LOGIN = owner,
    FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE = "",
    FKST_GITHUB_CLAIM_LABEL_SUFFIX = "",
    FKST_GITHUB_CLAIM_MODE = mode,
    FKST_GITHUB_WRITE = "",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
  }
  for name, value in pairs(values) do
    for _ = 1, 4 do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = value,
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function current_issue(assignees, labels)
  return {
    state = "OPEN",
    assignees = assignees,
    labels = labels,
  }
end

local function authorize(current)
  local terminal = terminal_row()
  return replay_authorization.authorize(
    current,
    "github-devloop/issue/owner/repo/42",
    source_ref(),
    {
      lineage = { terminal_dead_letter = terminal },
      terminal = terminal,
    }
  )
end

return {
  test_lineage_lookup_uses_exact_scope_and_fails_closed_when_unavailable = function()
    local original_observe = fkst.observe
    local requested = nil
    fkst.observe = function(opts)
      requested = opts
      error("injected lookup failure")
    end

    local terminal, reason = replay_authorization.terminal_precondition(source_ref())
    fkst.observe = original_observe

    t.is_nil(terminal)
    t.is_true(reason:match("^observe%-unavailable:") ~= nil)
    t.eq(requested.lineage.queue, "github-devloop-intake.devloop_intake_candidate")
    t.eq(requested.lineage.dept, "github-devloop-intake-default.intake_judge")
    t.eq(requested.lineage.source_ref.kind, "external")
    t.eq(requested.lineage.source_ref.ref, "owner/repo#issue/42")
    t.is_nil(requested.limit)
  end,

  test_lineage_live_delivery_blocks_replay = function()
    t.mock_observe({
      live_delivery = {
        delivery_id = "live-one",
        queue = "github-devloop-intake.devloop_intake_candidate",
        dept = "github-devloop-intake-default.intake_judge",
        source = {
          kind = "External",
          reference = "owner/repo#issue/42",
        },
        status = "retrying",
      },
    })

    local terminal, reason = replay_authorization.terminal_precondition(source_ref())

    t.is_nil(terminal)
    t.eq(reason, "live-delivery-present")
  end,

  test_lineage_without_terminal_fails_closed = function()
    t.mock_observe({})

    local terminal, reason = replay_authorization.terminal_precondition(source_ref())

    t.is_nil(terminal)
    t.eq(reason, "terminal-dlq-absent")
  end,

  test_bounded_lineage_result_has_no_truncation_cliff = function()
    local expected = terminal_row()
    t.mock_observe({
      terminal_dead_letter = expected,
      truncated = {
        deliveries = true,
        dead_letters = true,
      },
    })

    local terminal, reason = replay_authorization.terminal_precondition(source_ref())

    t.eq(terminal.delivery_id, expected.delivery_id)
    t.eq(terminal.attempts, expected.attempts)
    t.is_nil(reason)
  end,

  test_terminal_from_another_lineage_fails_closed = function()
    local mismatched = terminal_row()
    mismatched.source.reference = "owner/repo#issue/99"
    t.mock_observe({ terminal_dead_letter = mismatched })

    local terminal, reason = replay_authorization.terminal_precondition(source_ref())

    t.is_nil(terminal)
    t.eq(reason, "terminal-dlq-absent")
  end,

  test_label_claim_authorizes_replay = function()
    mock_claim_env("label")
    local authorization, reason = authorize(current_issue(
      {},
      { claim_carriers.derived_label(owner) }
    ))

    t.is_true(type(authorization) == "table")
    t.eq(authorization.repo, "owner/repo")
    t.eq(authorization.issue_number, "42")
    t.is_nil(reason)
  end,

  test_label_mode_without_claim_refuses_replay = function()
    mock_claim_env("label")
    local authorization, reason = authorize(current_issue({}, {}))

    t.is_nil(authorization)
    t.eq(reason, "not-self-only-assignee")
  end,

  test_assignee_claim_does_not_authorize_migrated_replay = function()
    mock_claim_env("assignee")
    local authorization, reason = authorize(current_issue({ owner }, {}))

    t.is_nil(authorization)
    t.eq(reason, "not-self-only-assignee")
  end,
}
