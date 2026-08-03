local core = require("core")
local strings = require("contract.strings")
local t = fkst.test

local function load_department()
  local old_pipeline = pipeline
  local module = require("departments.external_pr_intake.main")
  pipeline = old_pipeline
  return module
end

local function pr_origin_marker(branch, base_branch)
  return '<!-- fkst:github-devloop:pr-origin:v1 proposal="github-devloop/issue/owner/repo/42"'
    .. ' issue="42" branch="'
    .. branch
    .. '" impl_version="ready/github-devloop/issue/owner/repo/42/intake/0000000001" base_branch="'
    .. base_branch
    .. '" -->'
end

local function production_pr(signer, branch, base_branch)
  return {
    number = 7,
    title = "Contributor patch",
    author_login = "trusted-contributor",
    head_ref_name = "feature/contrib",
    base_ref_name = "dev",
    state = "OPEN",
    created_at = "2026-06-03T01:02:03Z",
    updated_at = "2026-06-19T01:02:03Z",
    comments = {
      {
        author_login = signer,
        body = pr_origin_marker(branch, base_branch),
        created_at = "2026-06-19T01:02:03Z",
      },
    },
    assignees = {},
  }
end

local function pr_json(pr)
  local comments = {}
  for _, item in ipairs(pr.comments or {}) do
    table.insert(comments, '{"body":' .. strings.json_string(item.body)
      .. ',"author":{"login":' .. strings.json_string(item.author_login)
      .. '},"createdAt":' .. strings.json_string(item.created_at) .. "}")
  end
  local assignees = {}
  for _, login in ipairs(pr.assignees or {}) do
    table.insert(assignees, '{"login":' .. strings.json_string(login) .. "}")
  end
  return '{"number":' .. tostring(pr.number)
    .. ',"title":' .. strings.json_string(pr.title)
    .. ',"headRefName":' .. strings.json_string(pr.head_ref_name)
    .. ',"baseRefName":' .. strings.json_string(pr.base_ref_name)
    .. ',"state":' .. strings.json_string(pr.state)
    .. ',"createdAt":' .. strings.json_string(pr.created_at)
    .. ',"updatedAt":' .. strings.json_string(pr.updated_at)
    .. ',"author":{"login":' .. strings.json_string(pr.author_login)
    .. '},"comments":[' .. table.concat(comments, ",")
    .. '],"assignees":[' .. table.concat(assignees, ",") .. "]}"
end

local function fake_github(pr, authorized_login)
  local operations = {}
  local handle = { operations = operations }
  authorized_login = authorized_login or "trusted-contributor"

  function handle.is_authorized_author(login)
    return login == authorized_login
  end

  function handle.pr_list(repo, timeout)
    table.insert(operations, { kind = "pr_list", repo = repo, timeout = timeout })
    return { stdout = "[" .. pr_json(pr) .. "]", stderr = "", exit_code = 0 }
  end

  function handle.pr_cli_view(repo, pr_number, fields, timeout)
    table.insert(operations, {
      kind = "pr_cli_view",
      repo = repo,
      pr_number = pr_number,
      fields = fields,
      timeout = timeout,
    })
    return { stdout = pr_json(pr), stderr = "", exit_code = 0 }
  end

  function handle.issue_search(repo, query, fields, timeout)
    table.insert(operations, {
      kind = "issue_search",
      repo = repo,
      query = query,
      fields = fields,
      timeout = timeout,
    })
    return { stdout = "[]", stderr = "", exit_code = 0 }
  end

  function handle.issue_assign(repo, issue_number, login, timeout)
    table.insert(operations, {
      kind = "issue_assign",
      repo = repo,
      issue_number = issue_number,
      login = login,
      timeout = timeout,
    })
    pr.assignees = { login }
    return { stdout = "", stderr = "", exit_code = 0 }
  end

  function handle.issue_create(repo, title, body_file, labels, assignees, timeout)
    table.insert(operations, {
      kind = "issue_create",
      repo = repo,
      title = title,
      body = file.read(body_file),
      labels = labels,
      assignees = assignees,
      timeout = timeout,
    })
    return { stdout = "https://github.com/owner/repo/issues/77\n", stderr = "", exit_code = 0 }
  end

  function handle.pr_comment(repo, pr_number, body_file, timeout)
    table.insert(operations, {
      kind = "pr_comment",
      repo = repo,
      pr_number = pr_number,
      body = file.read(body_file),
      timeout = timeout,
    })
    return { stdout = "", stderr = "", exit_code = 0 }
  end

  function handle.issue_close(repo, issue_number, disposition, timeout)
    table.insert(operations, {
      kind = "issue_close",
      repo = repo,
      issue_number = issue_number,
      disposition = disposition,
      timeout = timeout,
    })
    return { stdout = "", stderr = "", exit_code = 0 }
  end

  return handle
