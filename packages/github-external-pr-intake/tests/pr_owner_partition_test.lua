local core = require("core")
local forge_strings = require("forge.strings")
local pr_origin = require("contract.github_devloop_pr_origin")
local strings = require("contract.strings")
local t = fkst.test

local repo = "owner/repo"
local upstream_branch = "dev"
local integration_branch = "integration-fkst-test-bot"
local now_seconds = 1780459324

local managed = {
  ["fkst-test-bot"] = true,
  ["other-bot"] = true,
}

local function pr_origin_marker(issue_number, branch, base_branch)
  return '<!-- fkst:github-devloop:pr-origin:v1 proposal="github-devloop/issue/'
    .. repo
    .. "/"
    .. tostring(issue_number)
    .. '" issue="'
    .. tostring(issue_number)
    .. '" branch="'
    .. tostring(branch)
    .. '" impl_version="ready/v1" base_branch="'
    .. tostring(base_branch)
    .. '" -->'
end

local function owner_pr(fields)
  fields = fields or {}
  local is_cross_repository = fields.is_cross_repository
  if is_cross_repository == nil then
    is_cross_repository = false
  end
  return {
    repo = repo,
    number = fields.number or 7,
    title = fields.title or "Operator hotfix",
    state = fields.state or "OPEN",
    author_login = fields.author_login or "fkst-test-bot",
    head_ref_name = fields.head_ref_name or "fix/operator-hotfix",
    base_ref_name = fields.base_ref_name or upstream_branch,
    is_cross_repository = is_cross_repository,
    created_at = fields.created_at or "2026-06-03T01:02:03Z",
    updated_at = fields.updated_at or "2026-06-03T04:02:03Z",
    comments = fields.comments or {},
    assignees = fields.assignees or {},
  }
end

local function owner_kind(pr, is_authorized_author)
  local previous_read_env = core.read_env
  core.read_env = function(name)
    return ({
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_GITHUB_WRITE = "",
    })[name] or ""
  end
  local ok, origin = pcall(core.find_current_issue_pr_origin, pr)
  core.read_env = previous_read_env
  if not ok then
    error(origin, 0)
  end
  local has_actionable_issue_origin = origin ~= nil
  return core.classify_pr_owner(pr, managed, {
    upstream = upstream_branch,
    integration = integration_branch,
  }, is_authorized_author ~= false, has_actionable_issue_origin).kind
end

local function contains(errors, needle)
  for _, message in ipairs(errors or {}) do
    if tostring(message):find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function copy_declarations_without(kind)
  local copied = {}
  for _, declaration in ipairs(core.pr_owner_declarations()) do
    if declaration.kind ~= kind then
      table.insert(copied, declaration)
    end
  end
  return copied
end

local function pr_json(pr)
  local comments = {}
  for _, comment in ipairs(pr.comments or {}) do
    table.insert(comments, table.concat({
      '{"body":',
      strings.json_string(comment.body),
      ',"author":{"login":',
      strings.json_string(comment.author_login),
      "}}",
    }))
  end
  local assignees = {}
  for _, login in ipairs(pr.assignees or {}) do
    table.insert(assignees, '{"login":' .. strings.json_string(login) .. "}")
  end
  return table.concat({
    '{"number":',
    tostring(pr.number),
    ',"title":',
    strings.json_string(pr.title),
    ',"headRefName":',
    strings.json_string(pr.head_ref_name),
    ',"baseRefName":',
    strings.json_string(pr.base_ref_name),
    ',"isCrossRepository":',
    tostring(pr.is_cross_repository),
    ',"state":"OPEN","createdAt":',
    strings.json_string(pr.created_at),
    ',"updatedAt":',
    strings.json_string(pr.updated_at),
    ',"author":{"login":',
    strings.json_string(pr.author_login),
    '},"comments":[',
    table.concat(comments, ","),
    '],"assignees":[',
    table.concat(assignees, ","),
    "]}",
  })
end

local function issue_json(issue)
  local assignees = {}
  for _, login in ipairs(issue.assignees or {}) do
    table.insert(assignees, '{"login":' .. strings.json_string(login) .. "}")
  end
  local labels = {}
  for _, name in ipairs(issue.labels or {}) do
    table.insert(labels, '{"name":' .. strings.json_string(name) .. "}")
  end
  return table.concat({
    '{"number":', tostring(issue.number),
    ',"state":"OPEN","author":{"login":', strings.json_string(issue.author_login),
    '},"assignees":[', table.concat(assignees, ","),
    '],"labels":[', table.concat(labels, ","), "]}",
  })
