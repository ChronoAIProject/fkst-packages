local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local claim_carriers = require("devloop.claim_carriers")
local claim_contract_mocks = require("tests.claim_contract_mock_helpers")

local function mock_bot_env(claim_mode)
  for _ = 1, 6 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_MODE"', { stdout = claim_mode or "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_SUFFIX"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_DEVLOOP_FORK_GRACE_HOURS"', { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function mock_repo_env()
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
end

local function mock_write_mode_reads(count)
  for _ = 1, count do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
  end
end

local function count_calls(needle)
  return gh_argv.count_calls(t, needle)
end

local function mock_admission_view(number)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = number,
    title = "Issue " .. tostring(number),
    body = "",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = {},
    author_login = "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

local function source_ref(number)
  return entity_lib.issue_source_ref("owner/repo", number)
end

local function event(number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = number,
      title = "Issue " .. tostring(number),
      state = "OPEN",
      labels = {},
      updated_at = "2026-06-03T01:02:03Z",
      dedup_key = "owner/repo#issue#" .. tostring(number) .. "@2026-06-03T01:02:03Z",
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function run_admission(number)
  return t.run_department("departments/admission/main.lua", event(number), {
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop-intake/intake-admission-claim-permission-denied",
      FKST_GITHUB_REPO = "owner/repo",
      FKST_GITHUB_WRITE = "1",
    },
  })
end

local function candidate_for(result, number)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "devloop_intake_candidate"
      and tostring(raised.payload.issue_number) == tostring(number) then
      return raised
    end
  end
  return nil
end

return {
  test_admission_uses_explicit_label_contract_under_assignee_mode = function()
    mock_bot_env("assignee")
    mock_repo_env()
    mock_write_mode_reads(6)
    mock_admission_view(42)
    local claim_spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    for _ = 1, 3 do
      t.mock_command("gh api repos/owner/repo/labels/" .. claim_spec.name, {
        stdout = '{"name":"' .. claim_spec.name .. '","description":"'
          .. claim_spec.description .. '"}\n',
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command("gh issue edit '42' --repo 'owner/repo' --add-label '" .. claim_spec.name .. "'", {
      stdout = "", stderr = "", exit_code = 0,
    })
    t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", "42"), {
      stdout = '{"assignees":[],"author":{"login":"fkst-test-bot"},"labels":[{"name":"'
        .. claim_spec.name .. '"}]}\n',
      stderr = "",
      exit_code = 0,
    })

    local admitted = run_admission(42)

    t.eq(admitted.exit_code, 0)
    t.is_true(candidate_for(admitted, 42) ~= nil)
    t.eq(count_calls("--add-assignee"), 0)
    t.eq(count_calls("--remove-assignee"), 0)
    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
  end,

  test_label_binding_collision_does_not_fallback_to_assignee_and_later_event_can_admit = function()
    mock_bot_env("assignee")
    mock_repo_env()
    mock_write_mode_reads(6)
    local claim_spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    t.mock_command("gh api repos/owner/repo/labels/" .. claim_spec.name, {
      stdout = '{"name":"' .. claim_spec.name
        .. '","description":"fkst-dev-label-mode-ownership-claim owner=other-bot"}\n',
      stderr = "",
      exit_code = 0,
    })
    claim_contract_mocks.mock_binding(t, "owner/repo", "fkst-test-bot", 2)
    mock_admission_view(42)

    local denied = run_admission(42)

    t.eq(denied.exit_code, 1)
    t.eq(candidate_for(denied, 42), nil)
    t.eq(count_calls("--add-assignee"), 0)

    mock_bot_env("assignee")
    mock_admission_view(43)
    t.mock_command("gh issue edit '43' --repo 'owner/repo' --add-label '" .. claim_spec.name .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", "43"), {
      stdout = '{"assignees":[],"author":{"login":"fkst-test-bot"},"labels":[{"name":"'
        .. claim_spec.name .. '"}]}\n',
      stderr = "",
      exit_code = 0,
    })

    local admitted = run_admission(43)

    t.eq(admitted.exit_code, 0)
    t.is_true(candidate_for(admitted, 43) ~= nil)
    t.eq(count_calls("--add-assignee"), 0)
    t.eq(count_calls("--remove-assignee"), 0)
  end,
}
