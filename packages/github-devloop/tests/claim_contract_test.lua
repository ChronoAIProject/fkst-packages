local devloop_base = require("devloop.base")
local claim_carriers = require("devloop.claim_carriers")
local m_claims = require("devloop.claims")
local parsers_misc = require("devloop.parsers.misc")
local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t
local claim_helpers = require("tests.claim_test_helpers")
local claim_with_poll_epoch = claim_helpers.claim_with_poll_epoch
local count_calls = claim_helpers.count_calls

local active_spec = claim_carriers.active_label_spec(false, "fkst-test-bot")
local active_label = active_spec.name
local foreign_label = claim_carriers.derived_label("peer-bot")

local function ownership_json(labels, author_login)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', tostring(label)))
  end
  return '{"labels":[' .. table.concat(rendered, ",") .. '],"author":{"login":"'
    .. tostring(author_login or "fkst-test-bot") .. '"}}\n'
end

local function current(extra)
  local fields = extra or {}
  return {
    labels = fields.labels or {},
    title = fields.title or "Implement fork isolation",
    state = fields.state or "OPEN",
    author_login = fields.author_login or "fkst-test-bot",
    comments = fields.comments or {},
    created_at = fields.created_at or "2026-06-03T01:00:00Z",
    updated_at = fields.updated_at,
  }
end

local function mock_claim_env(write_mode, exclusive, reads)
  local count = reads or 16
  for _ = 1, count do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_FORK_GRACE_HOURS"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api repos/owner/repo/labels/" .. active_label, {
      stdout = '{"name":"' .. active_label .. '","description":"'
        .. active_spec.description .. '"}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

return {
  test_issue_claim_state_uses_only_the_complete_label_family = function()
    mock_claim_env("")
    t.eq(m_claims.issue_claim_state({}), "unassigned")
    t.eq(m_claims.issue_claim_state({ active_label }), "self")
    t.eq(m_claims.issue_claim_state({ foreign_label }), "other")
    t.eq(m_claims.issue_claim_state({ active_label, foreign_label }), "other")
  end,

  test_is_self_owned_issue_allows_active_label_or_unclaimed_self_author = function()
    mock_claim_env("")
    t.eq(m_claims.is_self_owned_issue(nil, "fkst-test-bot"), false)
    t.eq(m_claims.is_self_owned_issue({
      labels = { active_label },
      author_login = "human",
    }, "fkst-test-bot"), true)
    t.eq(m_claims.is_self_owned_issue({
      labels = {},
      author_login = "fkst-test-bot",
    }, "fkst-test-bot"), true)
    t.eq(m_claims.is_self_owned_issue({
      labels = {},
      author_login = "human",
    }, "fkst-test-bot"), false)
  end,

  test_app_actor_has_bare_login_claim_ownership_parity = function()
    mock_claim_env("")
    t.eq(m_claims.is_self_owned_issue({
      labels = {},
      author_login = "app/FKST-Test-Bot",
    }, "fkst-test-bot"), true)
    t.eq(m_claims.is_self_owned_issue({
      labels = {},
      author_login = "app/other-bot",
    }, "fkst-test-bot"), false)
    t.eq(m_claims.is_self_owned_issue({
      labels = {},
      author_login = "app/",
    }, "fkst-test-bot"), false)
  end,

  test_dry_run_claim_proceeds_without_writing = function()
    mock_claim_env("")
    local ok = claim_with_poll_epoch(
      core,
      "claim_contract",
      "owner/repo",
      42,
      current(),
      "github-devloop/issue/owner/repo/42"
    )
    t.eq(ok, true)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_claim_adds_active_label_then_verifies_winner = function()
    mock_claim_env("1")
    t.mock_command("gh issue edit 42 --repo owner/repo --add-label '" .. active_label .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue view 42 --repo owner/repo --json labels,author", {
      stdout = ownership_json({ active_label }),
      stderr = "",
      exit_code = 0,
    })

    local ok = claim_with_poll_epoch(
      core,
      "claim_contract",
      "owner/repo",
      42,
      current(),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, true)
    t.eq(count_calls("--add-label " .. active_label), 1)
    t.eq(count_calls("--add-assignee"), 0)
  end,

  test_claim_race_rolls_back_only_the_active_label = function()
    mock_claim_env("1")
    t.mock_command("gh issue edit 42 --repo owner/repo --add-label '" .. active_label .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue view 42 --repo owner/repo --json labels,author", {
      stdout = ownership_json({ active_label, foreign_label }),
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue edit 42 --repo owner/repo --remove-label '" .. active_label .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local ok = claim_with_poll_epoch(
      core,
      "claim_contract",
      "owner/repo",
      42,
      current(),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, false)
    t.eq(count_calls("--remove-label " .. active_label), 1)
    t.eq(count_calls("--remove-label " .. foreign_label), 0)
  end,

  test_pr_review_claim_predicate_uses_labels_and_foreign_wins = function()
    mock_claim_env("")
    t.eq(m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
      labels = { active_label },
      author_login = "human",
    }, "github-devloop/issue/owner/repo/42"), true)
    t.eq(m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
      labels = { active_label, foreign_label },
      author_login = "human",
    }, "github-devloop/issue/owner/repo/42"), false)
  end,

  test_pr_review_claim_rederives_when_labels_are_missing = function()
    mock_claim_env("")
    t.mock_command("gh issue view 42 --repo owner/repo --json labels,author", {
      stdout = ownership_json({ active_label }, "human"),
      stderr = "",
      exit_code = 0,
    })

    t.eq(m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
      author_login = "human",
    }, "github-devloop/issue/owner/repo/42"), true)
  end,

  test_release_fresh_reads_and_removes_only_the_active_label = function()
    mock_claim_env("1")
    t.mock_command("gh issue view 42 --repo owner/repo --json labels,author", {
      stdout = ownership_json({ active_label }, "human"),
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue edit 42 --repo owner/repo --remove-label '" .. active_label .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local released = m_claims.release_issue_claim_if_self(
      core,
      "admission",
      "owner/repo",
      42,
      "github-devloop/issue/owner/repo/42",
      "excess-active-intake-claim"
    )

    t.eq(released, true)
    t.eq(count_calls("--remove-label " .. active_label), 1)
    t.eq(count_calls("--remove-assignee"), 0)
  end,

  test_release_never_mutates_a_foreign_label = function()
    mock_claim_env("1")
    t.mock_command("gh issue view 42 --repo owner/repo --json labels,author", {
      stdout = ownership_json({ foreign_label }, "human"),
      stderr = "",
      exit_code = 0,
    })

    local released = m_claims.release_issue_claim_if_self(
      core,
      "admission",
      "owner/repo",
      42,
      "github-devloop/issue/owner/repo/42",
      "excess-active-intake-claim"
    )

    t.eq(released, false)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_claim_payload_carries_the_exact_expected_label = function()
    mock_claim_env("")
    local payload = m_claims.claim_required_payload({
      kind = "external",
      ref = "owner/repo#issue/42",
    })

    t.eq(payload.label, active_label)
    t.eq(payload.owner, "fkst-test-bot")
    t.eq(payload.source_ref.kind, "external")
    t.eq(payload.source_ref.ref, "owner/repo#issue/42")
  end,

  test_claim_owner_normalizes_app_suffix = function()
    parsers_misc.configure_trusted_bot_login("fkst-test-bot[bot]")
    t.eq(m_claims.claim_owner(), "fkst-test-bot")
    parsers_misc.configure_trusted_bot_login(nil)
  end,
}
