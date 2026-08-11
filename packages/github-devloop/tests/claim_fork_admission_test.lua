local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local core = h.core
local forks = require("devloop.forks")
local t = h.t
local author_policy = require("testkit_internal.github_author_policy")
local claim_helpers = require("tests.claim_test_helpers")
local claim_with_poll_epoch = claim_helpers.claim_with_poll_epoch
local count_calls = claim_helpers.count_calls
local mock_bot = claim_helpers.mock_bot

local function mock_authorized_login(login, bot_login, managed_bot_logins)
  author_policy.mock_env(t, {
    env = {
      FKST_GITHUB_BOT_LOGIN = bot_login or "fkst-test-bot",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = managed_bot_logins or "",
      FKST_GITHUB_AUTHORIZED_LOGINS = login or "",
    },
  }, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
end

local function mock_repo_collaborator_authorization(stdout)
  t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZE_REPO_COLLABORATORS"', {
    stdout = "1",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/collaborators?permission=push&per_page=100'", {
    stdout = stdout or '[{"login":"write-collab","permissions":{"push":true}}]',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_org_member_authorization(stdout)
  t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZE_ORG_MEMBERS"', {
    stdout = "1",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'orgs/owner/members?per_page=100'", {
    stdout = stdout or '[{"login":"org-member"}]',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_complete_peer_discovery()
  t.mock_command("gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author", { stdout = "[]", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "integration-fkst-test-bot", stderr = "", exit_code = 0 })
  t.mock_command("gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author", { stdout = "[]", stderr = "", exit_code = 0 })
end

local function encode_json_string(value)
  return '"' .. tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")
    .. '"'
end

local function issue_state_json(fields)
  local selected = fields or {}
  local comments = {}
  for _, comment in ipairs(selected.comments or {}) do
    table.insert(comments, '{"body":' .. encode_json_string(comment.body or "")
      .. ',"author":{"login":' .. encode_json_string(comment.author_login or "fkst-test-bot") .. "}}")
  end
  return '{"title":' .. encode_json_string(selected.title or "Implement fork isolation")
    .. ',"createdAt":' .. encode_json_string(selected.created_at or "2026-06-03T01:00:00Z")
    .. ',"updatedAt":' .. encode_json_string(selected.updated_at or "2026-06-03T01:02:03Z")
    .. ',"state":' .. encode_json_string(selected.state or "OPEN")
    .. ',"labels":[],"comments":[' .. table.concat(comments, ",")
    .. '],"assignees":[],"author":{"login":' .. encode_json_string(selected.author_login or "human") .. "}}\n"
end

local function self_current(extra)
  local fields = extra or {}
  return {
    assignees = fields.assignees or {},
    labels = fields.labels or {},
    title = fields.title or "Implement fork isolation",
    state = fields.state or "OPEN",
    author_login = fields.author_login or "fkst-test-bot",
    comments = fields.comments or {},
    created_at = fields.created_at or "2026-06-03T01:00:00Z",
    updated_at = fields.updated_at,
  }
end

local function fork_parent_issue_fields(marker_body, marker_author, created_at)
  return {
    author_login = "human",
    created_at = created_at,
    comments = {
      {
        body = marker_body,
        author_login = marker_author,
      },
    },
  }
end

local function iso_at(seconds)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds)
end

local function created_inside_grace()
  return iso_at(now())
end

local function created_after_grace()
  return iso_at(now() - (3 * 60 * 60) - 1)
end

local function capture_raises(fn)
  local old_raise = raise
  local raised = {}
  raise = function(queue, payload)
    table.insert(raised, {
      queue = queue,
      payload = payload,
    })
  end
  local ok, result = pcall(fn)
  raise = old_raise
  if not ok then
    error(result)
  end
  return result, raised
end

local function capture_info_logs(fn)
  local previous_info = log.info
  local logs = {}
  log.info = function(message)
    table.insert(logs, tostring(message))
  end
  local ok, result = pcall(fn)
  log.info = previous_info
  if not ok then
    error(result, 0)
  end
  return result, logs
end

