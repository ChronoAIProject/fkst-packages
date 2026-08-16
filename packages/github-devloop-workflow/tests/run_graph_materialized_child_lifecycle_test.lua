local devloop_base = require("devloop.base")
local t = fkst.test
local core = require("core")
local graph = require("testkit.graph")
local gh_argv = require("testkit_internal.gh_argv_mock")
local github_commands = require("forge.github").new(function() end)
local projected_state_comment = require("testkit_internal.projected_state_fixture").bind(require("devloop.state"))
local context_fixtures = require("testkit_internal.devloop_helpers_fixtures")
local codex_jsonl = require("testkit_internal.codex_jsonl")
local fixtures = require("tests.run_graph_materialization_helpers")
gh_argv.install(t, core)

local implement_fixtures = require("testkit_internal.devloop_worktree_fixtures").new({
  devloop_base = devloop_base,
  base_ids = fixtures.base_ids,
  base = { t = t, core = core },
})

local base_ids = fixtures.base_ids
local repo = fixtures.repo
local origin_issue = fixtures.origin_issue
local revived_child_issue = fixtures.revived_child_issue
local revived_pr = fixtures.revived_pr
local child_version = fixtures.child_version
local head_sha = fixtures.head_sha
local integration_branch = fixtures.integration_branch
local revived_branch = fixtures.revived_branch
local merge_commit_sha = "1111111111111111111111111111111111111111"
local rollup_head_sha = "2222222222222222222222222222222222222222"
local rollup_pr = 2140
local upstream_branch = "dev"

local workflow_history = fixtures.workflow_history
local blocked_by_json = fixtures.blocked_by_json
local rest_comments_json = fixtures.rest_comments_json
local issue_json = fixtures.issue_json
local json_escape = fixtures.json_escape
local revived_child_body = fixtures.revived_child_body
local pr_origin_body = fixtures.pr_origin_body
local mock_materialization_cycle = fixtures.mock_materialization_cycle
local mock_env = fixtures.mock_env
local mock_write_mode = fixtures.mock_write_mode

local function mock_child_issue_reads(issue_number, title, body, labels, comments)
  local stdout = issue_json(issue_number, title, labels, comments, "OPEN", body)
  for _ = 1, 8 do
    for _, command in ipairs({
      core.gh_issue_view_state_cmd(repo, issue_number),
      core.gh_issue_view_intake_judge_cmd(repo, issue_number),
      core.gh_issue_view_implement_cmd(repo, issue_number),
      core.gh_issue_view_claim_cmd(repo, issue_number),
      core.gh_issue_view_commit_subject_cmd(repo, issue_number),
      "gh issue view " .. tostring(issue_number) .. " --repo " .. repo
        .. " --json 'title,body,updatedAt,labels,comments,state,author'",
    }) do
      t.mock_command(command, { stdout = stdout, stderr = "", exit_code = 0 })
    end
  end

  local path = "repos/" .. repo .. "/issues/" .. tostring(issue_number)
  local rest = string.format(
    '{"number":%d,"title":"%s","body":"%s","state":"open","created_at":"2026-07-10T20:00:00Z","updated_at":"2026-07-12T00:25:03Z","labels":[{"name":"fkst-dev:enabled"},{"name":"fkst-dev:ready"}],"user":{"login":"fkst-test-bot"},"assignees":[{"login":"fkst-test-bot"}]}\n',
    issue_number,
    json_escape(title),
    json_escape(body)
  )
  for _ = 1, 12 do
    t.mock_command("gh api '" .. path .. "' --jq '.updated_at'", {
      stdout = "2026-07-12T00:25:03Z\n", stderr = "", exit_code = 0,
    })
    t.mock_command("gh api '" .. path .. "' --jq '.updated_at // .updatedAt // \"\"'", {
      stdout = "2026-07-12T00:25:03Z\n", stderr = "", exit_code = 0,
    })
    t.mock_command("gh api '" .. path .. "'", { stdout = rest, stderr = "", exit_code = 0 })
    t.mock_command("gh api --paginate --slurp '" .. path .. "/comments?per_page=100'", {
      stdout = rest_comments_json(comments), stderr = "", exit_code = 0,
    })
  end
