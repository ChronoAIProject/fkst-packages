local base_ids = require("devloop.base_ids")
local core = require("core")
local digest = require("core.digest")
local entity = require("devloop.entity")
local github_fake = require("forge.github_fake")
local gh_argv = require("testkit_internal.gh_argv_mock")
local graph = require("testkit.graph")
local materialization = require("core.materialization")
local marker = require("core.marker")
local testing = require("testkit_internal.testing")

local t = fkst.test
gh_argv.install(t, core)

local repo = "owner/repo"
local origin_issue = 42
local child_issue = 108
local origin = base_ids.proposal_id(repo, origin_issue)
local tree_sha = string.rep("1", 40)
local receipt_sha = string.rep("a", 40)

local function blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "workflow-one",
    version = "2026-08-05",
    summary = "Exercise one satisfied workflow child.",
    applies_when = "The acceptance fixture selects this workflow.",
    steps = {
      {
        id = "first",
        title = "First child",
        content = {
          kind = "static",
          intent = "Complete the first child.",
        },
      },
    },
  }
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
end

local function blueprint_json(plan)
  local slot = plan.steps[1]
  return string.format(
    '{"schema":"%s","id":"%s","version":"%s","summary":"%s","applies_when":"%s","steps":[{"id":"%s","title":"%s","content":{"kind":"static","intent":"%s"}}]}',
    json_escape(plan.schema),
    json_escape(plan.id),
    json_escape(plan.version),
    json_escape(plan.summary),
    json_escape(plan.applies_when),
    json_escape(slot.id),
    json_escape(slot.title),
    json_escape(slot.content.intent)
  )
end

local function test_root()
  return "/tmp/fkst-workflow-child-disposition-run-graph-"
    .. tostring({}):gsub("[^A-Za-z0-9]", "")
end

local function with_catalog(plan, fn)
  local root = test_root()
  local path = root .. "/workflow-one.json"
  os.remove(path)
  os.execute("rmdir " .. shell_quote(root) .. " >/dev/null 2>&1")
  local made = os.execute("mkdir -p " .. shell_quote(root))
  if made ~= true and made ~= 0 then
    error("failed to create workflow catalog fixture")
  end
  file.write(path, blueprint_json(plan))
  local ok, result = pcall(fn, root)
  os.remove(path)
  os.execute("rmdir " .. shell_quote(root) .. " >/dev/null 2>&1")
  if not ok then
    error(result, 0)
  end
  return result
end

local function comment_json(comment, index, rest)
  local value = type(comment) == "table" and comment or { body = tostring(comment or "") }
  if rest then
    return string.format(
      '{"id":%d,"body":"%s","created_at":"%s","user":{"login":"%s"}}',
      index,
      json_escape(value.body),
      json_escape(value.created_at or "2026-08-05T00:00:00Z"),
      json_escape(value.author_login or "fkst-test-bot")
    )
  end
  return string.format(
    '{"id":"comment-%d","body":"%s","createdAt":"%s","author":{"login":"%s"}}',
    index,
    json_escape(value.body),
    json_escape(value.created_at or "2026-08-05T00:00:00Z"),
    json_escape(value.author_login or "fkst-test-bot")
  )
end

local function comments_json(comments, rest)
  local rendered = {}
  for index, comment in ipairs(comments or {}) do
    rendered[index] = comment_json(comment, index, rest)
  end
  local joined = table.concat(rendered, ",")
  return rest and ("[[" .. joined .. "]]\n") or joined
end

local function labels_json(labels, rest)
  local rendered = {}
  for index, label in ipairs(labels or {}) do
    rendered[index] = rest
      and ('{"name":"' .. json_escape(label) .. '"}')
      or ('{"name":"' .. json_escape(label) .. '"}')
  end
  return table.concat(rendered, ",")
end

local function issue_view_json(number, title, body, state, labels, comments)
  return string.format(
    '{"number":%d,"title":"%s","body":"%s","url":"https://github.example/%s/issues/%d","updatedAt":"2026-08-05T00:00:00Z","state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    number,
    json_escape(title),
    json_escape(body),
    repo,
    number,
    state,
    labels_json(labels),
    comments_json(comments, false)
  )
end