return {
  test_fork_grace_elapsed_uses_created_at_and_clamps_future_age = function()
    local elapsed, reason, age = m_claims.fork_grace_elapsed("owner/repo", 42, {
      created_at = "2026-06-03T00:00:00Z",
      updated_at = "2026-06-03T23:59:00Z",
    }, 1782835200, 3 * 60 * 60)
    t.eq(elapsed, true)
    t.eq(reason, "fork-grace-elapsed")
    t.is_true(age >= 3 * 60 * 60)

    elapsed, reason, age = m_claims.fork_grace_elapsed("owner/repo", 42, {
      created_at = "2999-01-01T00:00:00Z",
      updated_at = "2026-06-03T01:02:03Z",
    }, 1782835200, 3 * 60 * 60)
    t.eq(elapsed, false)
    t.eq(reason, "fork-grace-pending")
    t.eq(age, 0)

    elapsed, reason, age = m_claims.fork_grace_elapsed("owner/repo", 42, {
      updated_at = "2026-06-03T01:02:03Z",
    }, 1782835200, 3 * 60 * 60)
    t.eq(elapsed, false)
    t.eq(reason, "fork-grace-age-unknown")
    t.eq(age, nil)
  end,

  test_other_author_unassigned_issue_inside_grace_skips_without_forking = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 44), {
      stdout = issue_state_json({ author_login = "human", created_at = created_inside_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, logs
    local _, raised = capture_raises(function()
      ok, logs = capture_info_logs(function()
        return claim_with_poll_epoch(core,
          "claim_contract",
          "owner/repo",
          44,
          self_current({ author_login = "human", created_at = created_inside_grace() }),
          "github-devloop/issue/owner/repo/44"
        )
      end)
    end)

    t.eq(ok, false)
    t.eq(count_calls("gh issue edit"), 0)
    t.eq(#raised, 0)
    local joined = table.concat(logs, "\n")
    t.is_true(joined:find("outcome=skip-fork-grace", 1, true) ~= nil)
    t.is_true(joined:find("reason=fork-grace-pending", 1, true) ~= nil)
    t.is_true(joined:find("age_seconds=", 1, true) ~= nil)
    t.is_true(joined:find("grace_seconds=10800", 1, true) ~= nil)
  end,

  test_managed_bot_author_unassigned_issue_after_grace_skips_without_forking = function()
    mock_bot("fkst-test-bot", "1")
    author_policy.mock_env(t, {
      env = {
        FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "peer-bot[bot],other-peer",
      },
    }, {
      configure_trusted_bot_login = h.mock_author_policy_configure,
    })
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 45), {
      stdout = issue_state_json({ author_login = "peer-bot[bot]", created_at = created_after_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, captured_logs = capture_info_logs(function()
      local result, raised = capture_raises(function()
        return claim_with_poll_epoch(core,
          "claim_contract",
          "owner/repo",
          45,
          self_current({ author_login = "peer-bot[bot]", created_at = created_after_grace() }),
          "github-devloop/issue/owner/repo/45"
        )
      end)
      t.eq(#raised, 0)
      return result
    end)

    t.eq(ok, false)
    t.eq(count_calls("gh issue edit"), 0)
    local logs = table.concat(captured_logs, "\n")
    t.is_true(logs:find("outcome=skip-peer-authored", 1, true) ~= nil)
  end,

  test_managed_peer_app_author_with_existing_self_claim_skips_as_peer_authored = function()
    local admission, detail = m_claims.claim_admission_precheck(self_current({
      assignees = { "app/fkst-test-bot" },
      author_login = "app/peer-bot",
    }), {
      owner = "fkst-test-bot",
      status = "self",
      claim_mode = "assignee",
      managed = {
        ["peer-bot"] = true,
      },
    })

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-peer-authored")
  end,

  test_own_app_author_with_existing_self_claim_remains_held = function()
    local admission = m_claims.claim_admission_precheck(self_current({
      assignees = { "app/fkst-test-bot" },
      author_login = "app/fkst-test-bot",
    }), {
      owner = "fkst-test-bot",
      status = "self",
      claim_mode = "assignee",
      managed = {
        ["peer-bot"] = true,
      },
    })

    t.eq(admission, "held")
  end,

  test_post_admission_self_held_org_member_continues_without_repository_peer_discovery = function()
    mock_bot("fkst-test-bot", "")
    mock_authorized_login("")
    mock_org_member_authorization()

    local ok = m_claims.claim_issue_for_management(
      "claim_contract",
      "owner/repo",
      42,
      self_current({
        assignees = { "fkst-test-bot" },
        author_login = "org-member",
      }),
      "github-devloop/issue/owner/repo/42"
    )

    t.eq(ok, true)
    t.eq(count_calls("gh api --paginate --slurp 'orgs/owner/members?per_page=100'"), 1)
    t.eq(count_calls("gh issue list --repo owner/repo --state all"), 0)
    t.eq(count_calls("gh pr list --repo owner/repo --state all"), 0)
  end,

  test_other_author_unassigned_issue_after_grace_raises_self_assigned_fork = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 43), {
      stdout = issue_state_json({ author_login = "human", created_at = created_after_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        43,
        self_current({ author_login = "human", created_at = created_after_grace() }),
        "github-devloop/issue/owner/repo/43"
      )
    end)

    t.eq(ok, false)
    t.eq(count_calls("gh issue edit"), 0)
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(raised[1].payload.assignees[1], "fkst-test-bot")
    t.eq(raised[1].payload.dedup_key, forks.fork_issue_dedup_key("owner/repo", 43))
    t.eq(raised[1].payload.post_create_blocked_by.blocked_issue_number, 43)
    t.eq(raised[1].payload.post_create_blocked_by.dedup_key, forks.fork_issue_dedup_key("owner/repo", 43) .. "/blocked-by")
  end,

  test_repo_write_collaborator_authorizes_claim_admission_path = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("")
    mock_repo_collaborator_authorization()
    mock_complete_peer_discovery()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 43), {
      stdout = issue_state_json({ author_login = "write-collab", created_at = created_after_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        43,
        self_current({ author_login = "write-collab", created_at = created_after_grace() }),
        "github-devloop/issue/owner/repo/43"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.dedup_key, forks.fork_issue_dedup_key("owner/repo", 43))
    t.eq(count_calls("gh api --paginate --slurp 'repos/owner/repo/collaborators?permission=push&per_page=100'"), 1)
  end,

  test_org_member_authorizes_claim_admission_path = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("")
    mock_org_member_authorization()
    mock_complete_peer_discovery()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 43), {
      stdout = issue_state_json({ author_login = "org-member", created_at = created_after_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        43,
        self_current({ author_login = "org-member", created_at = created_after_grace() }),
        "github-devloop/issue/owner/repo/43"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.dedup_key, forks.fork_issue_dedup_key("owner/repo", 43))
    t.eq(count_calls("gh api --paginate --slurp 'orgs/owner/members?per_page=100'"), 1)
  end,

  test_non_whitelisted_other_author_skips_before_fork_side_effects = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("")

    local ok, captured_logs = capture_info_logs(function()
      local result, raised = capture_raises(function()
        return claim_with_poll_epoch(core,
          "claim_contract",
          "owner/repo",
          43,
          self_current({ author_login = "human", created_at = created_after_grace() }),
          "github-devloop/issue/owner/repo/43"
        )
      end)
      t.eq(#raised, 0)
      return result
    end)

    t.eq(ok, false)
    t.eq(count_calls("gh issue edit"), 0)
    t.is_true(table.concat(captured_logs, "\n"):find("outcome=skip-non-whitelisted-author", 1, true) ~= nil)
  end,

  test_other_author_fork_revalidates_closed_issue_before_raise = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 43), {
      stdout = issue_state_json({ state = "CLOSED", author_login = "human", created_at = created_after_grace() }),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        43,
        self_current({ author_login = "human", state = "OPEN", created_at = created_after_grace() }),
        "github-devloop/issue/owner/repo/43"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_missing_author_unassigned_issue_skips_without_assigning_or_forking = function()
    mock_bot("fkst-test-bot", "1")

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        { assignees = {}, labels = {}, title = "Unknown author", comments = {} },
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_existing_fork_parent_ledger_skips_duplicate_fork = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    local dedup_key = forks.fork_issue_dedup_key("owner/repo", 42)
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 42), {
      stdout = issue_state_json(fork_parent_issue_fields(
        '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. dedup_key .. '" issue="99" -->',
        "fkst-test-bot"
      )),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(fork_parent_issue_fields(
          '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. dedup_key .. '" issue="99" -->',
          "fkst-test-bot"
        )),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_existing_peer_bot_fork_parent_ledger_skips_duplicate_fork = function()
    mock_bot("loning", "1")
    author_policy.mock_env(t, {
      env = {
        FKST_GITHUB_BOT_LOGIN = "loning",
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "loning,ElonSG",
        FKST_GITHUB_AUTHORIZED_LOGINS = "human",
      },
    }, {
      configure_trusted_bot_login = h.mock_author_policy_configure,
    })
    mock_complete_peer_discovery()
    local dedup_key = forks.fork_issue_dedup_key("owner/repo", 42)
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 42), {
      stdout = issue_state_json(fork_parent_issue_fields(
        '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. dedup_key .. '" issue="99" -->',
        "ElonSG",
        created_after_grace()
      )),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(fork_parent_issue_fields(
          '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. dedup_key .. '" issue="99" -->',
          "ElonSG",
          created_after_grace()
        )),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_existing_fork_parent_intent_skips_duplicate_fork = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    local dedup_key = forks.fork_issue_dedup_key("owner/repo", 42)
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 42), {
      stdout = issue_state_json(fork_parent_issue_fields(
        '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. dedup_key .. '" -->',
        "fkst-test-bot"
      )),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(fork_parent_issue_fields(
          '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. dedup_key .. '" -->',
          "fkst-test-bot"
        )),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 0)
    t.eq(count_calls("gh issue edit"), 0)
  end,

  test_forged_fork_parent_intent_does_not_suppress_fork = function()
    mock_bot("fkst-test-bot", "1")
    mock_authorized_login("human")
    mock_complete_peer_discovery()
    local dedup_key = forks.fork_issue_dedup_key("owner/repo", 42)
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 42), {
      stdout = issue_state_json(fork_parent_issue_fields(
        '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. dedup_key .. '" -->',
        "human",
        created_after_grace()
      )),
      stderr = "",
      exit_code = 0,
    })

    local ok, raised = capture_raises(function()
      return claim_with_poll_epoch(core,
        "claim_contract",
        "owner/repo",
        42,
        self_current(fork_parent_issue_fields(
          '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. dedup_key .. '" -->',
          "human",
          created_after_grace()
        )),
        "github-devloop/issue/owner/repo/42"
      )
    end)

    t.eq(ok, false)
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.dedup_key, dedup_key)
    t.eq(count_calls("gh issue edit"), 0)
  end,
}
