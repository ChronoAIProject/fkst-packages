local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local t = h.t
local author_policy = require("testkit_internal.github_author_policy")
local strings = require("contract.strings")

local repo = "owner/repo"

local function mock_bot(login)
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = login or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_authorized_login(login, managed_bot_logins, opts)
  local options = opts or {}
  author_policy.mock_env(t, {
    env = {
      FKST_GITHUB_BOT_LOGIN = options.bot_login or "fkst-test-bot",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = managed_bot_logins or "",
      FKST_GITHUB_AUTHORIZED_LOGINS = login or "",
    },
  }, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
end

local function current_issue(author_login, comments)
  return {
    assignees = {},
    labels = {},
    author_login = author_login,
    comments = comments or {},
  }
end

local function state_marker_comment(author_login)
  return {
    author_login = author_login,
    body = 'github-devloop thinking\n<!-- fkst:github-devloop:state:v1 proposal="x" state="thinking" version="v" -->',
  }
end

local function admission_for(current, repo_name)
  local inputs = m_claims.claim_admission_inputs(current, repo_name)
  local admission, detail = m_claims.claim_admission_precheck(current, inputs)
  return admission, detail, inputs
end

local function json_comments(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    local fields = { '"body":' .. strings.json_string(comment.body or "") }
    if comment.author_login ~= false then
      fields[#fields + 1] = '"author":{"login":' .. strings.json_string(comment.author_login or "fkst-test-bot") .. "}"
    end
    if comment.user_login ~= nil then
      fields[#fields + 1] = '"user":{"login":' .. strings.json_string(comment.user_login) .. "}"
    end
    rendered[#rendered + 1] = "{" .. table.concat(fields, ",") .. "}"
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function issue_row(number, comments)
  return '{"number":' .. tostring(number) .. ',"comments":' .. json_comments(comments) .. ',"author":{"login":"issue-author"}}'
end

local function pr_row(fields)
  local selected = fields or {}
  local parts = {
    '"number":' .. tostring(selected.number or 10),
    '"headRefName":' .. strings.json_string(selected.head or "integration-peer"),
    '"baseRefName":' .. strings.json_string(selected.base or "dev"),
    '"comments":' .. json_comments(selected.comments),
  }
  if selected.author_login ~= false then
    parts[#parts + 1] = '"author":{"login":' .. strings.json_string(selected.author_login or "rollup-peer") .. "}"
  end
  if selected.user_login ~= nil then
    parts[#parts + 1] = '"user":{"login":' .. strings.json_string(selected.user_login) .. "}"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function mock_repo_peer_scan(issue_rows, pr_rows, opts)
  local options = opts or {}
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = options.upstream or "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = options.integration or "integration-fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author", {
    stdout = "[" .. table.concat(issue_rows or {}, ",") .. "]",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author", {
    stdout = "[" .. table.concat(pr_rows or {}, ",") .. "]",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_authorized_state_marker_author_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {
      state_marker_comment("peer-bot[bot]"),
    }))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", inputs.managed))
  end,

  test_unauthorized_state_marker_author_does_not_get_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("")

    local admission, detail, inputs = admission_for(current_issue("drive-by", {
      state_marker_comment("drive-by"),
    }))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-non-whitelisted-author")
    t.eq(m_claims.is_managed_bot_login("drive-by", inputs.managed), false)
  end,

  test_manual_managed_bot_login_seed_still_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("", "manual-peer")

    local admission, detail, inputs = admission_for(current_issue("manual-peer", {}))

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("manual-peer", inputs.managed))
    t.is_nil(inputs.trusted_author_policy)
  end,

  test_observed_peer_set_is_rederived_from_current_issue_comments = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local first_admission, first_detail, first_inputs = admission_for(current_issue("peer-bot", {
      state_marker_comment("peer-bot"),
    }))

    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")

    local second_admission, second_detail, second_inputs = admission_for(current_issue("peer-bot", {}))

    t.eq(first_admission, "denied")
    t.eq(first_detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", first_inputs.managed))
    t.eq(second_admission, "needs-claim")
    t.eq(second_detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", second_inputs.managed), false)
  end,

  test_authorized_repo_issue_state_marker_author_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({
      issue_row(7, {
        state_marker_comment("peer-bot[bot]"),
      }),
    }, {})

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", inputs.managed))
  end,

  test_authorized_repo_pr_state_marker_author_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({}, {
      pr_row({
        author_login = "someone-else",
        head = "feature/work",
        base = "dev",
        comments = { state_marker_comment("peer-bot") },
      }),
    })

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", inputs.managed))
  end,

  test_authorized_rollup_pr_author_gets_managed_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("rollup-peer")
    mock_repo_peer_scan({}, {
      pr_row({ author_login = "rollup-peer[bot]", head = "integration/dev", base = "dev" }),
    }, {
      integration = "integration/dev",
    })

    local admission, detail, inputs = admission_for(current_issue("rollup-peer", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("rollup-peer", inputs.managed))
  end,

  test_repo_peer_discovery_fails_closed_for_unauthorized_candidates = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("")
    mock_repo_peer_scan({
      issue_row(7, {
        state_marker_comment("drive-by"),
      }),
    }, {
      pr_row({ author_login = "drive-by", head = "integration-drive-by", base = "dev" }),
    })

    local admission, detail, inputs = admission_for(current_issue("drive-by", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-non-whitelisted-author")
    t.eq(m_claims.is_managed_bot_login("drive-by", inputs.managed), false)
  end,

  test_self_authored_repo_activity_is_ignored_as_peer_source = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({
      issue_row(7, {
        state_marker_comment("fkst-test-bot"),
      }),
    }, {
      pr_row({ author_login = "fkst-test-bot", head = "integration-fkst-test-bot", base = "dev" }),
    })

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "needs-claim")
    t.eq(detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", inputs.managed), false)
  end,

  test_repo_peer_set_is_rederived_from_current_scan_results = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({
      issue_row(7, {
        state_marker_comment("peer-bot"),
      }),
    }, {})

    local first_admission, first_detail, first_inputs = admission_for(current_issue("peer-bot", {}), repo)

    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({}, {})

    local second_admission, second_detail, second_inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(first_admission, "denied")
    t.eq(first_detail.action, "skip-fork-peer-bot")
    t.is_true(m_claims.is_managed_bot_login("peer-bot", first_inputs.managed))
    t.eq(second_admission, "needs-claim")
    t.eq(second_detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", second_inputs.managed), false)
  end,

  test_malformed_or_mismatched_repo_activity_does_not_discover_peer = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({
      issue_row(7, {
        { author_login = "peer-bot", body = '<!-- fkst:github-devloop:state:v1 -->' },
        { author_login = "peer-bot", body = 'fkst:github-devloop:state:v1 proposal="x" state="thinking"' },
        { author_login = "peer-bot", user_login = "other-bot", body = '<!-- fkst:github-devloop:state:v1 proposal="x" state="thinking" -->' },
        { author_login = false, body = '<!-- fkst:github-devloop:state:v1 proposal="x" state="thinking" -->' },
      }),
    }, {
      pr_row({ author_login = "peer-bot", head = "integration-peer-bot", base = "release" }),
      pr_row({ author_login = "peer-bot", head = "integration-peer-bot", base = "dev" }),
      pr_row({ author_login = "peer-bot", head = "feature/peer-bot", base = "dev" }),
      pr_row({ author_login = false, head = "integration-peer-bot", base = "dev" }),
      pr_row({ author_login = "peer-bot", user_login = "other-bot", head = "integration-peer-bot", base = "dev" }),
    })

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "needs-claim")
    t.eq(detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", inputs.managed), false)
  end,
}
