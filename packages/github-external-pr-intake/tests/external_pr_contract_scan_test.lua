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
  test_body_file_path_flattens_slash_bearing_repo = function()
    local core = require("core")
    local prefix = "/tmp/fkst-github-external-pr-intake-"
    local path = core.body_file_path("ChronoAIProject/fkst-packages", 1151, "issue")
    t.eq(path:sub(1, #prefix), prefix)
    t.is_true(path:sub(#prefix + 1):find("/", 1, true) == nil)
  end,

  test_scan_source_must_be_reliable = function()
    local spec = load_department().spec
    for _, queue in ipairs(spec.ephemeral or {}) do
      t.is_true(queue ~= "external_pr_scan")
    end
  end,

  test_candidate_activation_must_be_ephemeral = function()
    local spec = load_department().spec
    t.eq(#(spec.ephemeral or {}), 1)
    t.eq(spec.ephemeral[1], "external_pr_candidate")
  end,

  test_existing_intake_surfaces_cannot_schedule_external_pr_bridge = function()
    local proxy_raiser = read_disk_file(sibling_package_root("github-proxy") .. "/raisers/github_poll.lua")
    local proxy_poll = read_disk_file(sibling_package_root("github-proxy") .. "/departments/github_poll/main.lua")
    local proxy_issue_create = read_disk_file(sibling_package_root("github-proxy") .. "/departments/github_issue_create/main.lua")
    local proxy_issue_create_core = read_disk_file(sibling_package_root("github-proxy") .. "/core/issue_create.lua")
    local devloop_admission = read_disk_file(sibling_package_root("github-devloop-intake") .. "/departments/admission/main.lua")
    local external_scan_raiser = read_disk_file(package_root .. "/raisers/external_pr_scan.lua")
    local external_intake = read_disk_file(package_root .. "/departments/external_pr_intake/main.lua")
    local external_owner_resolution = read_disk_file(package_root .. "/core/pr_owner_resolution.lua")

    -- Necessity proof: `github-proxy` can observe generic PR facts and execute
    -- already-formed issue-create effects, but it has no policy owner for the
    -- required middle step: external PR selection -> bridge issue materialization.
    t.is_true(proxy_raiser:find('produces = "github_poll_tick"', 1, true) ~= nil)
    t.is_true(proxy_raiser:find("external_pr_scan", 1, true) == nil)
    t.is_true(proxy_poll:find('consumes = { "github_poll_tick" }', 1, true) ~= nil)
    t.is_true(proxy_poll:find('produces = { "github_entity_changed", "github_issue_observed" }', 1, true) ~= nil)
    t.is_true(proxy_poll:find('{ type = "pr"', 1, true) ~= nil)
    t.is_true(proxy_poll:find('raise("github_entity_changed"', 1, true) ~= nil)
    t.is_true(proxy_poll:find("core.is_external_candidate", 1, true) == nil)
    t.is_true(proxy_poll:find('"github_issue_create_request"', 1, true) == nil)
    t.is_true(proxy_poll:find("external_pr_candidate", 1, true) == nil)

    t.is_true(proxy_issue_create:find('consumes = { "github_issue_create_request" }', 1, true) ~= nil)
    t.is_true(proxy_issue_create:find('produces = { "github_issue_blocked_by_request" }', 1, true) ~= nil)
    t.is_true(proxy_issue_create:find("core.write_issue_create_request", 1, true) ~= nil)
    t.is_true(proxy_issue_create_core:find("payload.title", 1, true) ~= nil)
    t.is_true(proxy_issue_create_core:find("payload.body", 1, true) ~= nil)
    t.is_true(proxy_issue_create_core:find("payload.dedup_key", 1, true) ~= nil)
    t.is_true(proxy_issue_create_core:find("core.is_external_candidate", 1, true) == nil)
    t.is_true(proxy_issue_create_core:find("pr_list", 1, true) == nil)
    t.is_true(proxy_issue_create_core:find("external-pr-bridge:v1", 1, true) == nil)

    -- Devloop issue intake admits only GitHub issues already surfaced by the
    -- proxy entity stream; it has no PR source or bridge materialization policy.
    t.is_true(devloop_admission:find('"github-proxy.github_entity_changed"', 1, true) ~= nil)
    t.is_true(devloop_admission:find("devloop_intake_candidate", 1, true) ~= nil)
    t.is_true(devloop_admission:find("issue_list_intake", 1, true) == nil)
    t.is_true(devloop_admission:find("devloop_intake_tick", 1, true) == nil)
    t.is_true(devloop_admission:find("pr_list", 1, true) == nil)
    t.is_true(devloop_admission:find("#pr/", 1, true) == nil)

    -- The new adapter is the smallest owner of that middle step.
    t.is_true(external_scan_raiser:find('produces = "external_pr_scan"', 1, true) ~= nil)
    t.is_true(external_intake:find('consumes = { "external_pr_scan", "external_pr_candidate" }', 1, true) ~= nil)
    t.is_true(external_intake:find('produces = { "external_pr_candidate" }', 1, true) ~= nil)
    t.is_true(external_intake:find("github.pr_list(repo, 30)", 1, true) ~= nil)
    t.is_true(external_owner_resolution:find("core.classify_pr_owner", 1, true) ~= nil)
    t.is_true(external_intake:find("with_lock(core.bridge_lock_key", 1, true) ~= nil)
    t.is_true(external_intake:find("external_pr_candidate", 1, true) ~= nil)
    t.is_true(external_intake:find("create_bridge_issue", 1, true) ~= nil)
    t.is_true(external_intake:find("write_comment", 1, true) ~= nil)
  end,

  test_bridge_lock_key_uses_production_cross_process_flock = function()
    local core = require("core")
    local runtime_root = os.getenv("FKST_RUNTIME_ROOT")
    t.is_true(runtime_root ~= nil and runtime_root ~= "")

    local lock_key = core.bridge_lock_key("owner/repo", 7)
    local lock_path = runtime_root .. "/locks/" .. lock_key .. "/=lock"
    local scratch = runtime_root .. "/external-pr-intake-lock-proof-" .. tostring(now())
    mkdir_p(parent_dir(lock_path))
    mkdir_p(scratch)

    local ready_path = scratch .. "/ready"
    local release_path = scratch .. "/release"
    local released_path = scratch .. "/released"
    local entered_path = scratch .. "/entered"
    local locker_script = scratch .. "/hold_lock.py"

    write_disk_file(locker_script, [[
import fcntl
import os
import pathlib
import sys
import time

lock_path, ready_path, release_path, released_path = sys.argv[1:5]
pathlib.Path(os.path.dirname(lock_path)).mkdir(parents=True, exist_ok=True)
with open(lock_path, "a+", encoding="utf-8") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    pathlib.Path(ready_path).write_text("ready\n", encoding="utf-8")
    deadline = time.time() + 10.0
    while not os.path.exists(release_path):
        if time.time() > deadline:
            pathlib.Path(released_path).write_text("timeout\n", encoding="utf-8")
            raise SystemExit(2)
        time.sleep(0.02)
pathlib.Path(released_path).write_text("released\n", encoding="utf-8")
]])

    local ok, err = pcall(function()
      start_python_background(locker_script, { lock_path, ready_path, release_path, released_path })
      if not wait_for_file(ready_path, 150) then
        error("github-external-pr-intake: lock helper did not acquire the bridge lock")
      end

      -- Substrate #305 makes contention exit 75 as a supervise-owned transient defer.
      local entered_while_busy = false
      local busy_ok, busy_err = pcall(function()
        with_lock(lock_key, function()
          entered_while_busy = true
        end)
      end)
      t.eq(busy_ok, false)
      t.eq(tostring(busy_err):match("^[^\n]+"), "with_lock lock busy: " .. lock_key)
      t.eq(entered_while_busy, false)

      write_disk_file(release_path, "release\n")
      if not wait_for_file(released_path, 150) then
        error("github-external-pr-intake: lock helper did not release the bridge lock")
      end
      local entered_after_release = false
      with_lock(lock_key, function()
        entered_after_release = true
        file.write(entered_path, tostring(entered_after_release))
      end)

      t.eq(read_disk_file(released_path), "released\n")
      t.eq(read_disk_file(entered_path), "true")
      t.is_true(entered_after_release)
    end)

    write_disk_file(release_path, "release\n")
    os.execute("sleep 0.05")
    if not ok then
      error(err, 0)
    end
  end,

  test_scan_raises_bridge_owned_candidates_and_reserves_same_repository_human_pr = function()
    local github = new_fake_github({
      prs = {
        [7] = {
          number = 7,
          title = "Contributor patch",
          author_login = "contributor",
          head_ref_name = "feature/contrib",
          base_ref_name = "dev",
          state = "OPEN",
          comments = {},
          assignees = {},
        },
        [8] = {
          number = 8,
          title = "Bot patch",
          author_login = "fkst-test-bot[bot]",
          head_ref_name = "feature/bot",
          base_ref_name = "dev",
          is_cross_repository = false,
          state = "OPEN",
          comments = {},
          assignees = {},
        },
        [9] = {
          number = 9,
          title = "Unmarked managed branch",
          author_login = "contributor",
          head_ref_name = "devloop/owner-repo-9",
          base_ref_name = "dev",
          is_cross_repository = false,
          state = "OPEN",
          comments = {},
          assignees = {},
        },
      },
      list = {
        {
          number = 7,
          title = "Contributor patch",
          author_login = "contributor",
          head_ref_name = "feature/contrib",
          state = "OPEN",
        },
        {
          number = 8,
          title = "Bot patch",
          author_login = "fkst-test-bot[bot]",
          head_ref_name = "feature/bot",
          is_cross_repository = false,
          state = "OPEN",
        },
        {
          number = 9,
          title = "Managed branch",
          author_login = "contributor",
          head_ref_name = "devloop/owner-repo-9",
          is_cross_repository = false,
          state = "OPEN",
        },
        {
          number = 10,
          title = "Closed patch",
          author_login = "contributor",
          head_ref_name = "feature/closed",
          state = "CLOSED",
        },
      },
    })
    local result = run_pipeline({
      github = github,
      event = { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })

    t.eq(#result.raises, 2)
    t.eq(result.raises[1].queue, "external_pr_candidate")
    t.eq(result.raises[1].payload.repo, "owner/repo")
    t.eq(result.raises[1].payload.number, 7)
    t.eq(result.raises[1].payload.owner_kind, "external-pr-bridge")
    t.eq(result.raises[1].payload.source_ref.kind, "external")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/repo#pr/7")
    t.eq(result.raises[2].payload.number, 8)
    t.eq(result.raises[2].payload.owner_kind, "operator-hotfix-bridge")
    t.eq(count_kind(github._model.writes, "pr_list"), 1)
  end,

  test_failed_ephemeral_candidate_is_rederived_by_next_scan = function()
    local github = new_fake_github({
      fail_pr_cli_view_once = true,
    })
    local ok, err = pcall(function()
      run_pipeline({
        github = github,
        event = candidate_event(7),
      })
    end)
    t.eq(ok, false)
    t.is_true(tostring(err or ""):find("transient PR view failure", 1, true) ~= nil)
    t.eq(count_kind(github._model.writes, "issue_create"), 0)
    t.eq(count_kind(github._model.writes, "pr_comment"), 0)

    local scan = run_pipeline({
      github = github,
      event = { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })
    t.eq(#scan.raises, 1)
    t.eq(scan.raises[1].queue, "external_pr_candidate")
    t.eq(scan.raises[1].payload.source_ref.kind, "external")
    t.eq(scan.raises[1].payload.source_ref.ref, "owner/repo#pr/7")

    run_pipeline({
      github = github,
      event = {
        queue = scan.raises[1].queue,
        payload = scan.raises[1].payload,
      },
    })
    t.eq(count_kind(github._model.writes, "issue_create"), 1)
    t.eq(count_kind(github._model.writes, "pr_comment"), 1)
  end,

}
