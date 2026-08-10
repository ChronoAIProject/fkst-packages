local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local t = h.t
local author_policy = require("testkit_internal.github_author_policy")
local gh_argv = require("testkit_internal.gh_argv_mock")
local strings = require("contract.strings")
local github_author_policy = require("devloop.github_author_policy")
local entity_list_cache = require("devloop.entity_list_cache")

local repo = "owner/repo"
local issue_peer_command = "gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author"
local pr_peer_command = "gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author"

local function count_calls(command)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, command) then
      count = count + 1
    end
  end
  return count
end

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
  t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
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

local admission_epoch_sequence = 0

local function admission_for(current, repo_name, poll_key)
  if repo_name ~= nil and poll_key == nil then
    admission_epoch_sequence = admission_epoch_sequence + 1
    cache_set(entity_list_cache.poll_epoch_cache_key(repo_name), "")
    local recorded, allocated_epoch = entity_list_cache.record_poll_epoch(
      repo_name,
      "claim-peer-discovery-" .. tostring(admission_epoch_sequence)
    )
    t.is_true(recorded)
    poll_key = allocated_epoch
  end
  local inputs = m_claims.claim_admission_inputs(current, repo_name, poll_key)
  local admission, detail = m_claims.claim_admission_precheck(current, inputs)
  return admission, detail, inputs
end

local function direct_discovery_admission(handle, policy, poll_key)
  local observed, unavailable_reason = m_claims.repo_scoped_observed_managed_bot_logins(
    repo,
    policy,
    "fkst-test-bot",
    handle,
    poll_key
  )
  return m_claims.claim_admission_precheck(current_issue("trusted-human", {}), {
    owner = "fkst-test-bot",
    status = "unassigned",
    managed = observed or {},
    trusted_author_policy = policy,
    peer_discovery_error = observed == nil and unavailable_reason or nil,
    peer_snapshot_provenance = {
      repo = repo,
      poll_epoch = poll_key,
    },
  })
end

local function direct_carrier_admission(claim_mode, author, managed, authorized)
  return m_claims.claim_admission_precheck(current_issue(author, {}), {
    owner = "fkst-test-bot",
    status = "unassigned",
    claim_mode = claim_mode,
    managed = managed or {},
    trusted_author_policy = github_author_policy.from_logins(authorized or { "fkst-test-bot" }),
  })
end

