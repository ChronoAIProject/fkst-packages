local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local m_builders = require("devloop.markers.builders")
local decompose = require("devloop.decompose")
local conv_reconcile = require("devloop.convergence.reconcile")
local transition_version = require("contract.transition_version")
local terminal_retirement = require("departments.observability.terminal_retirement")

local proposal_id = "github-devloop/issue/owner/repo/42"
local terminal_version = "github-devloop/issue/owner/repo/42/intake/retirement-test"
local result_dedup = "consensus:github-devloop/issue/owner/repo/42/intake/retirement-test"
local reconcile_base_version = "github-devloop/issue/owner/repo/42/intake/reconcile-retirement-test"
local reconcile_round = 3
local reconcile_terminal_version = conv_reconcile.reconcile_state_version(reconcile_base_version, reconcile_round)
local delegated_pr_number = 7
local delegated_version = "ready/consensus-github-devloop/issue/owner/repo/42/retirement/fix/4"
local delegated_parent_version = transition_version.next_blocked(delegated_version, "child-pr-blocked")

parsers_misc.configure_trusted_bot_login("fkst-test-bot")

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

local function reconcile_marker(action, terminal_cause, base_version)
  return conv_reconcile.reconcile_marker(
    proposal_id,
    base_version or reconcile_base_version,
    reconcile_round,
    action or "drop",
    terminal_cause or "no-semantic-progress"
  )
end

local function blocked_issue(marker, marker_author, extra_comments)
  local comments = {
    bot_comment(
      core.state_marker(proposal_id, "blocked", reconcile_terminal_version),
      "2026-07-30T00:00:00Z"
    ),
    {
      body = marker or reconcile_marker(),
      author_login = marker_author or "fkst-test-bot",
      created_at = "2026-07-30T00:01:00Z",
    },
  }
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    number = 42,
    state = "OPEN",
    comments = comments,
  }
end

local function expected_reconcile_terminal()
  return {
    proposal_id = proposal_id,
    repo = "owner/repo",
    issue_number = 42,
    state = "blocked",
    version = reconcile_terminal_version,
  }
end

local function delegated_parent(extra_comments, delegation_marker, delegation_author)
  local comments = {
    bot_comment(
      core.state_marker(proposal_id, "blocked", delegated_parent_version),
      "2026-07-30T00:02:00Z"
    ),
  }
  if delegation_marker ~= false then
    table.insert(comments, {
      body = delegation_marker or m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/7",
        delegated_pr_number,
        delegated_version,
        "g1"
      ),
      author_login = delegation_author or "fkst-test-bot",
      created_at = "2026-07-29T23:59:00Z",
    })
  end
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    number = 42,
    state = "OPEN",
    comments = comments,
  }
end

local function delegated_pr(extra_comments, overrides)
  local values = overrides or {}
  local comments = {
    {
      body = values.pr_link_marker or m_builders.pr_link_marker(
        proposal_id,
        delegated_pr_number,
        "devloop-owner-repo-42",
        delegated_version,
        "dev"
      ),
      author_login = values.pr_link_author or "fkst-test-bot",
      created_at = "2026-07-29T23:59:00Z",
    },
  }
  local fix_marker = values.fix_marker
  if fix_marker == nil then
    fix_marker = conv_reconcile.fix_reconcile_marker(proposal_id, delegated_version, "drop")
  elseif fix_marker == false then
    fix_marker = ""
  end
  table.insert(comments,
    bot_comment(
      core.state_marker(proposal_id, values.state or "blocked", values.state_version or delegated_version)
        .. "\n" .. fix_marker,
      "2026-07-30T00:00:00Z"
    )
  )
  if values.decomposed_marker ~= false then
    table.insert(comments, {
      body = values.decomposed_marker or decompose.decomposed_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        values.decomposed_count or 2
      ),
      author_login = values.decomposed_author or "fkst-test-bot",
      created_at = "2026-07-30T00:01:00Z",
    })
  end
  for _, comment in ipairs(extra_comments or {}) do
    table.insert(comments, comment)
  end
  return {
    number = delegated_pr_number,
    state = values.native_state or "OPEN",
    comments = comments,
  }
end

local function delegated_children(overrides)
  local values = overrides or {}
  return {
    {
      number = 101,
      state = "OPEN",
      author_login = values.first_author or "fkst-test-bot",
      body = decompose.decompose_child_marker(
        values.first_parent or proposal_id,
        values.first_version or delegated_version,
        values.first_pr or delegated_pr_number,
        values.first_index or 1
      ),
    },
    {
      number = 102,
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        values.second_index or 2
      ),
    },
  }
end

