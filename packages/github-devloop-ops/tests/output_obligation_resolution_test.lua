local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local resolution = require("departments.observability.output_obligation_resolution")
local conv_reconcile = require("devloop.convergence.reconcile")

local repo = "owner/repo"
local source_issue_number = 42
local escalation_issue_number = 900
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "ready/2026-07-27T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local reason_class = "state-output-obligation-timeout"

local function escalation_dedup()
  return core.output_obligation_failure_dedup_key(
    repo,
    proposal_id,
    terminal_version,
    reason_class
  )
end

local function escalation_marker()
  return core.output_obligation_escalation_marker({
    proposal_id = proposal_id,
    terminal_version = terminal_version,
    dedup_key = escalation_dedup(),
    reason_class = reason_class,
    source_repo = repo,
    issue_number = source_issue_number,
  })
end

local function bot_comment(body, author_login)
  return {
    body = body,
    author_login = author_login or "fkst-test-bot",
    created_at = "2026-07-27T12:10:00Z",
  }
end

local function source_timeout_marker(overrides)
  local fields = overrides or {}
  return conv_reconcile.timeout_reconcile_marker(
    fields.proposal_id or proposal_id,
    fields.from_version or ready_version,
    "ready",
    3,
    "drop",
    {
      terminal_version = fields.terminal_version or terminal_version,
      from_state = "ready",
      from_version = fields.from_version or ready_version,
      attempt = 3,
      attempt_limit = 3,
      driving_queue = "github-devloop.devloop_ready",
      reason_class = reason_class,
      source_ref = fields.source_ref or {
        kind = "external",
        ref = "owner/repo#issue/42",
      },
    }
  )
end

local function source_issue(overrides)
  local issue = {
    number = source_issue_number,
    source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    },
    state = "CLOSED",
    comments = { bot_comment(source_timeout_marker()) },
  }
  for key, value in pairs(overrides or {}) do
    issue[key] = value
  end
  return issue
end

local function escalation_issue(overrides)
  local issue = {
    number = escalation_issue_number,
    state = "OPEN",
    labels = { core._hold_label },
    author_login = "fkst-test-bot",
    body = "Blocked output obligation.\n\n" .. escalation_marker(),
    comments = {},
  }
  for key, value in pairs(overrides or {}) do
    issue[key] = value
  end
  return issue
end

local function classify(issue)
  return core.classify_output_obligation_escalation_issue(
    issue,
    repo,
    escalation_issue_number
  )
end

local function replace_literal(text, old, new)
  local start_at, end_at = tostring(text):find(tostring(old), 1, true)
  if start_at == nil then
    error("test fixture replacement target is missing: " .. tostring(old))
  end
  return text:sub(1, start_at - 1) .. tostring(new) .. text:sub(end_at + 1)
end

local function capture_info_logs(fn)
  local captured = {}
  local old_log = log
  log = {
    info = function(message)
      table.insert(captured, tostring(message))
    end,
  }
  local ok, result = pcall(fn)
  log = old_log
  if not ok then
    error(result, 0)
  end
  return captured
end

