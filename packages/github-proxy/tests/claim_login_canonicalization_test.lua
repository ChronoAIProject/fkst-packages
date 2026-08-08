local core = require("core")
local author_policy = require("testkit_internal.github_author_policy")
local t = fkst.test

local repo = "owner/x"
local issue_number = 42

local function claim_payload(owner, label)
  return {
    claim = {
      owner = owner,
      label = label,
      source_ref = {
        kind = "external",
        ref = repo .. "#issue/" .. tostring(issue_number),
      },
    },
  }
end

local function mock_ownership(assignees, labels, exclusive)
  author_policy.mock_env(t, nil, { times = 2 })
  for _ = 1, 2 do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive or "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("gh api repos/owner/x/issues/42", {
    stdout = '{"assignees":' .. assignees .. ',"labels":' .. (labels or "[]") .. "}\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_live_claim_verification_canonicalizes_mixed_case_assignee = function()
    local payload = claim_payload("fkst-test-bot")
    mock_ownership('[{"login":"FKST-Test-Bot"}]')

    t.is_true(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_canonicalizes_mixed_case_assignee = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = { assignees = { { login = "FKST-Test-Bot" } }, labels = {} }
    author_policy.mock_env(t)

    t.is_true(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_canonicalizes_bot_suffix = function()
    local payload = claim_payload("fkst-test-bot")
    mock_ownership('[{"login":"FKST-Test-Bot[bot]"}]')

    t.is_true(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_canonicalizes_bot_suffix = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = { assignees = { { login = "FKST-Test-Bot[bot]" } }, labels = {} }
    author_policy.mock_env(t)

    t.is_true(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_refuses_owner_not_matching_authenticated_principal = function()
    local payload = claim_payload("peer-bot")
    mock_ownership('[{"login":"peer-bot"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
  end,

  test_in_memory_claim_verification_refuses_owner_not_matching_authenticated_principal = function()
    local payload = claim_payload("peer-bot")
    local issue = { assignees = { { login = "peer-bot" } }, labels = {} }
    author_policy.mock_env(t)

    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_different_assignee = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = { assignees = { { login = "someone-else" } }, labels = {} }
    mock_ownership('[{"login":"someone-else"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_empty_assignees = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = { assignees = {}, labels = {} }
    mock_ownership("[]")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_multiple_assignees = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = {
      assignees = {
        { login = "FKST-Test-Bot" },
        { login = "someone-else" },
      },
      labels = {},
    }
    mock_ownership('[{"login":"FKST-Test-Bot"},{"login":"someone-else"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_assignee_claim_verification_refuses_foreign_claim_label = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = {
      assignees = { { login = "FKST-Test-Bot" } },
      labels = { { name = "fkst-dev:claimed:peer" } },
    }
    mock_ownership('[{"login":"FKST-Test-Bot"}]', '[{"name":"fkst-dev:claimed:peer"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_accepts_own_label_with_human_assignee = function()
    local label = "fkst-dev:claimed:fkst-test-bot"
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), true)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), true)
  end,

  test_label_claim_verification_refuses_label_derived_from_different_owner = function()
    local label = "fkst-dev:claimed:peer"
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_refuses_derived_label_in_exclusive_posture = function()
    local label = "fkst-dev:claimed:fkst-test-bot"
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]', "1")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_refuses_managed_peer_assignee = function()
    local label = "fkst-dev:claimed:fkst-test-bot"
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "ElonSG" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"ElonSG"}]', '[{"name":"' .. label .. '"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_incomplete_label_projection = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = { assignees = { { login = "FKST-Test-Bot" } } }
    author_policy.mock_env(t, nil, { times = 2 })
    t.mock_command("gh api repos/owner/x/issues/42", {
      stdout = '{"assignees":[{"login":"FKST-Test-Bot"}]}\n', stderr = "", exit_code = 0,
    })

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,
}
