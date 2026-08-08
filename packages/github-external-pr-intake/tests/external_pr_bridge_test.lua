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
  test_candidate_creates_one_bridge_issue_and_pr_marker = function()
    local result = run_pipeline({
      event = candidate_event(7),
    })
    local writes = result.github._model.writes
    local created = write_of_kind(writes, "issue_create")
    local marker = write_of_kind(writes, "pr_comment")

    t.eq(count_kind(writes, "issue_add_label"), 1)
    t.eq(write_of_kind(writes, "issue_add_label").label, "fkst-dev:claimed:fkst-test-bot")
    t.eq(count_kind(writes, "issue_create"), 1)
    t.eq(count_kind(writes, "pr_comment"), 1)
    t.eq(count_kind(writes, "issue_close"), 0)
    t.eq(created.title, "Integrate external PR #7 from @contributor")
    t.eq(#created.labels, 0)
    t.is_true(created.body:find("source_ref: external:owner/repo#pr/7", 1, true) ~= nil)
    t.is_true(created.body:find("already provisioned in your worktree", 1, true) ~= nil)
    t.eq(created.body:find("fetch `refs/pull/7/head`", 1, true), nil)
    t.is_true(created.body:find("implement against `dev`", 1, true) ~= nil)
    t.is_true(marker.body:find('external-pr-bridge:v1 repo="owner/repo" pr="7"', 1, true) ~= nil)
    t.is_true(marker.body:find('issue="77"', 1, true) ~= nil)
    t.eq(#result.locks, 1)
  end,

  test_second_scan_dedups_on_trusted_pr_marker = function()
    local github = new_fake_github()
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "pr_comment"), 1)
  end,

  test_created_duplicate_bridge_is_reconciled_to_lowest_issue = function()
    local core = require("core")
    local github = new_fake_github({
      next_issue = 99,
      hidden_issues_until_create = true,
      issues = {
        {
          number = 88,
          author_login = "fkst-test-bot",
          state = "OPEN",
          body = core.bridge_marker("owner/repo", 7),
        },
      },
    })
    local result = run_pipeline({
      github = github,
      event = candidate_event(7),
    })
    local writes = result.github._model.writes
    local marker = write_of_kind(writes, "pr_comment")

    t.eq(count_kind(writes, "issue_create"), 1)
    t.eq(count_kind(writes, "issue_close"), 1)
    t.eq(write_of_kind(writes, "issue_close").issue_number, 99)
    t.eq(write_of_kind(writes, "issue_close").disposition.duplicate_of, 88)
    t.is_true(marker.body:find('issue="88"', 1, true) ~= nil)
  end,

  test_stale_visibility_reconciles_to_one_open_bridge_issue_and_one_marker = function()
    local github = new_fake_github({
      next_issue = 88,
      hidden_issues_until_creates = 2,
      hidden_comments_until_creates = 2,
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })
    run_pipeline({
      github = github,
      event = candidate_event(7),
    })

    local open_bridges, open_issue_number = count_open_bridge_issues(github)
    local trusted_markers, marker_body = count_pr_bridge_markers(github, 7)

    t.eq(count_kind(github._model.writes, "issue_create"), 2)
    t.eq(count_kind(github._model.writes, "issue_close"), 1)
    t.eq(open_bridges, 1)
    t.eq(open_issue_number, 88)
    t.eq(trusted_markers, 1)
    t.is_true(tostring(marker_body or ""):find('issue="88"', 1, true) ~= nil)
  end,

  test_same_bot_concurrent_candidates_serialize_to_one_bridge_issue_and_marker = function()
    local core = require("core")
    local github = new_fake_github({
      next_issue = 88,
      issue_create_yield = function()
        coroutine.yield("after-issue-create")
      end,
    })
    local files = {}
    local raises = {}
    local locks = {}
    local lock_busy = false
    local second_worker_waited = false
    local function bridge_lock(key, fn)
      table.insert(locks, key)
      while lock_busy do
        second_worker_waited = true
        coroutine.yield("waiting-for-lock")
      end
      lock_busy = true
      local result = fn()
      lock_busy = false
      return result
    end

    local old_file = file
    local old_log = log
    local old_raise = raise
    local old_with_lock = with_lock
    local old_pipeline = pipeline
    local old_now = now
    local old_read = core.read_env
    file = {
      write = function(path, body)
        files[path] = body
      end,
      read = function(path)
        return files[path] or ""
      end,
    }
    log = {
      info = function(_message) end,
      warn = function(_message) end,
      error = function(_message) end,
    }
    raise = function(queue, payload)
      table.insert(raises, { queue = queue, payload = payload })
    end
    with_lock = bridge_lock
    now = function()
      return 1780459324
    end
    core.read_env = function(name)
      return ({
        FKST_GITHUB_REPO = "owner/repo",
        FKST_GITHUB_WRITE = "1",
        FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot,other-bot",
      })[name] or ""
    end

    local ok, err = pcall(function()
      local first_module = load_department()
      local second_module = load_department()
      local claim_labels = require("devloop.claim_labels")
      local claims = {
        claimed_label = function()
          return "fkst-dev:claimed:fkst-test-bot"
        end,
        issue_claim_state = function(labels)
          return claim_labels.classify(labels, "fkst-dev:claimed:fkst-test-bot")
        end,
      }
      local first_dept = first_module.make_department({ github = github }, claims)
      local second_dept = second_module.make_department({ github = github }, claims)
      local first = coroutine.create(function()
        first_dept.pipeline(candidate_event(7))
      end)
      local second = coroutine.create(function()
        second_dept.pipeline(candidate_event(7))
      end)

      t.eq(resume_thread(first), "after-issue-create")
      t.eq(resume_thread(second), "waiting-for-lock")
      t.eq(coroutine.status(first), "suspended")
      t.eq(coroutine.status(second), "suspended")
      resume_thread(first)
      t.eq(coroutine.status(first), "dead")
      resume_thread(second)
      t.eq(coroutine.status(second), "dead")
    end)
    core.read_env = old_read
    now = old_now
    pipeline = old_pipeline
    file = old_file
    log = old_log
    raise = old_raise
    with_lock = old_with_lock
    if not ok then
      error(err, 0)
    end

    local open_bridges, open_issue_number = count_open_bridge_issues(github)
    local trusted_markers, marker_body = count_pr_bridge_markers(github, 7)

    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "issue_close"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 1)
    t.eq(open_bridges, 1)
    t.eq(open_issue_number, 88)
    t.eq(trusted_markers, 1)
    t.is_true(tostring(marker_body or ""):find('issue="88"', 1, true) ~= nil)
    t.eq(#locks, 2)
    t.eq(locks[1], core.bridge_lock_key("owner/repo", 7))
    t.eq(locks[2], core.bridge_lock_key("owner/repo", 7))
    t.eq(second_worker_waited, true)
  end,

}