end

local function fake_github(prs, backing_issues)
  local by_number = {}
  local model = {
    backing_issues = backing_issues or {},
    bridge_issues = {},
    comments = {},
    writes = {},
  }
  for _, pr in ipairs(prs) do
    by_number[pr.number] = pr
  end
  local github = { _model = model }

  function github.is_authorized_author(login)
    return login == "fkst-test-bot" or login == "trusted-contributor"
  end

  function github.pr_list(_repo, _timeout)
    local encoded = {}
    for _, pr in ipairs(prs) do
      table.insert(encoded, pr_json(pr))
    end
    return { stdout = "[" .. table.concat(encoded, ",") .. "]\n", exit_code = 0 }
  end

  function github.pr_cli_view(_repo, number, _fields, _timeout)
    return { stdout = pr_json(by_number[number]) .. "\n", exit_code = 0 }
  end

  function github.issue_search(_repo, query, _fields, _timeout)
    local encoded = {}
    for _, issue in pairs(model.bridge_issues) do
      if issue.body:find(query, 1, true) ~= nil then
        table.insert(encoded, table.concat({
          '{"number":', tostring(issue.number),
          ',"title":', strings.json_string(issue.title),
          ',"state":"OPEN","author":{"login":"fkst-test-bot"},"body":',
          strings.json_string(issue.body), ',"comments":[]}',
        }))
      end
    end
    return { stdout = "[" .. table.concat(encoded, ",") .. "]\n", exit_code = 0 }
  end

  function github.issue_view(_repo, number, _fields, _timeout)
    local issue = model.backing_issues[number]
    if issue == nil then
      return { stdout = "{}\n", exit_code = 0 }
    end
    return { stdout = issue_json(issue) .. "\n", exit_code = 0 }
  end

  function github.issue_assign(_repo, number, login, _timeout)
    by_number[number].assignees = { login }
    table.insert(model.writes, { kind = "issue_assign", number = number, login = login })
    return { stdout = "", exit_code = 0 }
  end

  function github.issue_create(_repo, title, body_file, _labels, _assignees, _timeout)
    local issue = {
      number = 77,
      title = title,
      body = file.read(body_file),
    }
    model.bridge_issues[issue.number] = issue
    table.insert(model.writes, { kind = "issue_create", title = title, body = issue.body })
    return { stdout = "https://github.com/owner/repo/issues/77\n", exit_code = 0 }
  end

  function github.pr_comment(_repo, number, body_file, _timeout)
    local body = file.read(body_file)
    table.insert(by_number[number].comments, { author_login = "fkst-test-bot", body = body })
    table.insert(model.comments, { number = number, body = body })
    table.insert(model.writes, { kind = "pr_comment", number = number })
    return { stdout = "", exit_code = 0 }
  end

  function github.pr_close(_repo, number, _timeout)
    by_number[number].state = "CLOSED"
    table.insert(model.writes, { kind = "pr_close", number = number })
    return { stdout = "", exit_code = 0 }
  end

  function github.issue_close(_repo, number, _timeout)
    table.insert(model.writes, { kind = "issue_close", number = number })
    return { stdout = "", exit_code = 0 }
  end

  return github
end

