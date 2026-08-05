local fixtures = require("tests.external_pr_intake_helpers")
local strings = fixtures.strings
local t = fixtures.t
local package_root = fixtures.package_root
local load_department = fixtures.load_department
local json_string = fixtures.json_string
local shell_quote = fixtures.shell_quote
local mkdir_p = fixtures.mkdir_p
local parent_dir = fixtures.parent_dir
local sibling_package_root = fixtures.sibling_package_root
local write_disk_file = fixtures.write_disk_file
local read_disk_file = fixtures.read_disk_file
local wait_for_file = fixtures.wait_for_file
local start_python_background = fixtures.start_python_background
local pr_json = fixtures.pr_json
local pr_list_json = fixtures.pr_list_json
local issue_json = fixtures.issue_json
local new_fake_github = fixtures.new_fake_github
local run_pipeline = fixtures.run_pipeline
local count_kind = fixtures.count_kind
local write_of_kind = fixtures.write_of_kind
local candidate_event = fixtures.candidate_event
local count_open_bridge_issues = fixtures.count_open_bridge_issues
local count_pr_bridge_markers = fixtures.count_pr_bridge_markers
local resume_thread = fixtures.resume_thread

return {
  test_existing_bridge_issue_search_dedups_without_pr_write = function()
    local core = require("core")
    local github = new_fake_github({
      issues = {
        {
          number = 88,
          author_login = "fkst-test-bot",
          state = "OPEN",
          body = core.bridge_marker("owner/repo", 7),
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
    t.eq(count_kind(github._model.writes, "issue_assign"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 1)
  end,

  test_same_repository_candidate_is_rejected_when_owner_changes_to_operator_bridge = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Bot patch",
          author_login = "other-bot[bot]",
          head_ref_name = "feature/bot",
          is_cross_repository = false,
          state = "OPEN",
          comments = {},
          assignees = {},
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "issue_assign"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 0)
  end,

  test_cross_repository_devloop_head_with_non_actionable_origin_is_not_self_excluded = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Managed branch",
          author_login = "contributor",
          head_ref_name = "devloop/owner-repo-7",
          is_cross_repository = true,
          state = "OPEN",
          comments = {
            {
              author_login = "fkst-test-bot",
              body = '<!-- fkst:github-devloop:pr-origin:v1 proposal="github-devloop/issue/owner/repo/42" issue="42" branch="devloop/owner-repo-7" impl_version="ready/v1" base_branch="dev" -->',
            },
          },
          assignees = {},
        },
      },
      issues = {
        { number = 42, author_login = "other-bot" },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "issue_assign"), 1)
    t.eq(count_kind(github._model.writes, "pr_comment"), 1)
  end,

  test_other_assignee_claim_blocks_writes = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Contributor patch",
          author_login = "contributor",
          head_ref_name = "feature/contrib",
          state = "OPEN",
          comments = {},
          assignees = { "other-bot" },
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
    t.eq(count_kind(github._model.writes, "issue_assign"), 0)
  end,

  test_dry_run_does_not_claim_or_write = function()
    local github = new_fake_github()
    run_pipeline({
      github = github,
      env = {
        FKST_GITHUB_REPO = "owner/repo",
        FKST_GITHUB_WRITE = "",
        FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot",
        FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
        FKST_DEVLOOP_INTEGRATION_BRANCH = "integration-fkst-test-bot",
      },
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
    t.eq(count_kind(github._model.writes, "issue_assign"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 1)
  end,
}
