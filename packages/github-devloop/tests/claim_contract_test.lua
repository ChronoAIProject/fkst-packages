local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t
local claim_helpers = require("tests.claim_test_helpers")
local claim_with_poll_epoch = claim_helpers.claim_with_poll_epoch
local count_calls = claim_helpers.count_calls

local active_label = "fkst-dev:claimed:fkst-test-bot"
local foreign_label = "fkst-dev:claimed:peer-bot"

local function ownership_json(labels, author_login)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', tostring(label)))
  end
<<<<<<< HEAD
  return '{"labels":[' .. table.concat(rendered, ",") .. '],"author":{"login":"'
=======
  return '{"assignees":[' .. table.concat(rendered, ",") .. '],"labels":[],"author":{"login":"'
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
    .. tostring(author_login or "fkst-test-bot") .. '"}}\n'
end

local function current(extra)
  local fields = extra or {}
  return {
<<<<<<< HEAD
=======
    assignees = fields.assignees or {},
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
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
  end
end

return {
<<<<<<< HEAD
  test_issue_claim_state_uses_only_the_complete_label_family = function()
    mock_claim_env("")
    t.eq(m_claims.issue_claim_state({}), "unassigned")
    t.eq(m_claims.issue_claim_state({ active_label }), "self")
    t.eq(m_claims.issue_claim_state({ foreign_label }), "other")
    t.eq(m_claims.issue_claim_state({ active_label, foreign_label }), "other")
=======
  test_issue_claim_state_requires_complete_carrier_projection = function()
    t.eq(m_claims.issue_claim_state({ { login = "fkst-test-bot" } }, "fkst-test-bot"), "other")
    t.eq(m_claims.issue_claim_state({}, "fkst-test-bot", {}), "unassigned")
    t.eq(m_claims.issue_claim_state({ { login = "fkst-test-bot" } }, "fkst-test-bot", {}), "self")
    t.eq(m_claims.issue_claim_state({ { login = "human" } }, "fkst-test-bot", {}), "other")
    t.eq(m_claims.issue_claim_state({ { login = "fkst-test-bot" }, { login = "other-bot" } }, "fkst-test-bot", {}), "other")
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
  end,

  test_is_self_owned_issue_allows_active_label_or_unclaimed_self_author = function()
    mock_claim_env("")
    t.eq(m_claims.is_self_owned_issue(nil, "fkst-test-bot"), false)
<<<<<<< HEAD
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
=======
    t.eq(m_claims.is_self_owned_issue({ assignees = { "fkst-test-bot" }, labels = {}, author_login = "human" }, "fkst-test-bot"), true)
    t.eq(m_claims.is_self_owned_issue({ assignees = {}, labels = {}, author_login = "fkst-test-bot" }, "fkst-test-bot"), true)
    t.eq(m_claims.is_self_owned_issue({ assignees = {}, labels = {}, author_login = "human" }, "fkst-test-bot"), false)
    t.eq(m_claims.is_self_owned_issue({ assignees = { "human" }, labels = {}, author_login = "fkst-test-bot" }, "fkst-test-bot"), false)
    t.eq(select("#", m_claims.is_self_owned_issue(nil, "fkst-test-bot")), 1)
  end,

  test_dry_run_claim_proceeds_without_assigning = function()
    mock_bot("fkst-test-bot", "")

    local ok = claim_with_poll_epoch(core,
      "claim_contract",
      "owner/repo",
      42,
      self_current(),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, true)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_claim_assigns_then_verifies_self_only_winner = function()
    mock_bot("fkst-test-bot", "1")
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --add-assignee 'fkst-test-bot'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", 42), {
      stdout = ownership_json({ "fkst-test-bot" }),
      stderr = "",
      exit_code = 0,
    })

    local ok = claim_with_poll_epoch(core,
      "claim_contract",
      "owner/repo",
      42,
      self_current(),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, true)
    t.eq(count_calls("--add-assignee fkst-test-bot"), 1)
    t.eq(count_calls("--remove-assignee fkst-test-bot"), 0)
  end,

  test_claim_permission_denied_is_terminal_skip_without_crashing_or_unassigning = function()
    mock_bot("fkst-test-bot", "1")
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --add-assignee 'fkst-test-bot'", {
      stdout = "",
      stderr = "GraphQL: Could not resolve to a User with the login of 'fkst-test-bot'. (permission-denied)\n",
      exit_code = 1,
    })

    local ok, captured_logs = capture_warn_logs(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(count_calls("--add-assignee fkst-test-bot"), 1)
    t.eq(count_calls("--remove-assignee fkst-test-bot"), 0)
    local logs = table.concat(captured_logs, "\n")
    t.is_true(logs:find("tag=SKIP", 1, true) ~= nil)
    t.is_true(logs:find("error_class=intake-skip-unclaimable", 1, true) ~= nil)
    t.is_true(logs:find("source_ref=external:owner/repo#issue/42", 1, true) ~= nil)
    t.is_true(logs:find("WHY=assign permission-denied is permanent", 1, true) ~= nil)
  end,

  test_claim_transient_assign_error_propagates = function()
    mock_bot("fkst-test-bot", "1")
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --add-assignee 'fkst-test-bot'", {
      stdout = "",
      stderr = "HTTP 502: upstream unavailable\n",
      exit_code = 1,
    })

    local ok, err = pcall(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("gh-command-failed", 1, true) ~= nil)
    t.eq(count_calls("--add-assignee fkst-test-bot"), 1)
    t.eq(count_calls("--remove-assignee fkst-test-bot"), 0)
  end,

  test_claim_loss_unassigns_only_self_and_skips = function()
    mock_bot("fkst-test-bot", "1")
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --add-assignee 'fkst-test-bot'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", 42), {
      stdout = ownership_json({ "other-bot" }),
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --remove-assignee 'fkst-test-bot'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local ok = claim_with_poll_epoch(core,
      "claim_contract",
      "owner/repo",
      42,
      self_current(),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, false)
    t.eq(count_calls("--remove-assignee fkst-test-bot"), 1)
    t.eq(count_calls("--remove-assignee other-bot"), 0)
  end,

  test_non_self_assignee_is_never_touched = function()
    mock_bot("fkst-test-bot", "1")

    local ok = claim_with_poll_epoch(core,
      "claim_contract",
      "owner/repo",
      42,
      { assignees = { { login = "human" } }, labels = {} },
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, false)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_verify_pr_review_issue_claim_predicate_contract = function()
    mock_bot("fkst-test-bot", "")
    local function verify(assignees, author_login)
      return m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
        assignees = assignees, labels = {}, author_login = author_login,
      }, "github-devloop/issue/owner/repo/42")
    end
    t.eq(verify({ "fkst-test-bot" }, "human"), true)
    t.eq(verify({ "human" }, "fkst-test-bot"), false)
    t.eq(verify({}, "fkst-test-bot"), true)
    t.eq(verify({}, "human"), false)
    t.eq(select("#", verify({ "fkst-test-bot" }, "human")), 1)

    local decision = m_claims.pr_review_issue_claim_decision("claim_contract", "owner/repo", 42, {
      assignees = { "human" }, labels = {}, author_login = "fkst-test-bot",
    }, "github-devloop/issue/owner/repo/42")
    t.eq(decision.owned, false)
    t.eq(decision.claim_state, "other")
    t.eq(m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", nil, nil, "github-devloop/pr/owner/repo/7"), false)
  end,

  test_verify_pr_review_issue_claim_uses_configured_claim_owner_before_assert = function()
    mock_bot("real-bot", "")

    local self_owned = m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
      assignees = { "real-bot" }, labels = {}, author_login = "human",
    }, "github-devloop/issue/owner/repo/42")
    local other_owned = m_claims.verify_pr_review_issue_claim("claim_contract", "owner/repo", 42, {
      assignees = { "fkst-test-bot" }, labels = {}, author_login = "human",
    }, "github-devloop/issue/owner/repo/42")
    devloop_base.configure_trusted_bot_login(nil)

    t.eq(self_owned, true)
    t.eq(other_owned, false)
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
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
    t.eq(payload.owner, nil)
    t.eq(payload.source_ref.kind, "external")
    t.eq(payload.source_ref.ref, "owner/repo#issue/42")
  end,

  test_claim_owner_normalizes_app_suffix = function()
    devloop_base.configure_trusted_bot_login("fkst-test-bot[bot]")
    t.eq(m_claims.claim_owner(), "fkst-test-bot")
    devloop_base.configure_trusted_bot_login(nil)
  end,
}
