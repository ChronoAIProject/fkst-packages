local strings = require("contract.strings")
local claim_labels = require("devloop.claim_labels")
local t = fkst.test

local package_root = "packages/github-external-pr-intake"

local function load_department()
  local old_pipeline = pipeline
  local module = require("departments.external_pr_intake.main")
  pipeline = old_pipeline
  return module
end

local function json_string(value)
  return strings.json_string(value)
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if not (ok == true or ok == 0) then
    error("github-external-pr-intake: mkdir failed for " .. tostring(path))
  end
end

local function parent_dir(path)
  return tostring(path):match("^(.*)/[^/]+$") or "."
end

local function sibling_package_root(name)
  return parent_dir(package_root) .. "/" .. tostring(name)
end

local function write_disk_file(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

local function read_disk_file(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function wait_for_file(path, attempts)
  for _ = 1, attempts or 100 do
    if file.exists(path) then
      return true
    end
    os.execute("sleep 0.02")
  end
  return false
end

local function start_python_background(script, args)
  local parts = { "python3", shell_quote(script) }
  for _, arg in ipairs(args or {}) do
    table.insert(parts, shell_quote(arg))
  end
  local ok = os.execute(table.concat(parts, " ") .. " &")
  if not (ok == true or ok == 0) then
    error("github-external-pr-intake: failed to start python helper")
  end
end

local function pr_json(pr)
  local comments = {}
  for _, comment in ipairs(pr.comments or {}) do
    table.insert(comments, '{"body":' .. json_string(comment.body or "")
      .. ',"author":{"login":' .. json_string(comment.author_login or "fkst-test-bot") .. "}}")
  end
  local assignees = {}
  for _, login in ipairs(pr.assignees or {}) do
    table.insert(assignees, '{"login":' .. json_string(login) .. "}")
  end
  local labels = {}
  for _, label in ipairs(pr.labels or {}) do
    table.insert(labels, '{"name":' .. json_string(label) .. "}")
  end
  local is_cross_repository = pr.is_cross_repository
  if is_cross_repository == nil then
    is_cross_repository = true
  end
  return '{"number":' .. tostring(pr.number or 7)
    .. ',"title":' .. json_string(pr.title or "Contributor patch")
    .. ',"headRefName":' .. json_string(pr.head_ref_name or "feature/contrib")
    .. ',"baseRefName":' .. json_string(pr.base_ref_name or "dev")
    .. ',"state":' .. json_string(pr.state or "OPEN")
    .. ',"createdAt":' .. json_string(pr.created_at or "2026-06-03T01:02:03Z")
    .. ',"updatedAt":' .. json_string(pr.updated_at or "2026-06-19T01:02:03Z")
    .. ',"isCrossRepository":' .. tostring(is_cross_repository)
    .. ',"author":{"login":' .. json_string(pr.author_login or "contributor")
    .. '},"comments":[' .. table.concat(comments, ",")
    .. '],"assignees":[' .. table.concat(assignees, ",")
    .. '],"labels":[' .. table.concat(labels, ",") .. "]}\n"
end

local function pr_list_json(prs)
  local parts = {}
  for _, pr in pairs(prs or {}) do
    table.insert(parts, (pr_json(pr):gsub("%s+$", "")))
  end
  return "[" .. table.concat(parts, ",") .. "]\n"
end

local function issue_json(issue)
  return '{"number":' .. tostring(issue.number or 77)
    .. ',"title":' .. json_string(issue.title or "Bridge")
    .. ',"state":' .. json_string(issue.state or "OPEN")
    .. ',"url":' .. json_string(issue.url or "https://github.com/owner/repo/issues/" .. tostring(issue.number or 77))
    .. ',"labels":[' .. table.concat((function()
      local labels = {}
      for _, label in ipairs(issue.labels or {}) do
        table.insert(labels, '{"name":' .. json_string(label) .. "}")
      end
      return labels
    end)(), ",") .. "]"
    .. ',"comments":[' .. table.concat((function()
      local comments = {}
      for _, comment in ipairs(issue.comments or {}) do
        table.insert(comments, '{"body":' .. json_string(comment.body or "")
          .. ',"author":{"login":' .. json_string(comment.author_login or "fkst-test-bot") .. "}}")
      end
      return comments
    end)(), ",") .. "]"
    .. ',"author":{"login":' .. json_string(issue.author_login or "fkst-test-bot")
    .. '},"body":' .. json_string(issue.body or "") .. "}"
end

local function new_fake_github(opts)
  local options = opts or {}
  local model = {
    writes = {},
    prs = options.prs or {
      [7] = {
        number = 7,
        title = "Contributor patch",
        author_login = "contributor",
        head_ref_name = "feature/contrib",
        base_ref_name = "dev",
        state = "OPEN",
        comments = {},
        assignees = {},
        labels = {},
      },
    },
    list = options.list,
    issues = options.issues or {},
    next_issue = options.next_issue or 77,
    hidden_issues_until_create = options.hidden_issues_until_create == true,
    hidden_issues_until_creates = options.hidden_issues_until_creates or 0,
    hidden_comments_until_creates = options.hidden_comments_until_creates or 0,
    issue_create_yield = options.issue_create_yield,
    fail_pr_cli_view_once = options.fail_pr_cli_view_once,
    pr_read_mutator = options.pr_read_mutator,
    pr_view_count = 0,
    created_count = 0,
  }
  local handle = { _model = model, is_authorized_author = function(_login) return true end }
  function handle.pr_list(repo, timeout)
    table.insert(model.writes, { kind = "pr_list", repo = repo, timeout = timeout })
    return { stdout = pr_list_json(model.list or model.prs), stderr = "", exit_code = 0 }
  end
  function handle.pr_cli_view(repo, pr_number, fields, timeout)
    table.insert(model.writes, { kind = "pr_cli_view", repo = repo, pr_number = pr_number, fields = fields, timeout = timeout })
    if model.fail_pr_cli_view_once then
      model.fail_pr_cli_view_once = false
      error("fake: transient PR view failure")
    end
    local pr = model.prs[pr_number]
    if pr == nil then
      error("fake: unknown PR " .. tostring(pr_number))
    end
    model.pr_view_count = model.pr_view_count + 1
    if type(model.pr_read_mutator) == "function" then
      model.pr_read_mutator(model, pr, model.pr_view_count)
    end
    if model.created_count < model.hidden_comments_until_creates then
      local hidden = {}
      for key, value in pairs(pr) do
        if key ~= "comments" then
          hidden[key] = value
        end
      end
      hidden.comments = {}
      return { stdout = pr_json(hidden), stderr = "", exit_code = 0 }
    end
    return { stdout = pr_json(pr), stderr = "", exit_code = 0 }
  end
  function handle.issue_search(repo, query, fields, timeout)
    table.insert(model.writes, { kind = "issue_search", repo = repo, query = query, fields = fields, timeout = timeout })
    local parts = {}
    if (not model.hidden_issues_until_create or model.created_count > 0)
      and model.created_count >= model.hidden_issues_until_creates then
      for _, issue in ipairs(model.issues or {}) do
        if tostring(issue.body or ""):find(query, 1, true) ~= nil then
          table.insert(parts, issue_json(issue))
        end
      end
    end
    return { stdout = "[" .. table.concat(parts, ",") .. "]\n", stderr = "", exit_code = 0 }
  end
  function handle.issue_view(repo, issue_number, fields, timeout)
    table.insert(model.writes, { kind = "issue_view", repo = repo, issue_number = issue_number, fields = fields, timeout = timeout })
    for _, issue in ipairs(model.issues or {}) do
      if tonumber(issue.number) == tonumber(issue_number) then
        return { stdout = issue_json(issue), stderr = "", exit_code = 0 }
      end
    end
    error("fake: unknown issue " .. tostring(issue_number))
  end
  function handle.issue_add_label(repo, issue_number, label, timeout)
    table.insert(model.writes, { kind = "issue_add_label", repo = repo, issue_number = issue_number, label = label, timeout = timeout })
    local pr = model.prs[issue_number]
    pr.labels = pr.labels or {}
    for _, existing in ipairs(pr.labels) do
      if existing == label then
        return { stdout = "", stderr = "", exit_code = 0 }
      end
    end
    table.insert(pr.labels, label)
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function handle.issue_remove_label(repo, issue_number, label, timeout)
    table.insert(model.writes, { kind = "issue_remove_label", repo = repo, issue_number = issue_number, label = label, timeout = timeout })
    local pr = model.prs[issue_number]
    local kept = {}
    for _, existing in ipairs(pr.labels or {}) do
      if existing ~= label then
        table.insert(kept, existing)
      end
    end
    pr.labels = kept
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function handle.issue_create(repo, title, body_file, labels, assignees, timeout)
    local body = file.read(body_file)
    table.insert(model.writes, { kind = "issue_create", repo = repo, title = title, body = body, labels = labels, assignees = assignees, timeout = timeout })
    model.created_count = model.created_count + 1
    local issue_number = model.next_issue
    table.insert(model.issues, {
      number = issue_number,
      author_login = "fkst-test-bot",
      state = "OPEN",
      body = body,
    })
    model.next_issue = model.next_issue + 1
    if type(model.issue_create_yield) == "function" then
      model.issue_create_yield(model, issue_number)
    end
    return { stdout = "https://github.com/" .. tostring(repo) .. "/issues/" .. tostring(issue_number) .. "\n", stderr = "", exit_code = 0 }
  end
  function handle.pr_comment(repo, pr_number, body_file, timeout)
    local body = file.read(body_file)
    table.insert(model.writes, { kind = "pr_comment", repo = repo, pr_number = pr_number, body = body, timeout = timeout })
    local pr = model.prs[pr_number]
    pr.comments = pr.comments or {}
    table.insert(pr.comments, { author_login = "fkst-test-bot", body = body })
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  function handle.issue_close(repo, issue_number, disposition, timeout)
    table.insert(model.writes, { kind = "issue_close", repo = repo, issue_number = issue_number, disposition = disposition, timeout = timeout })
    for _, issue in ipairs(model.issues or {}) do
      if tonumber(issue.number) == tonumber(issue_number) then
        issue.state = "CLOSED"
      end
    end
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  return handle
end

local function run_pipeline(opts)
  local options = opts or {}
  local github = options.github or new_fake_github(options.github_opts)
  local files = {}
  local raises = {}
  local locks = {}
  local old_file = file
  local old_log = log
  local old_raise = raise
  local old_with_lock = with_lock
  local old_now = now
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
  with_lock = function(key, fn)
    table.insert(locks, key)
    return fn()
  end
  now = function()
    return options.now_seconds or 1780459324
  end

  local module = load_department()
  local claim_label = "fkst-dev:claimed:fkst-test-bot"
  local claims = {
    claimed_label = function()
      return claim_label
    end,
    issue_claim_state = function(labels)
      return claim_labels.classify(labels, claim_label)
    end,
  }
  local dept = module.make_department({ github = github }, claims)
  local core = require("core")
  local old_read = core.read_env
  local env = options.env or {
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_WRITE = "1",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot,other-bot",
  }
  core.read_env = function(name)
    return env[name] or ""
  end
  local ok, err = pcall(function()
    dept.pipeline(options.event)
  end)
  core.read_env = old_read
  file = old_file
  log = old_log
  raise = old_raise
  with_lock = old_with_lock
  now = old_now
  if not ok then
    error(err, 0)
  end
  return { github = github, files = files, raises = raises, locks = locks }
end

local function count_kind(writes, kind)
  local count = 0
  for _, write in ipairs(writes or {}) do
    if write.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function write_of_kind(writes, kind, ordinal)
  local seen = 0
  for _, write in ipairs(writes or {}) do
    if write.kind == kind then
      seen = seen + 1
      if seen == (ordinal or 1) then
        return write
      end
    end
  end
  return nil
end

local function candidate_event(number)
  number = number or 7
  return {
    queue = "external_pr_candidate",
    payload = {
      schema = "github-external-pr-intake.v1",
      repo = "owner/repo",
      number = number,
      dedup_key = "github-external-pr-intake/owner/repo/pr/" .. tostring(number),
      source_ref = {
        kind = "external",
        ref = "owner/repo#pr/" .. tostring(number),
      },
    },
  }
end

local function count_open_bridge_issues(github)
  local count = 0
  local issue_number = nil
  for _, issue in ipairs(github._model.issues or {}) do
    if tostring(issue.state or ""):upper() ~= "CLOSED" then
      count = count + 1
      issue_number = issue.number
    end
  end
  return count, issue_number
end

local function count_pr_bridge_markers(github, pr_number)
  local count = 0
  local marker_body = nil
  for _, comment in ipairs((github._model.prs[pr_number] or {}).comments or {}) do
    if tostring(comment.body or ""):find('external-pr-bridge:v1 repo="owner/repo" pr="' .. tostring(pr_number) .. '"', 1, true) ~= nil then
      count = count + 1
      marker_body = comment.body
    end
  end
  return count, marker_body
end

local function resume_thread(thread)
  local ok, value = coroutine.resume(thread)
  if not ok then
    error(value, 0)
  end
  return value
end

return {
  strings = strings,
  t = t,
  package_root = package_root,
  load_department = load_department,
  json_string = json_string,
  shell_quote = shell_quote,
  mkdir_p = mkdir_p,
  parent_dir = parent_dir,
  sibling_package_root = sibling_package_root,
  write_disk_file = write_disk_file,
  read_disk_file = read_disk_file,
  wait_for_file = wait_for_file,
  start_python_background = start_python_background,
  pr_json = pr_json,
  pr_list_json = pr_list_json,
  issue_json = issue_json,
  new_fake_github = new_fake_github,
  run_pipeline = run_pipeline,
  count_kind = count_kind,
  write_of_kind = write_of_kind,
  candidate_event = candidate_event,
  count_open_bridge_issues = count_open_bridge_issues,
  count_pr_bridge_markers = count_pr_bridge_markers,
  resume_thread = resume_thread,
}
