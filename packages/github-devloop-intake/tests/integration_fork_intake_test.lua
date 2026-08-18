local entity_lib = require("devloop.entity")
local claim_carriers = require("devloop.claim_carriers")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local find_raise = h.find_raise
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local author_policy = require("testkit_internal.github_author_policy")
local entity_highwater = require("devloop.entity_highwater")
local entity_list_cache = require("devloop.entity_list_cache")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local testing = require("testkit_internal.testing")
local admission_department = require("departments.admission.main")
local poll_sequence = 0

local function mock_repo_env(claim_mode)
  h.mock_bot_env()
  author_policy.mock_env(t, nil, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 4,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_FORK_GRACE_HOURS"', { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_MODE"', {
      stdout = claim_mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author", {
    stdout = "[]",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author", {
    stdout = "[]",
    stderr = "",
    exit_code = 0,
  })
end

local function source_ref()
  return entity_lib.issue_source_ref("owner/repo", 42)
end

local function event(updated_at)
  local selected_updated_at = updated_at or "2026-06-03T01:02:03Z"
  poll_sequence = poll_sequence + 1
  cache_set(entity_list_cache.poll_epoch_cache_key("owner/repo"), "")
  local recorded, poll_epoch = entity_list_cache.record_poll_epoch(
    "owner/repo",
    "integration-fork-intake-" .. selected_updated_at .. "-" .. tostring(poll_sequence)
  )
  t.is_true(recorded)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      title = "External request",
      state = "OPEN",
      labels = {},
      updated_at = selected_updated_at,
      dedup_key = "owner/repo#issue#42@" .. selected_updated_at,
      poll_token = poll_epoch,
      source_ref = source_ref(),
    },
    source_ref = source_ref(),
  }
end

local function mock_admission_view(fields)
  local f = fields or {}
  github_proxy_entity_view.invalidate_entity_after_write("owner/repo", "issue", f.number or 42)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = f.number or 42,
    title = "External request",
    body = "",
    created_at = f.created_at or "2026-06-03T01:00:00Z",
    updated_at = f.updated_at or "2026-06-03T01:02:03Z",
    state = f.state or "OPEN",
    labels = {},
    comments = {},
    assignees = {},
    author_login = f.author_login or "trusted-human",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

local function mock_state_view(fields)
  local f = fields or {}
  t.mock_command(core.gh_issue_view_state_cmd("owner/repo", tostring(f.number or 42)), {
    stdout = '{"title":"External request","createdAt":"' .. tostring(f.created_at or "2026-06-03T01:00:00Z") .. '","updatedAt":"' .. tostring(f.updated_at or "2026-06-03T01:02:03Z") .. '","state":"' .. tostring(f.state or "OPEN") .. '","labels":[],"comments":[],"assignees":[],"author":{"login":"' .. tostring(f.author_login or "trusted-human") .. '"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function run_admission(run_opts, updated_at, deps)
  author_policy.mock_env(t, run_opts, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 4,
  })
  return testing.run_fake_outcome(admission_department.make_department(deps), event(updated_at))
end

local function assert_no_fork_or_candidate(result)
  t.eq(result.exit_code, 0)
  t.eq(#result.raises, 0)
  t.eq(find_raise(result.raises, "github-proxy.github_issue_create_request"), nil)
  t.eq(find_raise(result.raises, "devloop_intake_candidate"), nil)
end

local function created_inside_grace()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now())
end

local function created_after_grace()
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60) - 1)
end

return {
  test_label_mode_denies_non_whitelisted_author_before_candidate_admission = function()
    local run_opts = opts("label-mode-non-whitelisted-author", {
      FKST_GITHUB_CLAIM_MODE = "label",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
      FKST_GITHUB_AUTHORIZED_LOGINS = "",
    })
    mock_repo_env("label")
    mock_admission_view({ author_login = "drive-by" })
    cache_set(entity_highwater.key("github-devloop-intake/admission", source_ref()), "")
<<<<<<< HEAD
    local claim_label = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    t.mock_command("gh api repos/owner/repo/labels/" .. claim_label.name, {
=======
    local claim_label = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    t.mock_command("gh api --method GET 'repos/owner/repo/labels/fkst-dev%3Aclaimed%3A881cb233d76686282e06df2ecace1311'", {
>>>>>>> d8c2d56babf16257706c3641f2b231f6047351b4
      stdout = '{"name":"' .. claim_label.name .. '","description":"' .. claim_label.description .. '"}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_admission(run_opts, nil, {
      capacity = {
        authorize = function()
          return true, "label-mode-author-admission-test"
        end,
        relinquish = function()
          return true, "label-mode-author-admission-test"
        end,
        reconcile = function()
          return true, "label-mode-author-admission-test"
        end,
      },
    })

    assert_no_fork_or_candidate(result)
  end,

  test_admission_other_authored_unassigned_issue_inside_grace_does_not_fork = function()
    mock_repo_env()
    mock_admission_view({ created_at = created_inside_grace() })
    mock_state_view({ created_at = created_inside_grace() })

    local result = run_admission(opts("fork-intake-admission-other-author"))

    assert_no_fork_or_candidate(result)
  end,

  test_admission_other_authored_unassigned_issue_after_grace_raises_fork_request_only = function()
    local run_opts = opts("fork-intake-admission-other-author-stale")
    mock_repo_env()
    mock_admission_view({ created_at = created_after_grace() })
    mock_state_view({ created_at = created_after_grace() })

    local result = run_admission(run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local request = find_raise(result.raises, "github-proxy.github_issue_create_request").payload
    t.eq(request.external_effect_saga, "fork-and-block")
    t.eq(request.external_effect_step, "create-fork")
    t.eq(request.assignees[1], "fkst-test-bot")
    t.eq(request.parent_comment_target.issue_number, 42)
    t.eq(request.post_create_blocked_by.blocked_issue_number, 42)
    t.eq(request.post_create_blocked_by.external_effect_saga, "fork-and-block")
    t.eq(request.post_create_blocked_by.external_effect_step, "block-original")
    t.eq(find_raise(result.raises, "devloop_intake_candidate"), nil)
  end,

  test_admission_stale_open_issue_revalidates_closed_issue_before_fork = function()
    local run_opts = opts("fork-intake-admission-stale-open-author-closed")
    mock_repo_env()
    mock_admission_view({ created_at = created_after_grace() })
    mock_state_view({ state = "CLOSED", created_at = created_after_grace() })

    local result = run_admission(run_opts)

    assert_no_fork_or_candidate(result)
  end,

  test_admission_other_authored_closed_issue_after_grace_does_not_fork = function()
    local run_opts = opts("fork-intake-admission-other-author-closed")
    mock_repo_env()
    mock_admission_view({ state = "CLOSED", created_at = created_after_grace() })

    local result = run_admission(run_opts)

    assert_no_fork_or_candidate(result)
  end,

  test_admission_updated_at_change_does_not_restart_fork_grace = function()
    local run_opts = opts("fork-intake-admission-progress-keeps-grace")
    mock_repo_env()
    mock_admission_view({ created_at = created_after_grace(), updated_at = "2026-06-03T02:00:00Z" })
    mock_state_view({ created_at = created_after_grace(), updated_at = "2026-06-03T02:00:00Z" })

    local result = run_admission(run_opts, "2026-06-03T02:00:00Z")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_create_request").payload.post_create_blocked_by.blocked_issue_number, 42)
    t.eq(find_raise(result.raises, "devloop_intake_candidate"), nil)
  end,
}