end

local function run_event(github, event, write_enabled)
  local files = {}
  local logs = {}
  local raises = {}
  local old_file = file
  local old_log = log
  local old_now = now
  local old_raise = raise
  local old_read_env = core.read_env
  local old_with_lock = with_lock

  file = {
    read = function(path)
      return files[path] or ""
    end,
    write = function(path, body)
      files[path] = body
    end,
  }
  log = {
    error = function(message)
      table.insert(logs, tostring(message))
    end,
    info = function(message)
      table.insert(logs, tostring(message))
    end,
    warn = function(message)
      table.insert(logs, tostring(message))
    end,
  }
  now = function()
    return 1780459324
  end
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  core.read_env = function(name)
    return ({
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_GITHUB_REPO = "owner/repo",
      FKST_GITHUB_WRITE = write_enabled and "1" or "",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot,other-bot",
      FKST_EXTERNAL_PR_BRIDGE_MIN_AGE_SECONDS = "",
    })[name] or ""
  end
  with_lock = function(_key, fn)
    return fn()
  end

  local ok, err = pcall(function()
    load_department().make_department({ github = github }).pipeline(event)
  end)

  file = old_file
  log = old_log
  now = old_now
  raise = old_raise
  core.read_env = old_read_env
  with_lock = old_with_lock
  if not ok then
    error(err, 0)
  end
  return logs, raises
end

local function count_kind(operations, kind)
  local count = 0
  for _, operation in ipairs(operations or {}) do
    if operation.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function first_kind(operations, kind)
  for _, operation in ipairs(operations or {}) do
    if operation.kind == kind then
      return operation
    end
  end
  return nil
end

local function logs_contain(logs, needle)
  for _, message in ipairs(logs or {}) do
    if message:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function candidate_event()
  return {
    queue = "github-external-pr-intake.external_pr_candidate",
    payload = {
      schema = "github-external-pr-intake.v1",
      repo = "owner/repo",
      number = 7,
      dedup_key = "github-external-pr-intake/owner/repo/pr/7",
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    },
  }
end

