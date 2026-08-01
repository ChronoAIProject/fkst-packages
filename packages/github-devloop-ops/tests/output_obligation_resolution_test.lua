local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local resolution = require("departments.observability.output_obligation_resolution")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local marker_builders = require("devloop.markers.builders")
local operator_commands = require("devloop.operator_commands")

local repo = "owner/repo"
local source_issue_number = 42
local escalation_issue_number = 900
local proposal_id = "github-devloop/issue/owner/repo/42"
local ready_version = "ready/2026-07-27T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local reason_class = "state-output-obligation-timeout"
local pr_number = 77
local pr_branch = "devloop-owner-repo-42-live-recovery"
local pr_head_sha = "abcdef1234567890abcdef1234567890abcdef12"
local pr_blocked_version = "implement/2026-07-27T12-00-00Z/review-loop/3"
local prior_intake_dedup = "intake/github-devloop/issue/owner/repo/42/original"

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

local function live_source_issue(overrides)
  local issue = source_issue({
    title = "Recover this output obligation",
    body = "Original issue body",
    updated_at = "2026-07-27T12:12:00Z",
    state = "OPEN",
    labels = { core._blocked_label },
    comments = {
      bot_comment(marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        prior_intake_dedup,
        "standard"
      )),
      bot_comment(source_timeout_marker()),
      bot_comment(core.state_marker(proposal_id, "blocked", terminal_version)),
    },
  })
  for key, value in pairs(overrides or {}) do
    issue[key] = value
  end
  return issue
end

local function append_comment(comments, comment)
  local copied = {}
  for _, existing in ipairs(comments or {}) do
    table.insert(copied, existing)
  end
  table.insert(copied, comment)
  return copied
end

