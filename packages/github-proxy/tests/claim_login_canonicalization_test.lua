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

local function mock_ownership(assignees, labels)
  author_policy.mock_env(t, nil, { times = 2 })
  t.mock_command("gh api repos/owner/x/issues/42", {
    stdout = '{"assignees":' .. assignees .. ',"labels":' .. (labels or "[]") .. "}\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_live_claim_verification_canonicalizes_mixed_case_assignee = function()
    local payload = claim_payload("elonsg")
    mock_ownership('[{"login":"ElonSG"}]')

    t.is_true(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_canonicalizes_mixed_case_assignee = function()
    local payload = claim_payload("elonsg")
    local issue = { assignees = { { login = "ElonSG" } }, labels = {} }

    t.is_true(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_canonicalizes_mixed_case_owner = function()
    local payload = claim_payload("ElonSG")
    mock_ownership('[{"login":"elonsg"}]')

    t.is_true(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_canonicalizes_mixed_case_owner = function()
    local payload = claim_payload("ElonSG")
    local issue = { assignees = { { login = "elonsg" } }, labels = {} }

    t.is_true(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_canonicalizes_bot_suffix = function()
    local payload = claim_payload("elonsg")
    mock_ownership('[{"login":"ElonSG[bot]"}]')

    t.is_true(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_canonicalizes_bot_suffix = function()
    local payload = claim_payload("elonsg")
    local issue = { assignees = { { login = "ElonSG[bot]" } }, labels = {} }

    t.is_true(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"))
  end,

  test_claim_verification_refuses_different_assignee = function()
    local payload = claim_payload("elonsg")
    local issue = { assignees = { { login = "someone-else" } }, labels = {} }
    mock_ownership('[{"login":"someone-else"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_empty_assignees = function()
    local payload = claim_payload("elonsg")
    local issue = { assignees = {}, labels = {} }
    mock_ownership("[]")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_multiple_assignees = function()
    local payload = claim_payload("elonsg")
    local issue = {
      assignees = {
        { login = "ElonSG" },
        { login = "someone-else" },
      },
      labels = {},
    }
    mock_ownership('[{"login":"ElonSG"},{"login":"someone-else"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_assignee_claim_verification_refuses_foreign_claim_label = function()
    local payload = claim_payload("elonsg")
    local issue = {
      assignees = { { login = "ElonSG" } },
      labels = { { name = "fkst-dev:claimed:peer" } },
    }
    mock_ownership('[{"login":"ElonSG"}]', '[{"name":"fkst-dev:claimed:peer"}]')

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
    local payload = claim_payload("elonsg")
    local issue = { assignees = { { login = "ElonSG" } } }
    author_policy.mock_env(t)
    t.mock_command("gh api repos/owner/x/issues/42", {
      stdout = '{"assignees":[{"login":"ElonSG"}]}\n', stderr = "", exit_code = 0,
    })

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,
}