local function assert_origin_fixture(pr, signer, branch, base_branch)
  t.eq(pr.head_ref_name, "feature/contrib")
  t.eq(pr.base_ref_name, "dev")
  t.eq(#pr.comments, 1)
  t.eq(pr.comments[1].author_login, signer)
  t.eq(pr.comments[1].body, pr_origin_marker(branch, base_branch))
end

local function assert_origin_comment_does_not_change_outcome(signer, branch, base_branch)
  local scan_pr = production_pr(signer, branch, base_branch)
  assert_origin_fixture(scan_pr, signer, branch, base_branch)
  local scan_github = fake_github(scan_pr)
  local scan_logs, scan_raises = run_event(scan_github, {
    queue = "github-external-pr-intake.external_pr_scan",
    payload = { schema = "github-external-pr-intake.v1" },
  }, false)

  t.eq(#scan_raises, 1)
  t.eq(scan_raises[1].queue, "external_pr_candidate")
  t.eq(scan_raises[1].payload.schema, "github-external-pr-intake.v1")
  t.eq(scan_raises[1].payload.repo, "owner/repo")
  t.eq(scan_raises[1].payload.number, 7)
  t.eq(scan_raises[1].payload.updated_at, "2026-06-19T01:02:03Z")
  t.eq(scan_raises[1].payload.dedup_key, "github-external-pr-intake/owner/repo/pr/7")
  t.eq(scan_raises[1].payload.source_ref.kind, "external")
  t.eq(scan_raises[1].payload.source_ref.ref, "owner/repo#pr/7")
  t.eq(count_kind(scan_github.operations, "issue_assign"), 0)
  t.eq(count_kind(scan_github.operations, "issue_create"), 0)
  t.eq(count_kind(scan_github.operations, "pr_comment"), 0)
  t.eq(count_kind(scan_github.operations, "issue_close"), 0)
  t.eq(logs_contain(scan_logs, "action=skip-"), false)

  local candidate_pr = production_pr(signer, branch, base_branch)
  assert_origin_fixture(candidate_pr, signer, branch, base_branch)
  local candidate_github = fake_github(candidate_pr)
  local candidate_logs, candidate_raises = run_event(candidate_github, candidate_event(), true)

  t.eq(#candidate_raises, 0)
  t.eq(count_kind(candidate_github.operations, "issue_assign"), 1)
  t.eq(count_kind(candidate_github.operations, "issue_create"), 1)
  t.eq(count_kind(candidate_github.operations, "pr_comment"), 1)
  t.eq(count_kind(candidate_github.operations, "issue_close"), 0)

  local assign = first_kind(candidate_github.operations, "issue_assign")
  t.eq(assign.repo, "owner/repo")
  t.eq(assign.issue_number, 7)
  t.eq(assign.login, "fkst-test-bot")
  t.eq(assign.timeout, 30)

  local create = first_kind(candidate_github.operations, "issue_create")
  t.eq(create.repo, "owner/repo")
  t.eq(create.title, "Integrate external PR #7 from @trusted-contributor")
  t.eq(#create.labels, 0)
  t.eq(#create.assignees, 0)
  t.eq(create.timeout, 30)
  t.is_true(create.body:find(
    '<!-- fkst:github-external-pr-intake:external-pr-bridge:v1 repo="owner/repo" pr="7" source_ref="external:owner/repo#pr/7" -->',
    1,
    true
  ) ~= nil)
  t.is_nil(create.body:find("fkst:github-devloop:pr-origin:v1", 1, true))

  local bridge_comment = first_kind(candidate_github.operations, "pr_comment")
  t.eq(bridge_comment.repo, "owner/repo")
  t.eq(bridge_comment.pr_number, 7)
  t.eq(bridge_comment.timeout, 30)
  t.eq(
    bridge_comment.body,
    '<!-- fkst:github-external-pr-intake:external-pr-bridge:v1 repo="owner/repo" pr="7" source_ref="external:owner/repo#pr/7" issue="77" -->\n'
  )
  t.is_true(logs_contain(candidate_logs, "action=created-bridge"))
  t.eq(logs_contain(candidate_logs, "action=skip-"), false)
end

local function with_env(values, fn)
  local old_read_env = core.read_env
  core.read_env = function(name)
    return values[name] or ""
  end
  local ok, result = pcall(fn)
  core.read_env = old_read_env
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_external_login_comparison_treats_mixed_case_managed_bot_as_external = function()
    local managed = { ["managed-bot"] = true }
    t.eq(core.strip_bot_login_suffix("Managed-Bot[bot]"), "Managed-Bot")
    t.eq(core.is_managed_bot_login("managed-bot[bot]", managed), true)
    t.eq(core.is_managed_bot_login("Managed-Bot[bot]", managed), false)

    with_env({ FKST_EXTERNAL_PR_BRIDGE_MIN_AGE_SECONDS = "" }, function()
      t.eq(core.is_external_candidate({
        number = 7,
        state = "OPEN",
        author_login = "Managed-Bot[bot]",
        head_ref_name = "feature/contrib",
        created_at = "2026-06-03T01:02:03Z",
      }, managed, 1780459324), true)
    end)
  end,

  test_external_intake_raises_mixed_case_managed_bot_author_as_external_candidate = function()
    local pr = production_pr("fkst-test-bot[bot]", "feature/contrib", "dev")
    pr.author_login = "Other-Bot[bot]"
    local github = fake_github(pr, pr.author_login)

    local logs, raises = run_event(github, {
      queue = "github-external-pr-intake.external_pr_scan",
      payload = { schema = "github-external-pr-intake.v1" },
    }, false)

    t.eq(#raises, 1)
    t.eq(raises[1].queue, "external_pr_candidate")
    t.eq(raises[1].payload.repo, "owner/repo")
    t.eq(raises[1].payload.number, 7)
    t.eq(raises[1].payload.source_ref.ref, "owner/repo#pr/7")
    t.eq(count_kind(github.operations, "issue_assign"), 0)
    t.eq(count_kind(github.operations, "issue_create"), 0)
    t.eq(count_kind(github.operations, "pr_comment"), 0)
    t.eq(logs_contain(logs, "action=skip-"), false)
  end,

  test_trusted_current_pr_origin_comment_is_ignored_by_intake = function()
    assert_origin_comment_does_not_change_outcome("fkst-test-bot[bot]", "feature/contrib", "dev")
  end,

  test_trusted_stale_pr_origin_comment_is_ignored_by_intake = function()
    assert_origin_comment_does_not_change_outcome("fkst-test-bot[bot]", "feature/previous", "main")
  end,

  test_peer_bot_current_pr_origin_comment_is_ignored_by_intake = function()
    assert_origin_comment_does_not_change_outcome("other-bot[bot]", "feature/contrib", "dev")
  end,

  test_peer_bot_stale_pr_origin_comment_is_ignored_by_intake = function()
    assert_origin_comment_does_not_change_outcome("other-bot[bot]", "feature/previous", "main")
  end,
}