local function expected_delegated_terminal()
  return {
    proposal_id = proposal_id,
    repo = "owner/repo",
    issue_number = 42,
    state = "blocked",
    version = delegated_parent_version,
  }
end

local function decide_delegated(parent, pr, children)
  return terminal_retirement.decide(
    parent,
    expected_delegated_terminal(),
    contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z"),
    {
      pr = pr,
      child_issues = children,
    }
  )
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

  test_exact_trusted_reconcile_drop_fact_is_eligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")

    local decision = terminal_retirement.decide(
      blocked_issue(),
      expected_reconcile_terminal(),
      now_seconds
    )

    t.eq(decision.decision, "eligible")
    t.eq(decision.action, "receipt")
    t.eq(decision.fact.terminal_authority, "reconcile:v1")
    t.eq(decision.fact.reconcile_action, "drop")
    t.eq(decision.fact.terminal_cause, "no-semantic-progress")
  end,

  test_untrusted_reconcile_drop_marker_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")

    local decision = terminal_retirement.decide(
      blocked_issue(nil, "mallory"),
      expected_reconcile_terminal(),
      now_seconds
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-fact-missing")
  end,

  test_reconcile_drop_marker_for_another_version_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")
    local wrong_version_marker = reconcile_marker(nil, nil, reconcile_base_version .. "-other")

    local decision = terminal_retirement.decide(
      blocked_issue(wrong_version_marker),
      expected_reconcile_terminal(),
      now_seconds
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-fact-missing")
  end,

  test_reconcile_marker_with_non_drop_action_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")

    local decision = terminal_retirement.decide(
      blocked_issue(reconcile_marker("re-design")),
      expected_reconcile_terminal(),
      now_seconds
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-action-unsupported")
  end,

  test_reconcile_marker_with_other_terminal_cause_is_ineligible = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")

    local decision = terminal_retirement.decide(
      blocked_issue(reconcile_marker("drop", "external-evidence-required")),
      expected_reconcile_terminal(),
      now_seconds
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-cause-unsupported")
  end,

  test_exact_reconcile_retirement_receipt_is_idempotent = function()
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:01:00Z")
    local issue = blocked_issue()
    local first = terminal_retirement.decide(issue, expected_reconcile_terminal(), now_seconds)
    table.insert(issue.comments, bot_comment(first.request.body, "2026-07-31T00:00:00Z"))

    local replay = terminal_retirement.decide(issue, expected_reconcile_terminal(), now_seconds)

    t.eq(replay.decision, "eligible")
    t.eq(replay.action, "close")
  end,

  test_exact_delegated_fix_reconcile_decomposition_is_eligible = function()
    local decision = decide_delegated(
      delegated_parent(),
      delegated_pr(),
      delegated_children()
    )

    t.eq(decision.decision, "eligible")
    t.eq(decision.action, "receipt")
    t.eq(decision.fact.terminal_authority, "delegated-fix-reconcile:v1")
    t.eq(decision.fact.delegated_pr_number, delegated_pr_number)
    t.eq(decision.fact.pr_terminal_version, delegated_version)
    t.eq(decision.fact.decomposed_count, 2)
    t.is_true(type(decision.fact.proof_digest) == "string")
    t.eq(#decision.fact.proof_digest, 64)
    t.is_true(decision.request.body:find('proof_digest="' .. decision.fact.proof_digest .. '"', 1, true) ~= nil)
  end,

  test_delegated_terminal_requires_exact_issue_and_pr_authority = function()
    local wrong_delegation = m_builders.pr_delegation_marker(
      proposal_id,
      "github-devloop/pr/owner/repo/7",
      7,
      delegated_version .. "/other",
      "g1"
    )
    local wrong_link = m_builders.pr_link_marker(
      proposal_id,
      8,
      "devloop-owner-repo-42",
      delegated_version,
      "dev"
    )
    local cases = {
      { parent = delegated_parent(nil, false), reason = "reconcile-terminal-fact-missing" },
      { parent = delegated_parent(nil, nil, "mallory"), reason = "reconcile-terminal-fact-missing" },
      { parent = delegated_parent(nil, wrong_delegation), reason = "reconcile-terminal-pr-delegation-mismatch" },
      { parent = delegated_parent(), pr = nil, reason = "delegated-pr-unavailable" },
      { parent = delegated_parent(), pr = { state = "OPEN", comments = {} }, reason = "delegated-pr-link-missing" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { pr_link_marker = wrong_link }), reason = "delegated-pr-link-missing" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { pr_link_author = "mallory" }), reason = "delegated-pr-link-missing" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { native_state = "CLOSED" }), reason = "delegated-pr-state-mismatch" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { native_state = "MERGED" }), reason = "delegated-pr-state-mismatch" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { state = "reviewing" }), reason = "delegated-pr-state-mismatch" },
      { parent = delegated_parent(), pr = delegated_pr(nil, { state_version = delegated_version .. "/other" }), reason = "delegated-pr-state-mismatch" },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, {
          fix_marker = conv_reconcile.fix_reconcile_marker(proposal_id, delegated_version, "re-design"),
        }),
        reason = "delegated-fix-reconcile-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, {
          fix_marker = conv_reconcile.review_reconcile_marker(
            proposal_id,
            delegated_version,
            4,
            "drop",
            "no-semantic-progress"
          ),
        }),
        reason = "delegated-fix-reconcile-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, {
          fix_marker = '<!-- fkst:github-devloop:timeout-reconcile:v1 proposal="' .. proposal_id
            .. '" version="' .. delegated_version .. '" round="4" action="drop" -->',
        }),
        reason = "delegated-fix-reconcile-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, { decomposed_marker = false }),
        reason = "delegated-decomposed-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, {
          decomposed_marker = decompose.decomposed_marker(
            proposal_id,
            delegated_version .. "/other",
            delegated_pr_number,
            2
          ),
        }),
        reason = "delegated-decomposed-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, { decomposed_author = "mallory" }),
        reason = "delegated-decomposed-missing",
      },
      {
        parent = delegated_parent(),
        pr = delegated_pr(nil, {
          decomposed_marker = '<!-- fkst:github-devloop:decomposed:v1 proposal="' .. proposal_id
            .. '" version="' .. delegated_version .. '" pr="7" count="0" -->',
        }),
        reason = "delegated-decomposed-missing",
      },
    }

    for _, case in ipairs(cases) do
      local decision = decide_delegated(case.parent, case.pr, delegated_children())
      t.eq(decision.decision, "ineligible")
      t.eq(decision.reason, case.reason)
    end
  end,

  test_delegated_terminal_requires_blocked_to_be_the_current_pr_state = function()
    local pr = delegated_pr()
    table.insert(pr.comments, bot_comment(
      core.state_marker(
        proposal_id,
        "reviewing",
        transition_version.next_fix(delegated_version)
      ),
      "2026-07-30T00:03:00Z"
    ))

    local decision = decide_delegated(delegated_parent(), pr, delegated_children())

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "delegated-pr-state-mismatch")
  end,

  test_no_pr_retirement_rejects_contradictory_delegation_evidence = function()
    local comments = {
      bot_comment(m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/7",
        7,
        delegated_version,
        "g1"
      ), "2026-07-30T00:02:00Z"),
      bot_comment(m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/8",
        8,
        delegated_version,
        "g2"
      ), "2026-07-30T00:03:00Z"),
    }

    local decision = terminal_retirement.decide(
      blocked_issue(nil, nil, comments),
      expected_reconcile_terminal(),
      contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-pr-delegation-mismatch")
  end,

  test_no_pr_retirement_rejects_contradictory_decomposition_evidence = function()
    local comments = {
      bot_comment(decompose.decomposed_marker(
        proposal_id,
        reconcile_terminal_version,
        delegated_pr_number,
        2
      ), "2026-07-30T00:02:00Z"),
      bot_comment(decompose.decomposed_marker(
        proposal_id,
        reconcile_terminal_version,
        delegated_pr_number,
        3
      ), "2026-07-30T00:03:00Z"),
    }

    local decision = terminal_retirement.decide(
      blocked_issue(nil, nil, comments),
      expected_reconcile_terminal(),
      contract_time.iso_timestamp_epoch_seconds("2026-08-01T00:00:00Z")
    )

    t.eq(decision.decision, "ineligible")
    t.eq(decision.reason, "reconcile-terminal-decomposed-present")
  end,

  test_delegated_terminal_requires_one_exact_trusted_child_fact_per_index = function()
    local missing_identity = delegated_children()
    missing_identity[1].number = nil
    local invalid_identity = delegated_children()
    invalid_identity[1].number = 0
    local cases = {
      { children = { delegated_children()[1] } },
      { children = delegated_children({ second_index = 1 }) },
      { children = delegated_children({ first_parent = proposal_id .. "/other" }) },
      { children = delegated_children({ first_version = delegated_version .. "/other" }) },
      { children = delegated_children({ first_pr = 8 }) },
      { children = delegated_children({ first_author = "mallory" }) },
      { children = missing_identity },
      { children = invalid_identity },
    }

    for _, case in ipairs(cases) do
      local decision = decide_delegated(delegated_parent(), delegated_pr(), case.children)
      t.eq(decision.decision, "ineligible")
      t.eq(decision.reason, "delegated-decomposition-proof-incomplete")
    end
  end,

  test_delegated_terminal_rejects_post_reconcile_human_comment_on_either_surface = function()
    local issue_comment = {
      body = "Please keep this open.",
      author_login = "alice",
      created_at = "2026-07-30T00:03:00Z",
    }
    local pr_comment = {
      body = "The decomposition needs another pass.",
      author_login = "alice",
      created_at = "2026-07-30T00:03:00Z",
    }
    local same_second_issue_comment = {
      body = "This arrived after reconcile within the same timestamp second.",
      author_login = "alice",
      created_at = "2026-07-30T00:00:00Z",
    }

    local issue_decision = decide_delegated(
      delegated_parent({ issue_comment }),
      delegated_pr(),
      delegated_children()
    )
    local pr_decision = decide_delegated(
      delegated_parent(),
      delegated_pr({ pr_comment }),
      delegated_children()
    )
    local same_second_decision = decide_delegated(
      delegated_parent({ same_second_issue_comment }),
      delegated_pr(),
      delegated_children()
    )

    t.eq(issue_decision.decision, "ineligible")
    t.eq(issue_decision.reason, "post-terminal-non-bot-comment")
    t.eq(pr_decision.decision, "ineligible")
    t.eq(pr_decision.reason, "post-terminal-non-bot-comment")
    t.eq(same_second_decision.decision, "ineligible")
    t.eq(same_second_decision.reason, "post-terminal-non-bot-comment")
  end,

  test_delegated_terminal_rejects_contradictory_trusted_authority = function()
    local conflicting_parent = delegated_parent()
    table.insert(conflicting_parent.comments, bot_comment(
      m_builders.pr_delegation_marker(
        proposal_id,
        "github-devloop/pr/owner/repo/8",
        8,
        delegated_version,
        "g2"
      ),
      "2026-07-30T00:03:00Z"
    ))

    local conflicting_link_pr = delegated_pr()
    table.insert(conflicting_link_pr.comments, bot_comment(
      m_builders.pr_link_marker(
        proposal_id,
        8,
        "devloop-owner-repo-42-other",
        delegated_version,
        "dev"
      ),
      "2026-07-30T00:03:00Z"
    ))

    local conflicting_fix_pr = delegated_pr(nil, {
      fix_marker = conv_reconcile.fix_reconcile_marker(
        proposal_id,
        delegated_version,
        "re-design"
      ) .. "\n" .. conv_reconcile.fix_reconcile_marker(
        proposal_id,
        delegated_version,
        "drop"
      ),
    })

    local conflicting_decomposed_pr = delegated_pr()
    table.insert(conflicting_decomposed_pr.comments, bot_comment(
      decompose.decomposed_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        3
      ),
      "2026-07-30T00:03:00Z"
    ))

    local cases = {
      { parent = conflicting_parent, pr = delegated_pr() },
      { parent = delegated_parent(), pr = conflicting_link_pr },
      { parent = delegated_parent(), pr = conflicting_fix_pr },
      { parent = delegated_parent(), pr = conflicting_decomposed_pr },
    }
    for _, case in ipairs(cases) do
      local decision = decide_delegated(case.parent, case.pr, delegated_children())
      t.eq(decision.decision, "ineligible")
    end
  end,

  test_delegated_receipt_must_match_force_fresh_authority_and_proof = function()
    local parent = delegated_parent()
    local pr = delegated_pr()
    local children = delegated_children()
    local first = decide_delegated(parent, pr, children)
    local malformed_receipt = first.request.body:gsub('proof_digest="[^"]+"', 'proof_digest="wrong"')
    table.insert(parent.comments, bot_comment(malformed_receipt, "2026-07-31T00:00:00Z"))

    local malformed = decide_delegated(parent, pr, children)
    t.eq(malformed.decision, "eligible")
    t.eq(malformed.action, "receipt")

    table.insert(parent.comments, bot_comment(first.request.body, "2026-07-31T00:01:00Z"))
    local unchanged = decide_delegated(parent, pr, children)
    t.eq(unchanged.decision, "eligible")
    t.eq(unchanged.action, "close")

    table.insert(children, {
      number = 103,
      state = "OPEN",
      author_login = "fkst-test-bot",
      body = decompose.decompose_child_marker(
        proposal_id,
        delegated_version,
        delegated_pr_number,
        1
      ),
    })
    local changed = decide_delegated(parent, pr, children)
    t.eq(changed.decision, "ineligible")
    t.eq(changed.reason, "delegated-decomposition-proof-incomplete")
  end,
}
