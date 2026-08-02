local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local m_builders = require("devloop.markers.builders")
local terminal_retirement = require("departments.observability.terminal_retirement")

local proposal_id = "github-devloop/issue/owner/repo/42"
local terminal_version = "github-devloop/issue/owner/repo/42/intake/retirement-test"
local result_dedup = "consensus:github-devloop/issue/owner/repo/42/intake/retirement-test"

devloop_base.configure_trusted_bot_login("fkst-test-bot")

local function bot_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function declined_issue(marker_created_at, extra_comments)
  local body = "github-devloop decision: decline: premise-refuted\n\n"
    .. core.state_marker(proposal_id, "declined", terminal_version, "result-marker,declined-label,premise-refuted")
    .. "\n"
    .. m_builders.result_marker(
      proposal_id,
      "reject",
      result_dedup,
      "premise-refuted",
      terminal_version
    )
  local comments = { bot_comment(body, marker_created_at) }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    number = 42,
    state = "OPEN",
    comments = comments,
  }
end

local function expected_terminal()
  return {
    proposal_id = proposal_id,
    state = "declined",
    version = terminal_version,
  }
end

return {
  test_declined_marker_inside_retirement_dwell_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    local issue = declined_issue("2026-07-31T00:01:00Z")

    local decision = terminal_retirement.decide(issue, expected_terminal(), now_seconds)

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "retirement-dwell-active")
    t.eq(decision.elapsed_minutes, 1439)
  end,

  test_non_bot_comment_after_declined_marker_with_same_timestamp_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    local issue = declined_issue("2026-07-30T00:00:00Z", {
      {
        body = "New evidence is available.",
        author_login = "alice",
        created_at = "2026-07-30T00:00:00Z",
      },
    })

    local decision = terminal_retirement.decide(issue, expected_terminal(), now_seconds)

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "post-terminal-non-bot-comment")
  end,

  test_later_noncanonical_state_marker_does_not_override_current_terminal_version = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    local issue = declined_issue("2026-07-30T00:00:00Z", {
      bot_comment(
        core.state_marker(proposal_id, "thinking", terminal_version),
        "2026-07-30T12:00:00Z"
      ),
    })

    local decision = terminal_retirement.decide(issue, expected_terminal(), now_seconds)

    t.eq(decision.decision, "eligible")
    t.eq(decision.action, "receipt")
  end,

  test_newer_trusted_state_marker_invalidates_observed_terminal_version = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    local issue = declined_issue("2026-07-30T00:00:00Z", {
      bot_comment(
        core.state_marker(proposal_id, "blocked", terminal_version .. "/reimplement/1"),
        "2026-07-30T12:00:00Z"
      ),
    })

    local decision = terminal_retirement.decide(issue, expected_terminal(), now_seconds)

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "terminal-changed")
  end,
}
