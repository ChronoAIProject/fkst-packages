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
    t.eq(count_kind(github._model.writes, "issue_add_label"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 1)
  end,

  test_same_repository_bot_authored_pr_is_ignored = function()
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
          labels = {},
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "issue_add_label"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 0)
  end,

  test_cross_repository_devloop_head_pr_is_not_self_excluded = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Managed branch",
          author_login = "contributor",
          head_ref_name = "devloop/owner-repo-7",
          state = "OPEN",
          comments = {},
          labels = {},
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "issue_add_label"), 1)
    t.eq(count_kind(github._model.writes, "pr_comment"), 1)
  end,

  test_foreign_claim_label_blocks_writes = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Contributor patch",
          author_login = "contributor",
          head_ref_name = "feature/contrib",
          state = "OPEN",
          comments = {},
          labels = { "fkst-dev:claimed:other-bot" },
        },
      },
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
    t.eq(count_kind(github._model.writes, "issue_add_label"), 0)
  end,

  test_lost_claim_before_create_blocks_bridge_writes = function()
    local github = new_fake_github({
      pr_read_mutator = function(_model, pr, read_count)
        if read_count == 3 then
          pr.labels = { "fkst-dev:claimed:other-bot" }
        end
      end,
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_add_label"), 1)
    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
  end,

  test_lost_claim_before_comment_defers_bridge_marker = function()
    local github = new_fake_github({
      pr_read_mutator = function(_model, pr, read_count)
        if read_count == 4 then
          pr.labels = { "fkst-dev:claimed:other-bot" }
        end
      end,
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
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
      },
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)
    t.eq(count_kind(github._model.writes, "issue_add_label"), 0)
    t.eq(count_kind(github._model.writes, "issue_search"), 1)
  end,
}