local function rest_issue_json(number, title, body, state, labels)
  return string.format(
    '{"number":%d,"title":"%s","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-08-05T00:00:00Z","state":"%s","labels":[%s],"assignees":[{"login":"fkst-test-bot"}],"user":{"login":"fkst-test-bot"}}\n',
    number,
    json_escape(title),
    json_escape(body),
    repo,
    number,
    state,
    labels_json(labels, true)
  )
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-05T00:00:00Z",
  }
end

local function mock_env(name, value, times)
  for _ = 1, times or 1 do
    t.mock_command('printf %s "$' .. tostring(name) .. '"', {
      stdout = tostring(value or ""),
      stderr = "",
      exit_code = 0,
    })
  end
end

local function blocked_by_json()
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n'
end

local function mock_materialization_source(catalog_root, history, child_body)
  mock_env("FKST_WORKFLOW_CATALOG_ROOT", catalog_root)
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues?state=open&per_page=100'", {
    stdout = '[[{"number":' .. tostring(origin_issue)
      .. ',"title":"Workflow origin","state":"OPEN","updatedAt":"2026-08-05T00:00:00Z"}]]\n',
    stderr = "",
    exit_code = 0,
  })
  local full_fields = "title,body,updatedAt,labels,comments,state,assignees,author"
  local origin_stdout = issue_view_json(
    origin_issue,
    "Workflow origin",
    "Run the one-slot workflow.",
    "OPEN",
    {},
    history
  )
  t.mock_command("gh issue view " .. tostring(origin_issue) .. " --repo " .. repo
    .. " --json '" .. full_fields .. "'", {
    stdout = origin_stdout,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue view " .. tostring(origin_issue) .. " --repo " .. repo
    .. " --json 'assignees,author'", {
    stdout = origin_stdout,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api graphql", {
    stdout = blocked_by_json(),
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 3 do
    t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  end
  if child_body ~= nil then
    t.mock_command("gh issue view " .. tostring(child_issue) .. " --repo " .. repo
      .. " --json 'number,title,state,author,body,url'", {
      stdout = issue_view_json(
        child_issue,
        "First child",
        child_body,
        "OPEN",
        { "fkst-dev:enabled", "fkst-dev:implementing" },
        {}
      ),
      stderr = "",
      exit_code = 0,
    })
  end
end

local function materialization_event(stage)
  return {
    queue = "github-devloop-workflow.workflow_materialization_tick",
    payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
    source_ref = {
      kind = "cron",
      reference = "github-devloop-workflow.materialization_poll/" .. tostring(stage),
    },
  }
end

local function proxy_created_fact(dedup_key)
  return "Opened sub-issue #" .. tostring(child_issue) .. " for this task.\n\n"
    .. '<!-- fkst:github-proxy:issue-created:v1 dedup="' .. tostring(dedup_key)
    .. '" issue="' .. tostring(child_issue) .. '" -->'
end

local function proxy_created_child_body(create)
  return tostring(create.payload.body)
    .. "\n\n<!-- fkst:github-proxy:issue-create:"
    .. tostring(create.payload.dedup_key)
    .. " -->"
end

local function mock_fresh_issue_reads(history, child_body, child_read_count)
  local origin_rest = rest_issue_json(
    origin_issue,
    "Workflow origin",
    "Run the one-slot workflow.",
    "open",
    {}
  )
  t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(origin_issue), {
    stdout = origin_rest,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/"
    .. tostring(origin_issue) .. "/comments?per_page=100'", {
    stdout = comments_json(history, true),
    stderr = "",
    exit_code = 0,
  })

  local child_rest = rest_issue_json(
    child_issue,
    "First child",
    child_body,
    "open",
    { "fkst-dev:enabled", "fkst-dev:implementing" }
  )
  for _ = 1, child_read_count or 2 do
    t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(child_issue), {
      stdout = child_rest,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/"
      .. tostring(child_issue) .. "/comments?per_page=100'", {
      stdout = "[[]]\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function receipt_message(identity)
  return string.format(
    '{"schema":"%s","repo":"%s","origin":"%s","blueprint_digest":"%s","slot":"%s","child_issue":"%s","disposition":"satisfied"}',
    core.child_disposition_receipt.RECEIPT_SCHEMA,
    json_escape(identity.repo),
    json_escape(identity.origin),
    json_escape(identity.blueprint_digest),
    json_escape(identity.slot),
    json_escape(identity.child_issue)
  ) .. "\n"
end

local function receipt_commit_stdout(message)
  return "tree " .. tree_sha
    .. "\nauthor FKST Test <test@example.com> 0 +0000"
    .. "\ncommitter FKST Test <test@example.com> 0 +0000"
    .. "\n\n" .. tostring(message)
end

local function mock_visible_receipt_reads(identity, message, count)
  local ref = core.child_disposition_receipt.receipt_ref(identity)
  local listed = receipt_sha .. "\t" .. ref .. "\n"
  local committed = receipt_commit_stdout(message)
  for _ = 1, count do
    t.mock_command("git ls-remote", { stdout = listed, stderr = "", exit_code = 0 })
    t.mock_command("git fetch", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git rev-parse --verify", {
      stdout = receipt_sha .. "\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("git cat-file -p", { stdout = committed, stderr = "", exit_code = 0 })
  end
end

local function mock_receipt_commit_and_readback(identity)
  t.mock_command("git ls-remote", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git rev-parse --verify 'HEAD^{tree}'", {
    stdout = tree_sha .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git commit-tree", { stdout = receipt_sha .. "\n", stderr = "", exit_code = 0 })
  t.mock_command("git push", { stdout = "", stderr = "", exit_code = 0 })
  mock_visible_receipt_reads(identity, receipt_message(identity), 2)
end

local function command_count(calls, needle)
  local total = 0
  for _, call in ipairs(calls) do
    if gh_argv.call_contains(call, needle) then
      total = total + 1
    end
  end
  return total
end

local function command_index(calls, needle, last)
  local found = nil
  for index, call in ipairs(calls) do
    if gh_argv.call_contains(call, needle) then
      found = index
      if not last then
        return index
      end
    end
  end
  return found
end

local function committed_receipt_message(calls)
  local commit_index = command_index(calls, "git commit-tree")
  if commit_index == nil then
    error("routed disposition did not commit a receipt")
  end
  local message_path = gh_argv.argv_value_after(calls[commit_index], "-F")
  if message_path == nil then
    error("routed receipt commit did not use a message file")
  end
  return assert(file.read(message_path))
end

local function count(values, expected)
  local total = 0
  for _, value in ipairs(values) do
    if value == expected then
      total = total + 1
    end
  end
  return total
end

local function index_of(values, expected)
  for index, value in ipairs(values) do
    if value == expected then
      return index
    end
  end
  return nil
end

local function load_disposition_department()
  local previous_pipeline = _G.pipeline
  local department = require("departments.workflow_child_disposition.main")
  _G.pipeline = previous_pipeline
  return department
end

local function with_test_locks(fn)
  local previous_with_lock = with_lock
  local locks = {}
  with_lock = function(key, locked)
    locks[#locks + 1] = key
    return locked()
  end
  local ok, result = pcall(fn, locks)
  with_lock = previous_with_lock
  if not ok then
    error(result, 0)
  end
  return result
end

local function fake_issue_model(history, child_body)
  return github_fake.model({
    issues = {
      [repo .. "#issue/" .. tostring(origin_issue)] = {
        repo = repo,
        number = origin_issue,
        title = "Workflow origin",
        body = "Run the one-slot workflow.",
        state = "OPEN",
        labels = {},
        assignees = { "fkst-test-bot" },
        author_login = "fkst-test-bot",
        comments = history,
      },
      [repo .. "#issue/" .. tostring(child_issue)] = {
        repo = repo,
        number = child_issue,
        title = "First child",
        body = child_body,
        state = "OPEN",
        labels = { "fkst-dev:enabled", "fkst-dev:implementing" },
        assignees = { "fkst-test-bot" },
        author_login = "fkst-test-bot",
        comments = {},
      },
    },
  })
end

local function fake_port_fixture()
  local plan = blueprint()
  local blueprint_digest = digest.blueprint_digest(plan)
  local blueprint_marker = assert(marker.build_blueprint_marker(origin, plan.id, blueprint_digest))
  local child_body = assert(marker.build_lineage_header(origin, blueprint_digest, "first"))
    .. "\n\nComplete the first child."
  local entry = assert(materialization.created_entry(
    origin,
    blueprint_digest,
    plan.steps[1],
    materialization.EMPTY_PREDECESSOR_REF_DIGEST,
    { title = "First child", body = child_body },
    child_issue
  ))
  local materialization_marker = assert(marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    entry.child_issue,
    entry.state
  ))
  local history = {
    trusted_comment(blueprint_marker),
    trusted_comment(materialization_marker),
  }
  local identity = {
    repo = repo,
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = "first",
    child_issue = tostring(child_issue),
    disposition = "satisfied",
  }
  return history, child_body, core.child_disposition_request.build(identity), identity
end

local function assert_fake_port_disposition(history, child_body, request, identity)
  local order = {}
  local stored_receipt = nil
  local receipt_store = {
    put_once = function(value)
      order[#order + 1] = "receipt-put"
      stored_receipt = {
        schema = core.child_disposition_receipt.RECEIPT_SCHEMA,
        repo = value.repo,
        origin = value.origin,
        blueprint_digest = value.blueprint_digest,
        slot = value.slot,
        child_issue = value.child_issue,
        disposition = value.disposition,
        commit_sha = receipt_sha,
      }
      return stored_receipt
    end,
    read = function(value)
      order[#order + 1] = "receipt-read"
      t.eq(value.origin, identity.origin)
      t.eq(value.blueprint_digest, identity.blueprint_digest)
      t.eq(value.slot, identity.slot)
      t.eq(tostring(value.child_issue), identity.child_issue)
      return stored_receipt
    end,
  }
  local github_model = fake_issue_model(history, child_body)
  local github = github_fake.new(github_model)
  local read_issue = github.read_issue
  github.read_issue = function(source_ref, opts)
    order[#order + 1] = "read-" .. tostring(source_ref.ref)
    t.eq(opts.force_fresh, true)
    return read_issue(source_ref, opts)
  end
  local issue_close = github.issue_close
  github.issue_close = function(close_repo, number, disposition, timeout)
    order[#order + 1] = "close"
    t.eq(close_repo, repo)
    t.eq(tostring(number), tostring(child_issue))
    t.eq(disposition.kind, "completed")
    github_model.issues[repo .. "#issue/" .. tostring(child_issue)].state = "CLOSED"
    return issue_close(close_repo, number, disposition, timeout)
  end
  local department = load_disposition_department().make_department({
    github = github,
    receipt_store = receipt_store,
    write_enabled = function() return true end,
    claim_owner = function() return "fkst-test-bot" end,
  })

  local disposition_result = with_test_locks(function(locks)
    local result = testing.run_fake(department, {
      queue = "github-devloop-workflow.workflow_child_disposition_request",
      payload = request,
      source_ref = request.source_ref,
    })
    t.eq(locks[1], entity.merge_lane_lock_key(repo))
    return result
  end)

  t.is_nil(disposition_result.failure)
  t.eq(count(order, "read-owner/repo#issue/42"), 1, "origin authority read")
  t.eq(count(order, "read-owner/repo#issue/108"), 2, "child authority reads")
  t.eq(count(order, "receipt-put"), 1, "receipt commit")
  t.eq(count(order, "receipt-read"), 1, "receipt readback")
  t.eq(count(order, "close"), 1, "completed child close")
  t.is_true(index_of(order, "receipt-put") < index_of(order, "receipt-read"))
  t.is_true(index_of(order, "receipt-read") < index_of(order, "close"))
end

return {
  test_run_graph_satisfied_receipt_closes_child_and_completes_origin = function()
    with_catalog(blueprint(), function(catalog_root)
      local plan = blueprint()
      local blueprint_digest = digest.blueprint_digest(plan)
      local blueprint_marker = assert(marker.build_blueprint_marker(origin, plan.id, blueprint_digest))
      local history = { trusted_comment(blueprint_marker) }

      mock_env("FKST_GITHUB_REPO", repo, 12)
      mock_env("FKST_GITHUB_BOT_LOGIN", "fkst-test-bot", 24)

      mock_materialization_source(catalog_root, history)
      mock_env("FKST_GITHUB_WRITE", "", 4)
      local materialized = graph.require_quiescent(graph.run(materialization_event("create"), {
        max_steps = 4,
      }))
      graph.assert_covers(materialized, {
        "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
        "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
      })
      local create = graph.require_raise(materialized, "github-proxy.github_issue_create_request")
      t.eq(create.payload.title, "First child")
      t.is_true(create.payload.body:find("fkst:github-devloop-workflow:lineage:v1", 1, true) ~= nil)
      t.eq(
        create.payload.dedup_key,
        materialization.child_dedup_key(
          origin,
          "first",
          materialization.EMPTY_PREDECESSOR_REF_DIGEST
        )
      )

      -- The fake GitHub boundary applies the confirmed result of the observed proxy delivery.
      history[#history + 1] = trusted_comment(proxy_created_fact(create.payload.dedup_key))
      local child_body = proxy_created_child_body(create)
      mock_materialization_source(catalog_root, history, child_body)
      mock_env("FKST_GITHUB_WRITE", "", 4)
      local ledger_trace = graph.require_quiescent(graph.run(materialization_event("created-ledger"), {
        max_steps = 4,
      }))
      graph.assert_covers(ledger_trace, {
        "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
        "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      })
      local created = graph.require_raise(
        ledger_trace,
        "github-proxy.github_issue_comment_request",
        function(raised)
          return tostring(raised.payload and raised.payload.body or ""):find(
            'state="created"',
            1,
            true
          ) ~= nil
        end
      )
      t.is_true(created.payload.body:find('child_issue="108"', 1, true) ~= nil)
      history[#history + 1] = trusted_comment(created.payload.body)

      local request = core.child_disposition_request.build({
        repo = repo,
        origin = origin,
        blueprint_digest = blueprint_digest,
        slot = "first",
        child_issue = tostring(child_issue),
        disposition = "satisfied",
      })
      local identity = {
        repo = repo,
        origin = origin,
        blueprint_digest = blueprint_digest,
        slot = "first",
        child_issue = tostring(child_issue),
        disposition = "satisfied",
      }
      mock_fresh_issue_reads(history, child_body)
      mock_receipt_commit_and_readback(identity)
      mock_env("FKST_GITHUB_WRITE", "1", 2)
      t.mock_command("gh issue close " .. tostring(child_issue) .. " --repo " .. repo, {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      local disposition_start = #t.command_calls()
      local disposition_trace = graph.require_quiescent(graph.run({
        queue = "github-devloop-workflow.workflow_child_disposition_request",
        payload = request,
        source_ref = {
          kind = request.source_ref.kind,
          reference = request.source_ref.ref,
        },
      }, { max_steps = 2 }))
      graph.assert_covers(disposition_trace, {
        "github-devloop-workflow.workflow_child_disposition_request -> github-devloop-workflow.workflow_child_disposition",
      })

      local disposition_calls = {}
      for index = disposition_start + 1, #t.command_calls() do
        disposition_calls[#disposition_calls + 1] = t.command_calls()[index]
      end
      t.eq(command_count(disposition_calls, "gh api repos/owner/repo/issues/42"), 1, "origin authority read")
      t.eq(command_count(disposition_calls, "gh api repos/owner/repo/issues/108"), 2, "child authority reads")
      t.eq(command_count(disposition_calls, "git commit-tree"), 1, "receipt commit")
      t.eq(command_count(disposition_calls, "git cat-file -p"), 2, "receipt readbacks")
      t.eq(command_count(disposition_calls, "gh issue close 108"), 1, "completed child close")
      t.is_true(command_index(disposition_calls, "git commit-tree")
        < command_index(disposition_calls, "git cat-file -p"))
      t.is_true(command_index(disposition_calls, "git cat-file -p", true)
        < command_index(disposition_calls, "gh issue close 108"))
      local routed_receipt_message = committed_receipt_message(disposition_calls)
      t.eq(routed_receipt_message, receipt_message(identity))

      mock_materialization_source(catalog_root, history)
      mock_visible_receipt_reads(identity, routed_receipt_message, 1)
      mock_env("FKST_GITHUB_WRITE", "", 4)
      local terminal_trace = graph.require_quiescent(graph.run(materialization_event("receipt-done"), {
        max_steps = 4,
      }))
      graph.assert_covers(terminal_trace, {
        "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
        "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      })
      local terminal = graph.require_raise(
        terminal_trace,
        "github-proxy.github_issue_comment_request",
        function(raised)
          return tostring(raised.payload and raised.payload.body or ""):find(
            'state="done"',
            1,
            true
          ) ~= nil
        end
      )
      t.is_true(terminal.payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
    end)
  end,

  test_satisfied_disposition_uses_canonical_fake_forge_ports = function()
    local history, child_body, request, identity = fake_port_fixture()
    assert_fake_port_disposition(history, child_body, request, identity)
  end,
}