end

local function mock_child_implementation_context(proposal_id, version)
  local runtime = "/tmp/fkst-packages-test/github-devloop-workflow/materialized-child"
  context_fixtures.materialize_context_bundle({ proposal_id = proposal_id, dedup_key = version }, runtime,
    runtime .. "/context/.bundle-tmp.mocked")
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = runtime, stderr = "", exit_code = 0,
    })
  end
  for _, name in ipairs({
    "FKST_DEVLOOP_UPSTREAM_BRANCH",
    "FKST_DEVLOOP_INTEGRATION_BRANCH",
    "FKST_DEVLOOP_MAX_INFLIGHT",
    "FKST_DEVLOOP_MANAGED_SIBLING_REPOS",
  }) do
    for _ = 1, 8 do
      t.mock_command('printf %s "$' .. name .. '"', {
        stdout = name == "FKST_DEVLOOP_UPSTREAM_BRANCH" and "dev" or "",
        stderr = "",
        exit_code = 0,
      })
    end
  end
  for _ = 1, 3 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("test -e", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", {
    stdout = runtime .. "/context/.bundle-tmp.mocked\n", stderr = "", exit_code = 0,
  })
  for _ = 1, 12 do
    t.mock_command("touch ", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("printf %s '", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(" > ", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("test -r", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  for _ = 1, 3 do
    t.mock_command("python3 -c", { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function pr_rest_json()
  return string.format(
    '{"number":%d,"state":"closed","updated_at":"2026-07-12T00:25:02Z","merged_at":"2026-07-12T00:25:02Z","merge_commit_sha":"%s","draft":false,"labels":[],"user":{"login":"fkst-test-bot"},"mergeable":true,"mergeable_state":"clean","head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s","owner":{"login":"owner"}}},"base":{"ref":"%s","sha":"abc123","repo":{"full_name":"%s","owner":{"login":"owner"}}}}\n',
    revived_pr,
    merge_commit_sha,
    revived_branch,
    head_sha,
    repo,
    integration_branch,
    repo
  )
end

local function issue_rest_json()
  return string.format(
    '{"number":%d,"title":"Workflow child","body":"fixture","state":"open","created_at":"2026-07-10T20:00:00Z","updated_at":"2026-07-12T00:25:02Z","labels":[{"name":"fkst-dev:enabled"},{"name":"fkst-dev:blocked"}],"user":{"login":"fkst-test-bot"},"assignees":[{"login":"fkst-test-bot"}]}\n',
    revived_child_issue
  )
end

local function mock_child_materialization(created_issue, child_dedup)
  for _ = 1, 3 do
    t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("codex exec", {
    stdout = codex_jsonl.final_message(
      '{"title":"Workflow child","body":"Materialized workflow child fixture."}'),
    stderr = "",
    exit_code = 0,
  })
  if created_issue == nil then return end
  local comments_cmd = "gh api --paginate --slurp 'repos/" .. repo .. "/issues/"
    .. tostring(origin_issue) .. "/comments?per_page=100'"
  t.mock_command(comments_cmd, { stdout = rest_comments_json({}), stderr = "", exit_code = 0 })
  t.mock_command(comments_cmd, {
    stdout = rest_comments_json({ { body = '<!-- fkst:github-proxy:issue-create-intent:v1 dedup="'
      .. tostring(child_dedup) .. '" -->' } }), stderr = "", exit_code = 0,
  })
  for _, kind in ipairs({ "intent", "created" }) do
    t.mock_command("gh issue comment " .. tostring(origin_issue) .. " --repo " .. repo
      .. " --body-file /tmp/fkst-github-proxy-" .. kind .. "-", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command("gh issue create", {
    stdout = "https://github.example/" .. repo .. "/issues/" .. tostring(created_issue) .. "\n", stderr = "", exit_code = 0,
  })
  t.mock_command("gh api 'repos/" .. repo .. "/issues/" .. tostring(created_issue) .. "'", {
    stdout = '{"id":987654321,"number":' .. tostring(created_issue) .. '}\n', stderr = "", exit_code = 0,
  })
  t.mock_command("gh api --method POST repos/" .. repo .. "/issues/" .. tostring(origin_issue)
    .. "/sub_issues -F sub_issue_id=987654321", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_native_merge_observation(parent_merged_projection)
  local projection_pending = parent_merged_projection == nil
  mock_write_mode("1", projection_pending and 5 or 3)
  for _ = 1, (projection_pending and 3 or 2) do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot", stderr = "", exit_code = 0,
    })
  end
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
    stdout = upstream_branch, stderr = "", exit_code = 0,
  })
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
    stdout = integration_branch, stderr = "", exit_code = 0,
  })
  t.mock_command("gh api 'repos/" .. repo .. "/pulls/" .. tostring(revived_pr) .. "'", {
    stdout = pr_rest_json(), stderr = "", exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(revived_pr) .. "/comments?per_page=100'", {
    stdout = rest_comments_json({ { body = pr_origin_body() } }), stderr = "", exit_code = 0,
  })
  local parent_comments = { { body = revived_child_body() } }
  if parent_merged_projection ~= nil then
    table.insert(parent_comments, {
      body = parent_merged_projection,
      created_at = "2026-07-12T00:26:02Z",
    })
  end
  for _ = 1, (projection_pending and 2 or 1) do
    t.mock_command("gh api 'repos/" .. repo .. "/issues/" .. tostring(revived_child_issue) .. "'", {
      stdout = issue_rest_json(), stderr = "", exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(revived_child_issue) .. "/comments?per_page=100'", {
      stdout = rest_comments_json(parent_comments),
      stderr = "",
      exit_code = 0,
    })
  end
  if projection_pending then
    t.mock_command("gh api --method POST repos/" .. repo .. "/issues/" .. tostring(revived_child_issue)
      .. "/comments --field 'body=", {
        stdout = '{"id":123456,"body":"created","user":{"login":"fkst-test-bot"}}\n',
        stderr = "",
        exit_code = 0,
      })
  end
  t.mock_command(github_commands.pr_list_promotions_cmd(repo, integration_branch, upstream_branch), {
    stdout = '[[{"number":' .. tostring(rollup_pr)
      .. ',"state":"closed","merged_at":"2026-07-12T00:24:02Z"'
      .. ',"head":{"ref":"' .. integration_branch .. '","sha":"' .. rollup_head_sha
      .. '","repo":{"full_name":"' .. repo .. '"}},"base":{"ref":"' .. upstream_branch .. '"}}]]\n',
    stderr = "", exit_code = 0,
  })
  t.mock_command("git fetch --no-write-fetch-head origin '+refs/pull/" .. tostring(rollup_pr)
    .. "/head:refs/fkst/pr/" .. tostring(rollup_pr) .. "'", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command(core.git_rev_parse_ref_commit_cmd("refs/fkst/pr/" .. tostring(rollup_pr)),
    { stdout = rollup_head_sha .. "\n", stderr = "", exit_code = 0 })
  t.mock_command("git merge-base --is-ancestor " .. merge_commit_sha .. " " .. rollup_head_sha, {
    stdout = "", stderr = "", exit_code = 0,
  })
  if not projection_pending then
    t.mock_command(core.gh_issue_close_cmd(repo, revived_child_issue, { kind = "completed" }), {
      stdout = "closed\n", stderr = "", exit_code = 0,
    })
  end
end

local function native_pr_merged_event(updated_at)
  local observed_at = updated_at or "2026-07-12T00:25:02Z"
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = revived_pr,
      state = "MERGED",
      updated_at = observed_at,
      dedup_key = repo .. "#pr#" .. tostring(revived_pr) .. "@" .. observed_at,
      source_ref = { kind = "external", ref = repo .. "#pr/" .. tostring(revived_pr) },
    },
    source_ref = { kind = "external", reference = repo .. "#pr/" .. tostring(revived_pr) },
  }
end

return {
  test_run_graph_rederives_revived_merged_child_after_child_fatal = function()
    mock_env()
    mock_write_mode("", 4)
    mock_child_materialization()
    mock_materialization_cycle(workflow_history(false), nil, nil, false)

    local materialized_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/materialize" },
    }, { max_steps = 4 }))
    graph.assert_covers(materialized_trace, {
      "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
      "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
    })
    local create = graph.require_raise(materialized_trace, "github-proxy.github_issue_create_request")
    t.eq(create.payload.title, "Workflow child")
    t.is_true(create.payload.body:find("Materialized workflow child fixture.", 1, true) ~= nil)

    mock_write_mode("", 4)
    mock_materialization_cycle(workflow_history(true), "OPEN", "OPEN", false)

    local fatal_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/fatal" },
    }, { max_steps = 4 }))
    local fatal = graph.find_raise(fatal_trace, "github-proxy.github_issue_comment_request")
    if fatal == nil then
      local calls = {}
      for index, call in ipairs(t.command_calls()) do
        calls[index] = tostring(call.rendered or call.command or call.cmd or call)
      end
      local step = fatal_trace.steps and fatal_trace.steps[1] or {}
      error("fatal replay produced no terminal comment; stdout=" .. tostring(step.stdout)
        .. " stderr=" .. tostring(step.stderr)
        .. " commands=" .. table.concat(calls, " | "))
    end
    t.is_true(fatal.payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(fatal.payload.body:find('reason_code="child-fatal-behavior-preserving-restructure"', 1, true) ~= nil)

    mock_native_merge_observation()
    local projection_trace = graph.require_quiescent(graph.run(native_pr_merged_event(), { max_steps = 8 }))
    graph.assert_covers(projection_trace, {
      "github-proxy.github_entity_changed -> github-devloop.observe_issue",
    })
    local projection = graph.require_raise(projection_trace, "github-proxy.github_issue_comment_request")
    t.is_true(projection.payload.body:find("fkst:github-devloop:merged:v1", 1, true) ~= nil)
    t.eq(projection.payload.body:find('state="merged"', 1, true), nil)
    local close_calls = 0
    for _, call in ipairs(t.command_calls()) do
      if gh_argv.call_contains(call, "gh issue close " .. tostring(revived_child_issue))
        and gh_argv.call_contains(call, "--repo " .. repo) then
        close_calls = close_calls + 1
      end
    end
    t.eq(close_calls, 0)

    mock_native_merge_observation(projection.payload.body)
    local merged_trace = graph.require_quiescent(graph.run(
      native_pr_merged_event("2026-07-12T00:26:02Z"),
      { max_steps = 4 }
    ))
    graph.assert_covers(merged_trace, {
      "github-proxy.github_entity_changed -> github-devloop.observe_issue",
    })
    t.eq(graph.find_raise(merged_trace, "github-proxy.github_issue_comment_request"), nil)
    close_calls = 0
    for _, call in ipairs(t.command_calls()) do
      if gh_argv.call_contains(call, "gh issue close " .. tostring(revived_child_issue))
        and gh_argv.call_contains(call, "--repo " .. repo) then
        close_calls = close_calls + 1
      end
    end
    t.eq(close_calls, 1)

    mock_env()
    mock_write_mode("", 6)
    mock_materialization_cycle(workflow_history(true, fatal.payload.body), "CLOSED", "MERGED", true)
    local recovered_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/recovered" },
    }, { max_steps = 4 }))
    graph.assert_covers(recovered_trace, {
      "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
    })
    local done = graph.require_raise(recovered_trace, "github-proxy.github_issue_comment_request")
    t.is_true(done.payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(done.payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
  end,

  test_run_graph_origin_dependency_holds_then_releases_materialization = function()
    mock_env()
    mock_write_mode("", 4)
    local release_history, released_child_dedup = workflow_history(false)
    mock_child_materialization(revived_child_issue, released_child_dedup)
    mock_materialization_cycle(release_history, nil, nil, false, nil, "OPEN")

    local held = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/dependency-held" },
    }, { max_steps = 4 }))
    t.eq(graph.find_raise(held, "github-proxy.github_issue_create_request"), nil)

    mock_env()
    mock_write_mode("1", 4)
    mock_materialization_cycle(release_history, nil, nil, false, nil, "CLOSED")
    local released = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/dependency-released" },
    }, { max_steps = 4 }))
    graph.assert_covers(released, {
      "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
      "github-proxy.github_issue_create_request -> github-proxy.github_issue_create",
    })
    local create = graph.require_raise(released, "github-proxy.github_issue_create_request")
    t.eq(create.payload.parent, origin_issue)

    local created_marker_path = nil
    for _, call in ipairs(t.command_calls()) do
      local rendered = gh_argv.call_rendered(call)
      if rendered:find("fkst-github-proxy-created-", 1, true) ~= nil then
        created_marker_path = rendered:match("%-%-body%-file%s+(%S+)")
      end
    end
    t.is_true(created_marker_path ~= nil)
    local marker_dedup, child_issue = file.read(created_marker_path)
      :match('issue%-created:v1 dedup="([^"]+)" issue="(%d+)"')
    t.eq(marker_dedup, create.payload.dedup_key)
    local created_child_issue = tonumber(child_issue)
    t.is_true(created_child_issue ~= nil)
    local created_child = base_ids.proposal_id(repo, created_child_issue)

    local ready_version = "consensus:" .. created_child .. "/materialized"
    local ready_comment = {
      id = "IC_materialized_child_ready",
      body = projected_state_comment(
        created_child,
        "ready",
        ready_version,
        "result-marker,ready-label,devloop-ready"
      ),
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
    }
    local child_labels = { "fkst-dev:enabled", "fkst-dev:ready" }
    mock_env()
    mock_write_mode("", 18)
    mock_child_issue_reads(
      created_child_issue,
      create.payload.title,
      create.payload.body,
      child_labels,
      { ready_comment }
    )
    local implementation_version = base_ids.dedup_key({
      "ready",
      ready_version .. "/redrive/ready/1",
    })
    mock_child_implementation_context(created_child, implementation_version)
    for _ = 1, 3 do
      t.mock_command(core.gh_blocked_by_cmd(repo, created_child_issue), {
        stdout = blocked_by_json({}), stderr = "", exit_code = 0,
      })
    end
    implement_fixtures.mock_fresh_implement_worktree({
      durable_root = "/tmp/fkst-packages-test/github-devloop-workflow/materialized-child-durable",
      repo = repo,
      issue_number = created_child_issue,
      impl_version = implementation_version,
    })
    t.mock_command("git show abc123:.fkst/substrate-ref", {
      stdout = "",
      stderr = "fatal: path '.fkst/substrate-ref' does not exist in 'abc123'\n",
      exit_code = 128,
    })
    implement_fixtures.mock_implement_codex(0, "implemented")
    implement_fixtures.mock_git_status(
      " M packages/github-devloop-workflow/materialize_reconcile.lua\n"
    )
    implement_fixtures.mock_git_commit(
      "def456",
      devloop_base.implement_branch(repo, created_child_issue, implementation_version)
    )

    local child_ref = repo .. "#issue/" .. tostring(created_child_issue)
    local cascaded = graph.require_quiescent(graph.run({
      queue = "github-proxy.github_entity_changed",
      payload = {
        schema = "github-proxy.v1",
        type = "issue",
        repo = repo,
        number = created_child_issue,
        title = create.payload.title,
        state = "OPEN",
        updated_at = "2026-07-12T00:25:03Z",
        dedup_key = repo .. "#issue#" .. tostring(created_child_issue) .. "@2026-07-12T00:25:03Z",
        source_ref = { kind = "external", ref = child_ref },
      },
      source_ref = { kind = "external", reference = child_ref },
    }, { max_steps = 12 }))
    graph.assert_covers(cascaded, {
      "github-proxy.github_entity_changed -> github-devloop.observe_issue",
      "github-devloop.devloop_ready -> github-devloop.implement",
    })
    local implementing = graph.find_raise(
      cascaded,
      "github-proxy.github_issue_label_request",
      function(raised)
        return tonumber(raised.payload.issue_number) == created_child_issue
          and raised.payload.add_labels ~= nil
          and raised.payload.add_labels[1] == "fkst-dev:implementing"
      end
    )
    t.is_true(implementing ~= nil)
    t.eq(tonumber(implementing.payload.issue_number), created_child_issue)
    t.eq(implementing.payload.add_labels[1], "fkst-dev:implementing")
  end,
}
