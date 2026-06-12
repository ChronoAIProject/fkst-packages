local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

return {
  test_intake_parser_is_strict_and_conservative = function()
    local parsed = core.parse_intake_action("⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ expedite\n⟦FKST:REASON⟧ Clear bounded task.")
    t.eq(parsed.action, "enable")
    t.eq(parsed.class, "expedite")
    t.eq(parsed.reason, "Clear bounded task.")

    local tracked = core.parse_intake_action("⟦FKST:INTAKE⟧ track\n⟦FKST:CLASS⟧ background\n⟦FKST:REASON⟧ Umbrella tracking issue with independent waves.")
    t.eq(tracked.action, "track")
    t.eq(tracked.class, "background")
    t.eq(tracked.reason, "Umbrella tracking issue with independent waves.")

    local escalated = core.parse_intake_action("⟦FKST:INTAKE⟧ escalate-to-class\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Third widget-sync recurrence; class-level retry policy is required.")
    t.eq(escalated.action, "escalate-to-class")
    t.eq(escalated.class, "standard")
    t.eq(escalated.reason, "Third widget-sync recurrence; class-level retry policy is required.")

    t.is_nil(core.parse_intake_action("prefix\n⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Clear bounded task."))
    t.is_nil(core.parse_intake_action("⟦FKST:INTAKE⟧ enable extra\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Clear bounded task."))
    t.is_nil(core.parse_intake_action("⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ urgent\n⟦FKST:REASON⟧ Clear bounded task."))
    t.is_nil(core.parse_intake_action("⟦FKST:INTAKE⟧ enable\n\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Clear bounded task."))
    t.is_nil(core.parse_intake_action("⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Clear bounded task.\n⟦FKST:INTAKE⟧ decline"))
    t.is_nil(core.parse_intake_action("⟦FKST:INTAKE⟧ park\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Unknown values must fail closed."))
  end,

  test_intake_marker_fact_trusts_only_bot_comments = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local marker = core.intake_decision_marker(proposal_id, "decline", "intake/github-devloop/issue/owner/repo/42/v1", "background")
    t.eq(core.has_intake_decision_marker({ { body = marker, author_login = "ordinary-user" } }, proposal_id), false)
    local fact = core.intake_decision_fact({ { body = marker, author_login = core.trusted_bot_login() } }, proposal_id)
    t.eq(fact.decision, "decline")
    t.eq(fact.class, "background")
    t.eq(fact.proposal_id, proposal_id)

    local track_marker = core.intake_decision_marker(proposal_id, "track", "intake/github-devloop/issue/owner/repo/42/v-track")
    local tracked = core.intake_decision_fact({ { body = track_marker, author_login = core.trusted_bot_login() } }, proposal_id)
    t.eq(tracked.decision, "track")
    t.eq(tracked.class, "standard")

    local escalation_marker = core.intake_decision_marker(proposal_id, "escalate-to-class", "intake/github-devloop/issue/owner/repo/42/v2")
    local escalation = core.intake_decision_fact({ { body = escalation_marker, author_login = core.trusted_bot_login() } }, proposal_id)
    t.eq(escalation.decision, "escalate-to-class")
  end,

  test_intake_class_batch_uses_trusted_marker_order_with_fifo_capacity_guard = function()
    local function item(number, intake_class, updated_at, author_login)
      local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(number)
      return {
        number = number,
        updated_at = updated_at,
        labels = { "fkst-class:expedite" },
        comments = {
          {
            body = core.intake_decision_marker(proposal_id, "enable", "intake/" .. proposal_id .. "/v1", intake_class),
            author_login = author_login or core.trusted_bot_login(),
          },
        },
      }
    end
    local function marker_class(value)
      local fact = core.intake_decision_fact(value.comments, "github-devloop/issue/owner/repo/" .. tostring(value.number))
      return fact and fact.class
    end
    local function fifo(value)
      return tostring(value.updated_at or "") .. "/" .. tostring(value.number or "")
    end

    local sorted = core.sort_by_intake_class({
      item(40, "background", "2026-06-03T01:00:00Z"),
      item(41, "standard", "2026-06-03T01:01:00Z"),
      item(42, "expedite", "2026-06-03T01:02:00Z"),
      item(43, "expedite", "2026-06-03T01:03:00Z"),
    }, marker_class, fifo)
    t.eq(sorted[1].number, 42)
    t.eq(sorted[2].number, 43)
    t.eq(sorted[3].number, 41)
    t.eq(sorted[4].number, 40)

    local selected = core.select_intake_class_batch({
      item(50, "background", "2026-06-03T01:00:00Z"),
      item(51, "standard", "2026-06-03T01:01:00Z"),
      item(52, "expedite", "2026-06-03T01:02:00Z"),
      item(53, "expedite", "2026-06-03T01:03:00Z"),
      item(54, "expedite", "2026-06-03T01:04:00Z"),
    }, marker_class, fifo, 3)
    t.eq(#selected, 3)
    t.eq(selected[1].number, 52)
    t.eq(selected[2].number, 53)
    t.eq(selected[3].number, 51)
  end,
}