return {
  test_escalation_classifier_derives_one_coherent_source_lineage = function()
    local fact, reason = classify(escalation_issue())

    t.eq(reason, nil)
    t.eq(fact.proposal_id, proposal_id)
    t.eq(fact.parent, "owner/repo#issue/42")
    t.eq(fact.dedup_key, escalation_dedup())
    t.eq(fact.terminal_version, terminal_version)
    t.eq(fact.reason_class, reason_class)
    t.eq(fact.source_ref.kind, "external")
    t.eq(fact.source_ref.ref, "owner/repo#issue/42")
    t.eq(fact.escalation_source_ref.ref, "owner/repo#issue/900")
  end,

  test_escalation_classifier_rejects_untrusted_or_incoherent_markers = function()
    local cases = {
      {
        reason = "untrusted-escalation-author",
        issue = escalation_issue({ author_login = "mallory" }),
      },
      {
        reason = "escalation-not-held",
        issue = escalation_issue({ labels = {} }),
      },
      {
        reason = "escalation-not-open",
        issue = escalation_issue({ state = "CLOSED" }),
      },
      {
        reason = "unsupported-reason-class",
        issue = escalation_issue({
          body = replace_literal(
            escalation_marker(),
            'reason_class="' .. reason_class .. '"',
            'reason_class="decompose-output-obligation-timeout"'
          ),
        }),
      },
      {
        reason = "proposal-parent-mismatch",
        issue = escalation_issue({
          body = replace_literal(
            escalation_marker(),
            'parent="owner/repo#issue/42"',
            'parent="owner/repo#issue/43"'
          ),
        }),
      },
      {
        reason = "escalation-dedup-mismatch",
        issue = escalation_issue({
          body = replace_literal(
            escalation_marker(),
            'dedup="' .. escalation_dedup() .. '"',
            'dedup="wrong-dedup"'
          ),
        }),
      },
    }

    for _, case in ipairs(cases) do
      local fact, reason = classify(case.issue)
      t.eq(fact, nil)
      t.eq(reason, case.reason)
    end
  end,

  test_source_closed_decision_emits_one_stable_receipt_then_closes = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_issue()

    local first = core.output_obligation_resolution_decision(fact, issue, source)
    local replay = core.output_obligation_resolution_decision(fact, issue, source)

    t.eq(first.decision, "source-closed")
    t.eq(first.action, "receipt")
    t.eq(first.request.schema, "github-proxy.v1")
    t.eq(first.request.repo, repo)
    t.eq(first.request.issue_number, escalation_issue_number)
    t.eq(first.request.source_ref.ref, "owner/repo#issue/900")
    t.eq(first.request.dedup_key, replay.request.dedup_key)
    t.eq(first.request.body, replay.request.body)
    t.is_true(first.request.body:find('escalation_dedup="' .. escalation_dedup() .. '"', 1, true) ~= nil)
    t.is_true(first.request.body:find('terminal_version="' .. terminal_version .. '"', 1, true) ~= nil)

    issue.comments = {
      bot_comment(core.output_obligation_resolution_receipt_marker(fact)),
    }
    local after_receipt = core.output_obligation_resolution_decision(fact, issue, source)
    t.eq(after_receipt.decision, "source-closed")
    t.eq(after_receipt.action, "close")
    t.eq(after_receipt.request, nil)
  end,

  test_resolution_ignores_untrusted_receipts_and_nonclosed_sources = function()
    local issue = escalation_issue({
      comments = {
        bot_comment("fake\n" .. core.output_obligation_resolution_receipt_marker({
          dedup_key = escalation_dedup(),
          terminal_version = terminal_version,
        }), "mallory"),
      },
    })
    local fact = classify(issue)

    local untrusted = core.output_obligation_resolution_decision(fact, issue, source_issue())
    t.eq(untrusted.decision, "source-closed")
    t.eq(untrusted.action, "receipt")

    local source_open = core.output_obligation_resolution_decision(fact, issue, source_issue({ state = "OPEN" }))
    t.eq(source_open.decision, nil)
    t.eq(source_open.action, "skip")
    t.eq(source_open.reason, "source-not-closed")

    local wrong_lineage = core.output_obligation_resolution_decision(fact, issue, source_issue({
      comments = {
        bot_comment(source_timeout_marker({
          proposal_id = "github-devloop/issue/owner/repo/43",
        })),
      },
    }))
    t.eq(wrong_lineage.decision, nil)
    t.eq(wrong_lineage.action, "skip")
    t.eq(wrong_lineage.reason, "source-lineage-mismatch")

    local malformed_marker = replace_literal(
      source_timeout_marker(),
      'dedup="timeout-reconcile:' .. ready_version .. '/timeout-reconcile/ready/3"',
      'dedup="wrong-timeout-dedup"'
    )
    local malformed_lineage = core.output_obligation_resolution_decision(fact, issue, source_issue({
      comments = { bot_comment(malformed_marker) },
    }))
    t.eq(malformed_lineage.decision, nil)
    t.eq(malformed_lineage.action, "skip")
    t.eq(malformed_lineage.reason, "source-lineage-mismatch")
  end,

  test_deadline_defer_does_not_claim_source_closed_decision = function()
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local logs = capture_info_logs(function()
      resolution.reconcile({
        observability_has_budget = function()
          return false
        end,
      }, nil, repo, {
        issue_number = escalation_issue_number,
        parent_issue = escalation_issue(),
      }, {}, {})
    end)

    t.eq(#logs, 1)
    t.is_true(logs[1]:find("decision=none", 1, true) ~= nil)
    t.is_true(logs[1]:find("action=defer", 1, true) ~= nil)
  end,

  test_close_rechecks_deadline_after_source_read = function()
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
    local issue = escalation_issue({
      comments = {
        bot_comment(core.output_obligation_resolution_receipt_marker(classify(escalation_issue()))),
      },
    })
    local budget_checks = 0
    local close_calls = 0
    local logs = capture_info_logs(function()
      resolution.reconcile({
        observability_has_budget = function()
          budget_checks = budget_checks + 1
          return budget_checks == 1
        end,
        observability_call_timeout = function()
          return 10
        end,
      }, {
        read_issue = function()
          return source_issue()
        end,
        issue_close = function()
          close_calls = close_calls + 1
          return { exit_code = 0, stdout = "", stderr = "" }
        end,
      }, repo, {
        issue_number = escalation_issue_number,
        parent_issue = issue,
      }, {}, {})
    end)

    t.eq(budget_checks, 2)
    t.eq(close_calls, 0)
    t.eq(#logs, 1)
    t.is_true(logs[1]:find("decision=source-closed", 1, true) ~= nil)
    t.is_true(logs[1]:find("action=defer", 1, true) ~= nil)
  end,
}