local function mock_peer_branch_config(times)
  for _ = 1, times or 1 do
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "integration-fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function record_test_poll_epoch(poll_key)
  cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
  local recorded, allocated_epoch = entity_list_cache.record_poll_epoch(repo, poll_key)
  t.is_true(recorded)
  return allocated_epoch
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
  test_author_and_peer_admission_is_carrier_independent = function()
    for _, claim_mode in ipairs({ "assignee", "label" }) do
      local peer_admission, peer_detail = direct_carrier_admission(
        claim_mode,
        "peer-bot",
        { ["peer-bot"] = true }
      )
      t.eq(peer_admission, "denied")
      t.eq(peer_detail.action, "skip-fork-peer-bot")

      local author_admission, author_detail = direct_carrier_admission(
        claim_mode,
        "drive-by",
        {},
        { "fkst-test-bot" }
      )
      t.eq(author_admission, "denied")
      t.eq(author_detail.action, "skip-non-whitelisted-author")
    end
  end,

  test_repo_peer_snapshot_accessor_requires_a_nonempty_poll_epoch = function()
    local calls = 0
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local handle = {
      issue_list_cli = function()
        calls = calls + 1
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end,
    }

    local ok, err = pcall(function()
      m_claims.repo_scoped_observed_managed_bot_logins(
        repo,
        policy,
        "fkst-test-bot",
        handle,
        nil
      )
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("poll epoch must be non-empty", 1, true) ~= nil)
    t.eq(calls, 0, "missing epoch is denied before either peer source is scanned")
  end,

  test_tokenless_dynamic_peer_admission_settles_unavailable_before_scan = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("trusted-human")

    local inputs = m_claims.claim_admission_inputs(current_issue("trusted-human", {}), repo, nil)
    local admission, detail = m_claims.claim_admission_precheck(current_issue("trusted-human", {}), inputs)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-peer-discovery-unavailable")
    t.eq(detail.reason, "peer-activity-poll-epoch-unavailable")
    t.eq(count_calls(issue_peer_command), 0)
    t.eq(count_calls(pr_peer_command), 0)
  end,

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
    }), repo)

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

  test_equal_epoch_repoll_uses_the_new_authorization_snapshot = function()
    local token = "2026-07-30T01:02:03Z"
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "peer-bot" })
    local function handle(issue_stdout)
      return {
        issue_list_cli = function()
          return { stdout = issue_stdout, stderr = "", exit_code = 0 }
        end,
        pr_list_cli = function()
          return { stdout = "[]", stderr = "", exit_code = 0 }
        end,
      }
    end

    local first_epoch = record_test_poll_epoch(token)
    mock_peer_branch_config()
    local first = m_claims.repo_scoped_observed_managed_bot_logins(
      repo,
      policy,
      "fkst-test-bot",
      handle("[]"),
      first_epoch
    )
    t.eq(first["peer-bot"], nil)

    local recorded, replayed_epoch = entity_list_cache.record_poll_epoch(repo, token)
    t.is_true(recorded)
    t.is_true(first_epoch ~= replayed_epoch, "equal timestamp replay receives a new execution epoch")
    mock_peer_branch_config()
    local replayed = m_claims.repo_scoped_observed_managed_bot_logins(
      repo,
      policy,
      "fkst-test-bot",
      handle("[" .. issue_row(7, { state_marker_comment("peer-bot") }) .. "]"),
      replayed_epoch
    )

    t.is_true(replayed["peer-bot"], "a fresh execution of the poll must not reuse the older negative snapshot")
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
    t.eq(count_calls(issue_peer_command), 0)
    t.eq(count_calls(pr_peer_command), 0)
  end,

  test_self_claim_skips_outcome_neutral_repo_peer_discovery = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("trusted-human")
    local current = current_issue("trusted-human", {})
    current.labels = { "fkst-dev:claimed:fkst-test-bot" }

    local admission = admission_for(current, repo)

    t.eq(admission, "held")
    t.eq(count_calls(issue_peer_command), 0)
    t.eq(count_calls(pr_peer_command), 0)
  end,

  test_repo_peer_discovery_failure_is_not_an_empty_peer_set = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    t.mock_command(issue_peer_command, {
      stdout = "",
      stderr = "rate limited",
      exit_code = 1,
    })

    local admission, detail = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-peer-discovery-unavailable")
    t.eq(detail.reason, "issue-peer-activity-unavailable")
    t.eq(count_calls(issue_peer_command), 1)
    t.eq(count_calls(pr_peer_command), 0)
  end,

  test_nonzero_issue_discovery_settles_once_and_denies_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("trusted-human")
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local issue_calls = 0
    local handle = {
      issue_list_cli = function()
        issue_calls = issue_calls + 1
        return { stdout = "", stderr = "rate limited", exit_code = 1 }
      end,
    }
    local poll_key = record_test_poll_epoch("poll-nonzero")

    for _ = 1, 2 do
      local admission = direct_discovery_admission(handle, policy, poll_key)
      t.eq(admission, "denied")
    end

    t.eq(issue_calls, 1, "nonzero issue source settles once")
  end,

  test_exit_zero_object_peer_scan_settles_unavailable_and_denies = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("trusted-human")
    mock_peer_branch_config()
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local handle = {
      issue_list_cli = function()
        return { stdout = "{}", stderr = "", exit_code = 0 }
      end,
      pr_list_cli = function()
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end,
    }
    local poll_key = record_test_poll_epoch("poll-object")

    local admission = direct_discovery_admission(handle, policy, poll_key)

    t.eq(admission, "denied")
  end,

  test_exit_zero_sparse_row_peer_scan_settles_unavailable_and_denies = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("trusted-human")
    mock_peer_branch_config()
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local handle = {
      issue_list_cli = function()
        return {
          stdout = '[{"number":7,"comments":[],"author":{"login":"trusted-human"}},null]',
          stderr = "",
          exit_code = 0,
        }
      end,
      pr_list_cli = function()
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end,
    }
    local poll_key = record_test_poll_epoch("poll-sparse")

    local admission = direct_discovery_admission(handle, policy, poll_key)

    t.eq(admission, "denied")
  end,

  test_null_actor_rows_and_comments_are_skipped_without_invalidating_peer_scan = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("ghost-peer")
    mock_peer_branch_config()
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "ghost-peer", "peer-bot" })
    local marker = '<!-- fkst:github-devloop:state:v1 proposal="x" state="thinking" version="v" -->'
    local handle = {
      issue_list_cli = function()
        return {
          stdout = '[{"number":7,"comments":[],"author":null},'
            .. '{"number":8,"comments":[{"body":' .. strings.json_string(marker) .. ',"author":null}],"author":{"login":"issue-author"}},'
            .. '{"number":9,"comments":[{"body":' .. strings.json_string(marker) .. ',"author":{"login":"peer-bot"}}],"author":{"login":"issue-author"}}]',
          stderr = "",
          exit_code = 0,
        }
      end,
      pr_list_cli = function()
        return {
          stdout = '[{"number":10,"headRefName":"integration-fkst-test-bot","baseRefName":"dev","comments":[],"author":null}]',
          stderr = "",
          exit_code = 0,
        }
      end,
    }
    local poll_key = record_test_poll_epoch("2026-07-30T01:05:00Z")

    local observed, unavailable_reason = m_claims.repo_scoped_observed_managed_bot_logins(
      repo,
      policy,
      "fkst-test-bot",
      handle,
      poll_key
    )
    local admission, detail = m_claims.claim_admission_precheck(current_issue("ghost-peer", {}), {
      owner = "fkst-test-bot",
      status = "unassigned",
      managed = observed or {},
      trusted_author_policy = policy,
      peer_discovery_error = observed == nil and unavailable_reason or nil,
      peer_snapshot_provenance = {
        repo = repo,
        poll_epoch = poll_key,
      },
    })

    t.is_nil(unavailable_reason)
    t.is_true(observed["peer-bot"])
    t.eq(observed["ghost-peer"], nil)
    t.eq(admission, "needs-claim")
    t.eq(detail.author, "ghost-peer")
  end,

  test_missing_branch_config_preserves_issue_derived_peer_admission = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    t.mock_command(issue_peer_command, {
      stdout = "[" .. issue_row(7, { state_marker_comment("peer-bot") }) .. "]",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local admission, detail = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "denied")
    t.eq(detail.action, "skip-fork-peer-bot")
    t.eq(count_calls(issue_peer_command), 1)
    t.eq(count_calls(pr_peer_command), 0)
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

  test_repo_peer_set_is_rederived_from_successful_current_scan_results = function()
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

  test_valid_mismatched_repo_activity_does_not_discover_peer = function()
    mock_bot("fkst-test-bot")
    mock_authorized_login("peer-bot")
    mock_repo_peer_scan({
      issue_row(7, {
        { author_login = "peer-bot", body = '<!-- fkst:github-devloop:state:v1 -->' },
        { author_login = "peer-bot", body = 'fkst:github-devloop:state:v1 proposal="x" state="thinking"' },
      }),
    }, {
      pr_row({ author_login = "peer-bot", head = "integration-peer-bot", base = "release" }),
      pr_row({ author_login = "peer-bot", head = "integration-peer-bot", base = "dev" }),
      pr_row({ author_login = "peer-bot", head = "feature/peer-bot", base = "dev" }),
    })

    local admission, detail, inputs = admission_for(current_issue("peer-bot", {}), repo)

    t.eq(admission, "needs-claim")
    t.eq(detail.author, "peer-bot")
    t.eq(m_claims.is_managed_bot_login("peer-bot", inputs.managed), false)
  end,
}