local function run_events(github, events)
  local old_file = file
  local old_log = log
  local old_now = now
  local old_raise = raise
  local old_read_env = core.read_env
  local old_with_lock = with_lock
  local files = {}
  local raised = {}

  file = {
    read = function(path) return files[path] or "" end,
    write = function(path, body) files[path] = body end,
  }
  log = { info = function() end, warn = function() end, error = function() end }
  now = function() return now_seconds end
  raise = function(queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  core.read_env = function(name)
    return ({
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_GITHUB_REPO = repo,
      FKST_GITHUB_WRITE = "1",
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot,other-bot",
      FKST_DEVLOOP_UPSTREAM_BRANCH = upstream_branch,
      FKST_DEVLOOP_INTEGRATION_BRANCH = integration_branch,
      FKST_EXTERNAL_PR_BRIDGE_MIN_AGE_SECONDS = "1",
    })[name] or ""
  end
  with_lock = function(_key, fn) return fn() end

  local ok, err = pcall(function()
    local previous_pipeline = pipeline
    local module = require("departments.external_pr_intake.main")
    pipeline = previous_pipeline
    local department = module.make_department({ github = github })
    for _, event in ipairs(events) do
      department.pipeline(event)
    end
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
  return raised
end

return {
  test_owner_declarations_are_total_and_disjoint = function()
    t.eq(#core.pr_owner_conformance_errors(), 0)

    for _, rollup in ipairs({ false, true }) do
      for _, origin in ipairs({ false, true }) do
        for _, managed_author in ipairs({ false, true }) do
          for _, authorized_author in ipairs({ false, true }) do
            for _, cross_repository in ipairs({ false, true }) do
              local expected
              if rollup then
                expected = "integration-promotion"
              elseif origin then
                expected = "github-devloop-pr"
              elseif not authorized_author then
                expected = "unauthorized-pr-retirement"
              elseif cross_repository then
                expected = "external-pr-bridge"
              elseif managed_author then
                expected = "operator-hotfix-bridge"
              else
                expected = "same-repository-pr"
              end
              local owner = core.classify_pr_owner_facts({
                is_integration_rollup = rollup,
                has_actionable_issue_origin = origin,
                is_managed_author = managed_author,
                is_authorized_author = authorized_author,
                is_cross_repository = cross_repository,
              })
              t.eq(owner.kind, expected)
            end
          end
        end
      end
    end
  end,

  test_owner_conformance_rejects_unowned_and_ambiguous_fact_shapes = function()
    local without_operator = copy_declarations_without("operator-hotfix-bridge")
    t.is_true(contains(core.pr_owner_conformance_errors(without_operator), "unowned facts"))

    local overlapping = copy_declarations_without("missing-kind")
    table.insert(overlapping, core.pr_owner_declarations()[4])
    t.is_true(contains(core.pr_owner_conformance_errors(overlapping), "ambiguous facts"))
  end,

  test_owner_conformance_reports_malformed_declarations_without_crashing = function()
    local errors = core.pr_owner_conformance_errors({ "not-a-declaration", { match = {} } })
    t.is_true(contains(errors, "must be a table"))
    t.is_true(contains(errors, "requires kind"))
  end,

  test_pr_origin_fact_normalizes_login_case_on_both_sides = function()
    local origin = pr_origin.fact({ {
      author_login = "fkst-test-bot[bot]",
      body = pr_origin_marker(42, "fix/generated", integration_branch),
    } }, {
      trusted_bot_login = "FKST-Test-Bot",
      is_git_ref_safe = forge_strings.is_git_ref_safe,
    })

    t.eq(origin.issue_number, "42")
  end,

  test_runtime_classification_uses_trusted_origin_and_exact_rollup_facts = function()
    local origin = pr_origin_marker(42, "fix/generated", integration_branch)
    t.eq(owner_kind(owner_pr({
      head_ref_name = integration_branch,
      base_ref_name = upstream_branch,
      comments = { { author_login = "fkst-test-bot", body = origin } },
    })), "integration-promotion")

    t.eq(owner_kind(owner_pr({
      head_ref_name = "fix/generated",
      base_ref_name = integration_branch,
      comments = { { author_login = "fkst-test-bot", body = origin } },
    })), "github-devloop-pr")

    t.eq(owner_kind(owner_pr({
      comments = { { author_login = "untrusted-contributor", body = origin } },
    })), "operator-hotfix-bridge")
    t.eq(owner_kind(owner_pr({
      author_login = "trusted-contributor",
      is_cross_repository = true,
    })), "external-pr-bridge")
    t.eq(owner_kind(owner_pr({ author_login = "trusted-contributor" })), "same-repository-pr")
    t.eq(owner_kind(owner_pr({ author_login = "untrusted-contributor" }), false), "unauthorized-pr-retirement")
  end,

  test_scan_routes_peer_managed_origin_to_operator_bridge = function()
    local origin = pr_origin_marker(42, "fix/generated", integration_branch)
    local github = fake_github({
      owner_pr({
        number = 5,
        head_ref_name = "fix/generated",
        base_ref_name = integration_branch,
        comments = { { author_login = "other-bot", body = origin } },
      }),
    }, {
      [42] = { number = 42, author_login = "fkst-test-bot", assignees = {}, labels = {} },
    })

    local raised = run_events(github, {
      { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })

    t.eq(#raised, 1)
    t.eq(raised[1].payload.number, 5)
    t.eq(raised[1].payload.owner_kind, "operator-hotfix-bridge")
  end,

  test_label_mode_self_authored_unassigned_origin_stays_with_devloop = function()
    for _ = 1, 4 do
      t.mock_command('printf %s "$FKST_GITHUB_CLAIM_MODE"', {
        stdout = "label",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
        stdout = "fkst-test-bot",
        stderr = "",
        exit_code = 0,
      })
    end

    local origin = pr_origin_marker(42, "fix/generated", integration_branch)
    local github = fake_github({
      owner_pr({
        number = 5,
        head_ref_name = "fix/generated",
        base_ref_name = integration_branch,
        comments = { { author_login = "fkst-test-bot", body = origin } },
      }),
    }, {
      [42] = { number = 42, author_login = "fkst-test-bot", assignees = {}, labels = {} },
    })

    local raised = run_events(github, {
      { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })

    t.eq(#raised, 0)
    t.eq(#github._model.writes, 0)
  end,

  test_scan_retires_unauthorized_pr_with_durable_why = function()
    local github = fake_github({
      owner_pr({ number = 5, author_login = "untrusted-contributor", head_ref_name = "feature/untrusted" }),
    })

    local raised = run_events(github, {
      { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })

    t.eq(#raised, 0)
    t.eq(#github._model.writes, 2)
    t.eq(github._model.writes[1].kind, "pr_comment")
    t.eq(github._model.writes[1].number, 5)
    t.is_true(github._model.comments[1].body:find(
      'pr-disposition:v1 repo="owner/repo" pr="5" owner="unauthorized-pr-retirement" outcome="retired" why="non-authorized-author"',
      1,
      true
    ) ~= nil)
    t.eq(github._model.writes[2].kind, "pr_close")
    t.eq(github._model.writes[2].number, 5)
  end,

  test_scan_routes_only_bridge_owned_prs_and_operator_candidate_materializes_issue = function()
    local origin = pr_origin_marker(42, "fix/generated", integration_branch)
    local github = fake_github({
      owner_pr({
        number = 1,
        head_ref_name = "fix/generated",
        base_ref_name = integration_branch,
        comments = { { author_login = "fkst-test-bot", body = origin } },
      }),
      owner_pr({ number = 2, head_ref_name = integration_branch, base_ref_name = upstream_branch }),
      owner_pr({ number = 3, head_ref_name = "fix/operator-hotfix" }),
      owner_pr({
        number = 4,
        author_login = "trusted-contributor",
        head_ref_name = "feature/contrib",
        is_cross_repository = true,
      }),
    }, {
      [42] = { number = 42, author_login = "fkst-test-bot", assignees = {}, labels = {} },
    })

    local raised = run_events(github, {
      { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })
    t.eq(#raised, 2)
    t.eq(raised[1].payload.number, 3)
    t.eq(raised[1].payload.owner_kind, "operator-hotfix-bridge")
    t.eq(raised[2].payload.number, 4)
    t.eq(raised[2].payload.owner_kind, "external-pr-bridge")

    run_events(github, { raised[1] })
    t.eq(#github._model.writes, 3)
    t.eq(github._model.writes[1].kind, "issue_assign")
    t.eq(github._model.writes[2].kind, "issue_create")
    t.eq(github._model.writes[2].title, "Integrate operator hotfix PR #3 from @fkst-test-bot")
    t.is_true(github._model.writes[2].body:find("operator hotfix", 1, true) ~= nil)
    t.eq(github._model.writes[3].kind, "pr_comment")
  end,

  test_scan_routes_stale_or_unclaimed_trusted_origins_to_operator_bridge = function()
    local current_origin = pr_origin_marker(42, "fix/generated", integration_branch)
    local github = fake_github({
      owner_pr({
        number = 5,
        head_ref_name = "fix/changed-after-origin",
        base_ref_name = integration_branch,
        comments = { { author_login = "fkst-test-bot", body = current_origin } },
      }),
      owner_pr({
        number = 6,
        head_ref_name = "fix/generated",
        base_ref_name = integration_branch,
        comments = { { author_login = "fkst-test-bot", body = current_origin } },
      }),
    }, {
      [42] = { number = 42, author_login = "other-bot", assignees = { "other-bot" }, labels = {} },
    })

    local raised = run_events(github, {
      { queue = "external_pr_scan", payload = { schema = "github-external-pr-intake.v1" } },
    })

    t.eq(#raised, 2)
    t.eq(raised[1].payload.number, 5)
    t.eq(raised[1].payload.owner_kind, "operator-hotfix-bridge")
    t.eq(raised[2].payload.number, 6)
    t.eq(raised[2].payload.owner_kind, "operator-hotfix-bridge")

    run_events(github, { raised[1] })
    t.eq(github._model.writes[1].kind, "issue_assign")
    t.eq(github._model.writes[2].kind, "issue_create")
    t.eq(github._model.writes[3].kind, "pr_comment")
  end,
}