local function linked_pr_comments(state, version, extra_comments, fields)
  local metadata = fields or {}
  local comments = {
    bot_comment(marker_builders.pr_origin_marker(
      proposal_id,
      tostring(source_issue_number),
      metadata.origin_branch or pr_branch,
      metadata.origin_impl_version or ready_version,
      metadata.origin_base_branch or "dev"
    )),
    bot_comment(core.state_marker(proposal_id, state, version)),
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return comments
end

local function linked_pr_snapshot(state, version, extra)
  local fields = extra or {}
  local snapshot_pr_number = fields.pr_number or pr_number
  return {
    comments = fields.issue_comments or {},
    prs = {
      {
        number = snapshot_pr_number,
        link = {
          kind = "delegation",
          pr_number = snapshot_pr_number,
          pr_proposal_id = entity_lib.pr_proposal_id(repo, snapshot_pr_number),
          version = fields.link_version or ready_version,
          delegation = fields.link_delegation or "g1",
        },
        current = {
          state = fields.external_state or "OPEN",
          head_ref_name = fields.head_ref_name or pr_branch,
          head_sha = fields.head_sha or pr_head_sha,
          base_ref_name = fields.base_ref_name or "dev",
          head_repository = fields.head_repository or repo,
          is_cross_repository = fields.is_cross_repository == true,
          comments = fields.comments or linked_pr_comments(state, version, nil, fields),
        },
      },
    },
    absent_prs = {},
  }
end

local function source_with_pr_delegation(overrides, link_fields)
  local link = link_fields or {}
  local source = live_source_issue()
  source.comments = append_comment(source.comments, bot_comment(marker_builders.pr_delegation_marker(
    proposal_id,
    entity_lib.pr_proposal_id(repo, pr_number),
    pr_number,
    link.version or ready_version,
    link.delegation or "g1"
  )))
  for key, value in pairs(overrides or {}) do
    source[key] = value
  end
  return source
end

local function command_comment(request, id, created_at)
  return {
    id = id,
    body = request.body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-07-27T12:20:00Z",
  }
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
    t.eq(source_open.action, "wait")
    t.eq(source_open.reason, "source-terminal-changed")

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

  test_live_source_decision_table_selects_rereview_reintake_or_wait = function()
    local fact = classify(escalation_issue())
    local linked_source = source_with_pr_delegation()

    local rereview = core.output_obligation_resolution_decision(
      fact,
      escalation_issue(),
      linked_source,
      linked_pr_snapshot("blocked", pr_blocked_version)
    )
    t.eq(rereview.decision, "rereview")
    t.eq(rereview.action, "command")
    t.eq(rereview.request.schema, "github-proxy.v1")
    t.eq(rereview.request.repo, repo)
    t.eq(rereview.request.pr_number, pr_number)
    t.is_true(rereview.request.body:find("fkst: rereview", 1, true) == 1)
    t.is_true(rereview.request.body:find('escalation_dedup="' .. escalation_dedup() .. '"', 1, true) ~= nil)
    t.is_true(rereview.request.body:find('terminal_version="' .. terminal_version .. '"', 1, true) ~= nil)

    for _, state in ipairs({ "reviewing", "fixing" }) do
      local active = core.output_obligation_resolution_decision(
        fact,
        escalation_issue(),
        linked_source,
        linked_pr_snapshot(state, pr_blocked_version)
      )
      t.eq(active.decision, nil)
      t.eq(active.action, "wait")
      t.eq(active.reason, "linked-pr-active")
    end

    local reintake = core.output_obligation_resolution_decision(
      fact,
      escalation_issue(),
      live_source_issue(),
      { comments = {}, prs = {}, absent_prs = {} }
    )
    t.eq(reintake.decision, "abandon-recreate")
    t.eq(reintake.action, "command")
    t.eq(reintake.request.issue_number, source_issue_number)
    t.is_true(reintake.request.body:find("fkst: reintake", 1, true) == 1)

    local terminal_pr = core.output_obligation_resolution_decision(
      fact,
      escalation_issue(),
      linked_source,
      linked_pr_snapshot("merged", pr_blocked_version, { external_state = "MERGED" })
    )
    t.eq(terminal_pr.decision, "abandon-recreate")
    t.eq(terminal_pr.action, "command")
  end,

  test_rereview_requires_exact_applied_response_and_command_derived_reentry = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_with_pr_delegation()
    local initial_snapshot = linked_pr_snapshot("blocked", pr_blocked_version)
    local first = core.output_obligation_resolution_decision(fact, issue, source, initial_snapshot)
    local replay = core.output_obligation_resolution_decision(fact, issue, source, initial_snapshot)

    t.eq(first.request.dedup_key, replay.request.dedup_key)
    t.eq(first.request.body, replay.request.body)
    t.eq(first.target_version, operator_commands.operator_rereview_version(pr_blocked_version, pr_head_sha))

    local command = command_comment(first.request, "IC_rereview_recovery")
    local command_comments = append_comment(initial_snapshot.prs[1].current.comments, command)
    local command_only = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("blocked", pr_blocked_version, { comments = command_comments })
    )
    t.eq(command_only.action, "wait")
    t.eq(command_only.reason, "command-response-pending")

    local command_fact = operator_commands.operator_command_fact(command_comments, "rereview")
    local applied_comments = append_comment(command_comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "rereview")
    ))
    local applied_only = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("blocked", pr_blocked_version, { comments = applied_comments })
    )
    t.eq(applied_only.action, "wait")
    t.eq(applied_only.reason, "rereview-reentry-pending")

    local reentered_comments = append_comment(applied_comments, bot_comment(
      core.state_marker(proposal_id, "reviewing", first.target_version)
    ))
    local receipt = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("reviewing", first.target_version, { comments = reentered_comments })
    )
    t.eq(receipt.decision, "rereview")
    t.eq(receipt.action, "receipt")
    t.is_true(receipt.request.body:find('decision="rereview"', 1, true) ~= nil)

    issue.comments = { bot_comment(core.output_obligation_resolution_receipt_marker(fact, "rereview")) }
    local close = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("reviewing", first.target_version, { comments = reentered_comments })
    )
    t.eq(close.decision, "rereview")
    t.eq(close.action, "close")
  end,

  test_refused_rereview_is_retired_only_for_its_target_authority = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_with_pr_delegation()
    local initial_snapshot = linked_pr_snapshot("blocked", pr_blocked_version)
    local first = core.output_obligation_resolution_decision(fact, issue, source, initial_snapshot)
    local refusal_body = operator_commands.build_output_obligation_command_write_refusal_body(
      first.request.body,
      "command-target-changed"
    )
    local refused_comments = append_comment(
      initial_snapshot.prs[1].current.comments,
      command_comment({ body = refusal_body }, "IC_rereview_refused_old_head")
    )

    local unchanged = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("blocked", pr_blocked_version, { comments = refused_comments })
    )
    t.eq(unchanged.action, "wait")
    t.eq(unchanged.reason, "command-refused")

    local replacement_head = "1234567890abcdef1234567890abcdef12345678"
    local changed = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("blocked", pr_blocked_version, {
        comments = refused_comments,
        head_sha = replacement_head,
      })
    )
    t.eq(changed.decision, "rereview")
    t.eq(changed.action, "command")
    t.is_true(changed.request.dedup_key ~= first.request.dedup_key)
    t.is_true(changed.request.body:find('head_sha="' .. replacement_head .. '"', 1, true) ~= nil)
  end,

  test_multiple_correlated_rereview_commands_wait_without_another_effect = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_with_pr_delegation()
    local snapshot = linked_pr_snapshot("blocked", pr_blocked_version)
    local first = core.output_obligation_resolution_decision(fact, issue, source, snapshot)
    local comments = append_comment(
      snapshot.prs[1].current.comments,
      command_comment(first.request, "IC_rereview_ambiguous_a")
    )
    comments = append_comment(
      comments,
      command_comment(first.request, "IC_rereview_ambiguous_b")
    )

    local decision = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("blocked", pr_blocked_version, { comments = comments })
    )

    t.eq(decision.decision, nil)
    t.eq(decision.action, "wait")
    t.eq(decision.reason, "ambiguous-command")
    t.eq(decision.request, nil)
  end,

  test_existing_rereview_revalidates_other_same_lineage_pr_quiescence = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_with_pr_delegation()
    local initial_snapshot = linked_pr_snapshot("blocked", pr_blocked_version)
    local first = core.output_obligation_resolution_decision(fact, issue, source, initial_snapshot)
    local command = command_comment(first.request, "IC_rereview_other_active")
    local command_comments = append_comment(initial_snapshot.prs[1].current.comments, command)
    local command_fact = operator_commands.operator_command_fact(command_comments, "rereview")
    local applied_comments = append_comment(command_comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "rereview")
    ))
    local reentered_comments = append_comment(applied_comments, bot_comment(
      core.state_marker(proposal_id, "reviewing", first.target_version)
    ))
    local snapshot = linked_pr_snapshot("reviewing", first.target_version, {
      comments = reentered_comments,
    })
    local other_branch = "devloop-owner-repo-42-other-live-recovery"
    local other = linked_pr_snapshot("fixing", pr_blocked_version, {
      pr_number = 78,
      origin_branch = other_branch,
      head_ref_name = other_branch,
      head_sha = "1234567890abcdef1234567890abcdef12345678",
    }).prs[1]
    table.insert(snapshot.prs, other)

    local decision = core.output_obligation_resolution_decision(fact, issue, source, snapshot)
    t.eq(decision.decision, nil)
    t.eq(decision.action, "wait")
    t.eq(decision.reason, "linked-pr-active")
  end,

  test_reintake_requires_exact_applied_response_and_fresh_intake_generation = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = live_source_issue()
    local no_prs = { comments = source.comments, prs = {}, absent_prs = {} }
    local first = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    local command = command_comment(first.request, "IC_reintake_recovery", "2026-07-27T12:30:00Z")
    source.comments = append_comment(source.comments, command)

    local command_only = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    t.eq(command_only.action, "wait")
    t.eq(command_only.reason, "command-response-pending")

    local command_fact = operator_commands.operator_command_fact(source.comments, "reintake")
    source.comments = append_comment(source.comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "reintake")
    ))
    local applied_only = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    t.eq(applied_only.action, "wait")
    t.eq(applied_only.reason, "reintake-generation-pending")

    local effective_updated_at = operator_commands.reintake_effect_updated_at(
      source,
      command_fact,
      source.comments,
      proposal_id
    )
    local expected_intake_dedup = devloop_base.intake_decision_dedup_key(
      proposal_id,
      source,
      command_fact,
      effective_updated_at
    )
    source.comments = append_comment(source.comments, bot_comment(
      marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        expected_intake_dedup,
        "standard"
      )
    ))
    local decision_only = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    t.eq(decision_only.action, "wait")
    t.eq(decision_only.reason, "reintake-generation-pending")

    source.comments = append_comment(source.comments, bot_comment(
      core.state_marker(proposal_id, "thinking", expected_intake_dedup)
    ))
    local receipt = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    t.eq(receipt.decision, "abandon-recreate")
    t.eq(receipt.action, "receipt")
    t.is_true(receipt.request.body:find('decision="abandon-recreate"', 1, true) ~= nil)

    issue.comments = {
      bot_comment(core.output_obligation_resolution_receipt_marker(fact, "abandon-recreate")),
    }
    local close = core.output_obligation_resolution_decision(fact, issue, source, no_prs)
    t.eq(close.decision, "abandon-recreate")
    t.eq(close.action, "close")
  end,

  test_existing_reintake_revalidates_same_lineage_pr_quiescence = function()
    local issue = escalation_issue()
    local fact = classify(issue)
    local source = source_with_pr_delegation()
    local quiescent = linked_pr_snapshot("merged", pr_blocked_version, { external_state = "MERGED" })
    local first = core.output_obligation_resolution_decision(fact, issue, source, quiescent)
    local command = command_comment(first.request, "IC_reintake_pr_drift", "2026-07-27T12:30:00Z")
    source.comments = append_comment(source.comments, command)
    local command_fact = operator_commands.operator_command_fact(source.comments, "reintake")
    source.comments = append_comment(source.comments, bot_comment(
      operator_commands.operator_command_marker(command_fact, "applied", "reintake")
    ))
    local effective_updated_at = operator_commands.reintake_effect_updated_at(
      source,
      command_fact,
      source.comments,
      proposal_id
    )
    local expected_intake_dedup = devloop_base.intake_decision_dedup_key(
      proposal_id,
      source,
      command_fact,
      effective_updated_at
    )
    source.comments = append_comment(source.comments, bot_comment(
      marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        expected_intake_dedup,
        "standard"
      )
    ))
    source.comments = append_comment(source.comments, bot_comment(
      core.state_marker(proposal_id, "thinking", expected_intake_dedup)
    ))

    local drifted = core.output_obligation_resolution_decision(
      fact,
      issue,
      source,
      linked_pr_snapshot("fixing", pr_blocked_version)
    )
    t.eq(drifted.decision, nil)
    t.eq(drifted.action, "wait")
    t.eq(drifted.reason, "linked-pr-active")
  end,

  test_different_generation_active_pr_does_not_block_old_lineage_reintake = function()
    local new_generation = "intake/github-devloop/issue/owner/repo/42/new-generation"
    local decision = core.output_obligation_resolution_decision(
      classify(escalation_issue()),
      escalation_issue(),
      source_with_pr_delegation(nil, { version = new_generation }),
      linked_pr_snapshot("fixing", new_generation, {
        link_version = new_generation,
        origin_impl_version = new_generation,
      })
    )
    t.eq(decision.decision, "abandon-recreate")
    t.eq(decision.action, "command")
  end,

  test_incoherent_linked_pr_cannot_authorize_rereview_or_reintake = function()
    local fact = classify(escalation_issue())
    local source = source_with_pr_delegation()
    local cases = {
      linked_pr_snapshot("blocked", pr_blocked_version, { is_cross_repository = true }),
      linked_pr_snapshot("blocked", pr_blocked_version, { head_ref_name = "changed-head" }),
      linked_pr_snapshot("blocked", pr_blocked_version, { head_sha = "not-a-sha" }),
      linked_pr_snapshot("blocked", pr_blocked_version, {
        origin_impl_version = "ready/another-generation",
      }),
    }
    for _, snapshot in ipairs(cases) do
      local decision = core.output_obligation_resolution_decision(
        fact,
        escalation_issue(),
        source,
        snapshot
      )
      t.eq(decision.decision, nil)
      t.eq(decision.action, "wait")
      t.eq(decision.reason, "linked-pr-incoherent")
    end
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
          return budget_checks <= 5
        end,
        observability_call_timeout = function()
          return 10
        end,
      }, {
        read_issue = function(source_ref)
          if source_ref.ref == "owner/repo#issue/42" then
            return source_issue()
          end
          if source_ref.ref == "owner/repo#issue/900" then
            return issue
          end
          error("unexpected source ref: " .. tostring(source_ref.ref))
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

    t.eq(budget_checks, 6)
    t.eq(close_calls, 0)
    t.eq(#logs, 1)
    t.is_true(logs[1]:find("decision=source-closed", 1, true) ~= nil)
    t.is_true(logs[1]:find("action=defer", 1, true) ~= nil)
  end,

  test_close_reclassifies_and_redecides_fresh_escalation_before_write = function()
    for _ = 1, 16 do
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
    end
    local snapshot = escalation_issue()
    snapshot.comments = {
      bot_comment(core.output_obligation_resolution_receipt_marker(classify(snapshot))),
    }
    local changed_escalations = {
      escalation_issue({
        labels = {},
        comments = snapshot.comments,
      }),
      escalation_issue({ comments = {} }),
    }

    for _, current_escalation in ipairs(changed_escalations) do
      local reads = {}
      local close_calls = 0
      resolution.reconcile({
        observability_has_budget = function()
          return true
        end,
        observability_call_timeout = function()
          return 10
        end,
      }, {
        read_issue = function(source_ref, opts)
          table.insert(reads, {
            source_ref = source_ref,
            force_fresh = opts and opts.force_fresh,
          })
          if source_ref.ref == "owner/repo#issue/42" then
            return source_issue()
          end
          if source_ref.ref == "owner/repo#issue/900" then
            return current_escalation
          end
          error("unexpected source ref: " .. tostring(source_ref.ref))
        end,
        issue_close = function()
          close_calls = close_calls + 1
          return { exit_code = 0, stdout = "", stderr = "" }
        end,
      }, repo, {
        issue_number = escalation_issue_number,
        parent_issue = snapshot,
      }, {}, {})

      t.eq(#reads, 2)
      t.eq(reads[2].source_ref.ref, "owner/repo#issue/900")
      t.eq(reads[2].force_fresh, true)
      t.eq(close_calls, 0)
    end
  end,
}
