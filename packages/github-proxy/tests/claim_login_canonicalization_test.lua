local core = require("core")
local claim_carriers = require("devloop.claim_carriers")
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

local function mock_claim_mode(mode, times)
  for _ = 1, times or 1 do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_MODE"', {
      stdout = mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_ownership(assignees, labels, exclusive, mode, suffix, digest_hex_length)
  author_policy.mock_env(t, nil, { times = 2 })
  mock_claim_mode(mode, 2)
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_SUFFIX"', {
      stdout = suffix or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH"', {
      stdout = digest_hex_length or "",
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
    mock_claim_mode()

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
    mock_claim_mode()

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
      labels = { { name = claim_carriers.derived_label("peer", 32) } },
    }
    mock_ownership('[{"login":"FKST-Test-Bot"}]', '[{"name":"' .. claim_carriers.derived_label("peer", 32) .. '"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_assignee_mode_refuses_label_claim_carrier = function()
    local label = claim_carriers.derived_label("fkst-test-bot", 32)
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]')

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_mode_refuses_assignee_claim_carrier = function()
    local payload = claim_payload("fkst-test-bot")
    local issue = {
      assignees = { { login = "FKST-Test-Bot" } },
      labels = {},
    }
    mock_ownership('[{"login":"FKST-Test-Bot"}]', nil, nil, "label")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_accepts_own_label_with_human_assignee = function()
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    local label = spec.name
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label, description = spec.description } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label
      .. '","description":"' .. spec.description .. '"}]', nil, "label")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), true)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), true)
  end,

  test_label_claim_verification_uses_configured_short_derived_label_as_only_active_identity = function()
    local short_spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 8)
    local short_payload = claim_payload("fkst-test-bot", short_spec.name)
    local short_issue = {
      assignees = { { login = "human" } },
      labels = { { name = short_spec.name, description = short_spec.description } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. short_spec.name
      .. '","description":"' .. short_spec.description .. '"}]', "", "label", nil, "8")

    t.eq(core.verify_issue_claim_before_write(short_payload, repo, issue_number, "claim_test"), true)
    t.eq(core.verify_issue_claim_in_issue(short_issue, short_payload, repo, issue_number, "claim_test"), true)

    local former_spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    local former_payload = claim_payload("fkst-test-bot", former_spec.name)
    local former_issue = {
      assignees = { { login = "human" } },
      labels = { { name = former_spec.name, description = former_spec.description } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. former_spec.name
      .. '","description":"' .. former_spec.description .. '"}]', "", "label", nil, "8")

    t.eq(core.verify_issue_claim_before_write(former_payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(former_issue, former_payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_uses_declared_suffix_as_the_only_self_label = function()
    local label = "fkst-dev:claimed:macstudio-4"
    local description = "fkst-dev-label-mode-ownership-claim owner=fkst-test-bot"
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label, description = description } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label
      .. '","description":"' .. description .. '"}]', "", "label", "macstudio-4")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), true)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), true)

    local derived = claim_carriers.derived_label("fkst-test-bot", 32)
    local derived_payload = claim_payload("fkst-test-bot", derived)
    local derived_issue = {
      assignees = { { login = "human" } },
      labels = { { name = derived } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. derived .. '"}]', "", "label", "macstudio-4")
    t.eq(core.verify_issue_claim_before_write(derived_payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(derived_issue, derived_payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_fails_closed_on_forced_owner_collision = function()
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    local collision_description = "fkst-dev-label-mode-ownership-claim owner=peer-bot"
    local payload = claim_payload("fkst-test-bot", spec.name)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = spec.name, description = collision_description } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. spec.name
      .. '","description":"' .. collision_description .. '"}]', nil, "label")

    local live_ok, live_err = pcall(
      core.verify_issue_claim_before_write,
      payload,
      repo,
      issue_number,
      "claim_test"
    )
    local in_memory_ok, in_memory_err = pcall(
      core.verify_issue_claim_in_issue,
      issue,
      payload,
      repo,
      issue_number,
      "claim_test"
    )

    t.eq(live_ok, false)
    t.is_true(tostring(live_err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(live_err))
    t.eq(in_memory_ok, false)
    t.is_true(tostring(in_memory_err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(in_memory_err))
  end,

  test_label_claim_verification_refuses_label_derived_from_different_owner = function()
    local label = claim_carriers.derived_label("peer", 32)
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]', nil, "label")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_refuses_derived_label_in_exclusive_posture = function()
    local label = claim_carriers.derived_label("fkst-test-bot", 32)
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"human"}]', '[{"name":"' .. label .. '"}]', "1", "label")

    t.eq(core.verify_issue_claim_before_write(payload, repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(issue, payload, repo, issue_number, "claim_test"), false)
  end,

  test_label_claim_verification_refuses_managed_peer_assignee = function()
    local label = claim_carriers.derived_label("fkst-test-bot", 32)
    local payload = claim_payload("fkst-test-bot", label)
    local issue = {
      assignees = { { login = "ElonSG" } },
      labels = { { name = label } },
    }
    mock_ownership('[{"login":"ElonSG"}]', '[{"name":"' .. label .. '"}]', nil, "label")

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
