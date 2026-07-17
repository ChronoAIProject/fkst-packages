local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local devloop_commands = require("devloop.commands")
local entity_lib = require("devloop.entity")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local payloads_builders = require("devloop.payloads.builders")
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local t = h.t
local core = h.core

local repo = "base-skew/repo"
local issue_number = 2400
local pr_number = 2401
local old_base = "281c4f9e"
local new_base = "828df8d3"
local predecessor_set = "none"

local function base_skew_fixture(ci_failure_key)
  local template = h.fixing()
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  local version = tostring(template.version):gsub("owner/repo/42", repo .. "/" .. tostring(issue_number))
  local review_proposal_id = devloop_base.pr_review_proposal_id(repo, pr_number, version, template.reviewed_head_sha)
  local seed = h.fixing({
    proposal_id = proposal_id,
    pr_number = pr_number,
    version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
    source_ref = entity_lib.pr_source_ref(repo, pr_number),
  })
  local lineage = {
    review_proposal_id = seed.review_proposal_id,
    review_dedup_key = seed.review_dedup_key,
    reviewed_head_sha = seed.reviewed_head_sha,
    gate_baseline_sha = old_base,
    predecessor_set = predecessor_set,
    ci_failure_key = ci_failure_key,
    gate_failure_excerpt = "mergeable-conflicting",
  }
  local event = payloads_builders.build_replayed_fixing_payload({
    proposal_id = seed.proposal_id,
    impl_version = seed.version,
  }, seed.pr_number, lineage, seed.source_ref)
  local canonical = {
    body = "github-devloop merge gate failed: mergeable-conflicting\n"
      .. m_builders.merge_gate_marker(
        event.proposal_id,
        event.pr_number,
        event.version,
        event.review_proposal_id,
        event.review_dedup_key,
        event.reviewed_head_sha,
        new_base,
        "mergeable-conflicting",
        event.predecessor_set,
        event.ci_failure_key
      ),
    author_login = "fkst-test-bot",
    created_at = "2026-07-17T01:01:00Z",
  }
  return event, canonical
end

local function branch_for(event)
  return devloop_base.implement_branch(repo, tostring(issue_number), event.version)
end

local function current_pr_comments(event, canonical)
  local branch = branch_for(event)
  local merge_ready_version = core._strip_latest_fix_version_suffix(event.version)
  return {
    m_builders.pr_origin_marker(event.proposal_id, tostring(issue_number), branch, event.version, "dev"),
    core.state_marker(event.proposal_id, "merge-ready", merge_ready_version),
    m_builders.merge_ready_marker(
      event.proposal_id,
      event.pr_number,
      merge_ready_version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha
    ),
    m_builders.review_result_marker(
      event.review_proposal_id,
      event.proposal_id,
      "approve",
      event.review_dedup_key
    ),
    core.state_marker(event.proposal_id, "fixing", event.version),
    canonical,
  }
end

local function mock_runtime_config()
  for _ = 1, 40 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 64 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_old_delivery(event, canonical, times)
  h.mock_default_issue_claim(repo, issue_number)
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = pr_number,
    head = branch_for(event),
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    comments = current_pr_comments(event, canonical),
    state = "OPEN",
  }, entity_read_mocks.pr_fix_selector, times or 1)
end

local function mock_replay_entry(event, canonical)
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = pr_number,
    head = branch_for(event),
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    comments = current_pr_comments(event, canonical),
    labels = { "fkst-dev:fixing" },
    state = "OPEN",
  }, entity_read_mocks.pr_origin_selector)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 4)
end

local function mock_comment_handoff(event, canonical, include_fixing)
  local visible_comments = '[[{"id":1,"body":"'
    .. h.json_string(core.state_marker(event.proposal_id, "fixing", event.version))
    .. '","user":{"login":"fkst-test-bot"}},{"id":2,"body":"'
    .. h.json_string(canonical.body)
    .. '","user":{"login":"fkst-test-bot"}}]]\n'
  for _, command in ipairs({
    "gh api --paginate --slurp repos/" .. repo .. "/issues/" .. pr_number .. "/comments?per_page=100",
    "gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. pr_number .. "/comments?per_page=100'",
  }) do
    for _ = 1, 4 do
      t.mock_command(command, {
        stdout = visible_comments,
        stderr = "",
        exit_code = 0,
      })
    end
  end
  local comment_path = "/tmp/fkst-github-proxy-comment-base-skew_repo-pr-" .. pr_number .. ".md"
  local written_markers = {}
  if include_fixing ~= false then
    table.insert(written_markers, core.state_marker(event.proposal_id, "fixing", event.version))
  end
  table.insert(written_markers, core.state_marker(event.proposal_id, "reviewing", core.next_fix_version(event.version)))
  for index, written in ipairs(written_markers) do
    local comment_id = "2400" .. tostring(index)
    t.mock_command("gh api --method POST repos/" .. repo .. "/issues/" .. pr_number .. "/comments --field 'body=@" .. comment_path .. "'", {
      stdout = '{"id":' .. comment_id .. ',"body":"created","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api --method GET 'repos/" .. repo .. "/issues/comments/" .. comment_id .. "'", {
      stdout = '{"body":"' .. h.json_string(written) .. '","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_label_writes()
  for _ = 1, 3 do
    t.mock_command("gh label list", {
      stdout = '[{"name":"fkst-dev:fixing"},{"name":"fkst-dev:reviewing"}]\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr edit", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("gh issue edit", { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function mock_pr_fix_for_event(event, comments, branch, head_sha, status_check_rollup_json, precheck_times)
  local fields = {
    repo = repo,
    number = pr_number,
    comments = comments,
    head = branch,
    head_sha = head_sha,
    state = "OPEN",
    head_repo = repo,
    status_check_rollup_json = status_check_rollup_json or "[]",
  }
  entity_read_mocks.mock_pr_read_forms(t, fields)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_fix_selector, 2)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_fix_precheck_selector, precheck_times or 1)
end

local function mock_fix_execution(event, canonical, opts)
  opts = opts or {}
  local branch = branch_for(event)
  local origin_marker = m_builders.pr_origin_marker(
    event.proposal_id,
    tostring(issue_number),
    branch,
    event.version,
    "dev"
  )
  local issue_comments = {
    core.state_marker(event.proposal_id, "fixing", event.version),
    canonical,
  }

  h.mock_context_bundle(event)
  t.mock_command("gh pr diff " .. pr_number .. " --repo " .. repo .. " --name-only", {
    stdout = "file.lua\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, issue_comments, branch, event.version, {
    repo = repo,
    number = issue_number,
  })
  local status_check_rollup_json = "[]"
  if event.ci_failure_key ~= nil then
    status_check_rollup_json = '[{"__typename":"CheckRun","completedAt":"2026-07-17T01:02:00Z","conclusion":"FAILURE","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-07-17T01:01:00Z","status":"COMPLETED","workflowName":"test","headSha":"'
      .. event.reviewed_head_sha
      .. '"}]'
    h.mock_required_check_runs_for(event.reviewed_head_sha, "failure", repo)
  end
  mock_pr_fix_for_event(
    event,
    current_pr_comments(event, canonical),
    branch,
    event.reviewed_head_sha,
    status_check_rollup_json,
    opts.precheck_times
  )
  h.mock_existing_fix_worktree(branch, event.reviewed_head_sha, nil, {
    sha = new_base,
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, opts.merge_queue_reads or 1 do
    t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/pulls?state=open&base=dev&per_page=100'", {
      stdout = "[[]]\n",
      stderr = "",
      exit_code = 0,
    })
  end
  h.mock_implement_codex(opts.codex_exit_code or 0, opts.codex_stdout or "rebased base-skewed fix", opts.codex_stderr)
  if opts.codex_exit_code == nil or opts.codex_exit_code == 0 then
    if opts.no_changes then
      h.mock_git_status("")
      t.mock_command("git rev-list --count " .. event.reviewed_head_sha .. "..refs/heads/" .. branch, {
        stdout = "0\n",
        stderr = "",
        exit_code = 0,
      })
    else
      h.mock_git_status(" M packages/github-devloop-pr/core.lua\n")
      h.mock_git_commit("feedface", branch)
    end
  end
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, issue_comments, branch, event.version, {
    repo = repo,
    number = issue_number,
  })
  if opts.no_changes or (opts.codex_exit_code ~= nil and opts.codex_exit_code ~= 0) then
    return
  end
  h.mock_git_push(branch)
  mock_pr_fix_for_event(event, opts.post_push_comments or { origin_marker }, branch, "feedface")
end

local function poll_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      title = "Recover base-skewed fixing delivery",
      updated_at = "2026-07-17T01:03:00Z",
      dedup_key = repo .. "#pr/" .. pr_number .. "@2026-07-17T01:03:00Z",
      source_ref = entity_lib.pr_source_ref(repo, pr_number),
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#pr/" .. pr_number,
    },
  }
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  return output, ok ~= false and ok ~= nil
end

local function write_duplicate_recovery_source(root)
  local directory = root .. "/packages/github-devloop-pr/departments/test_duplicate_fixing"
  local made, made_ok = command_output("mkdir -p " .. shell_quote(directory))
  if not made_ok then
    error("base-skew duplicate fixture could not create department: " .. tostring(made))
  end
  file.write(directory .. "/main.lua", [[
local M = {}

M.spec = {
  consumes = { "test_duplicate_fixing" },
  produces = { "devloop_fixing" },
  stall_window = "2m",
  retry = false,
}

function M.pipeline(event)
  raise("devloop_fixing", event.payload.first)
  raise("devloop_fixing", event.payload.second)
end

return M
]])
end

local function run_duplicate_recovery_fixture()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("base-skew duplicate fixture requires BIN")
  end
  local root_output, made = command_output("mktemp -d " .. shell_quote("/tmp/fkst-base-skew-duplicate.XXXXXX"))
  if not made then
    error("base-skew duplicate fixture could not create a temp root: " .. tostring(root_output))
  end
  local root = root_output:gsub("%s+$", "")
  local ok, err = pcall(function()
    local repo_root = assert(command_output("pwd")):gsub("%s+$", "")
    local setup, setup_ok = command_output(
      "BIN=" .. shell_quote(bin)
        .. " FKST_RUNTIME_ROOT=" .. shell_quote(root)
        .. " bash " .. shell_quote(repo_root .. "/scripts/composed_test_graph_roots.sh")
        .. " graph github-devloop-pr"
    )
    if not setup_ok then
      error("base-skew duplicate fixture root setup failed: " .. tostring(setup))
    end
    local composed_root = setup:match("test_project_root='([^']+)'")
    if composed_root == nil then
      error("base-skew duplicate fixture root setup returned no project root: " .. tostring(setup))
    end
    write_duplicate_recovery_source(composed_root)
    local command = table.concat({
      "BIN=" .. shell_quote(bin),
      "FKST_BASE_SKEW_DUPLICATE_NESTED=1",
      "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
      "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
      shell_quote(bin),
      "test",
      "--project-root", shell_quote(composed_root),
      "--package-root", shell_quote(composed_root .. "/packages/github-devloop-pr"),
      "--package-root", shell_quote(composed_root .. "/packages/github-proxy"),
      "--package-root", shell_quote(composed_root .. "/packages/consensus"),
      "--package-root", shell_quote(composed_root .. "/packages/github-devloop-decompose"),
    }, " ")
    local output, passed = command_output(command)
    if not passed then
      error("base-skew duplicate nested test failed:\n" .. tostring(output))
    end
    for _, name in ipairs({
      "test_no_change_ci_base_recovery_replay_performs_zero_second_execution",
      "test_codex_failure_ci_base_recovery_replay_performs_zero_second_execution",
    }) do
      t.is_true(output:find(
        "PASS tests/run_graph_base_skew_fix_recovery_test.lua::" .. name,
        1,
        true
      ) ~= nil, output)
    end
  end)
  command_output("rm -rf " .. shell_quote(root))
  if not ok then
    error(err)
  end
end

local function assert_ci_recovery_duplicate_executes_once(outcome)
  local ci_failure_key = "head:def456/checks:digest-0000000101"
  local event, canonical = base_skew_fixture(ci_failure_key)
  local recovery = payloads_builders.build_replayed_fixing_payload({
    proposal_id = event.proposal_id,
    impl_version = event.version,
  }, event.pr_number, {
    review_proposal_id = event.review_proposal_id,
    review_dedup_key = event.review_dedup_key,
    reviewed_head_sha = event.reviewed_head_sha,
    gate_baseline_sha = new_base,
    predecessor_set = event.predecessor_set,
    ci_failure_key = ci_failure_key,
    gate_failure_excerpt = "mergeable-conflicting",
  }, event.source_ref)
  t.eq(recovery.work_unit_key, event.work_unit_key)
  t.eq(recovery.dedup_key, event.dedup_key)

  mock_runtime_config()
  h.mock_default_issue_claim(repo, issue_number)
  mock_fix_execution(event, canonical, outcome)
  mock_comment_handoff(event, canonical, false)
  local trace = graph.run({
    queue = "github-devloop-pr.test_duplicate_fixing",
    payload = {
      schema = "github-devloop-pr.test-duplicate-fixing.v1",
      first = event,
      second = recovery,
      dedup_key = "test-duplicate-fixing/" .. event.work_unit_key,
      source_ref = event.source_ref,
    },
    source_ref = {
      kind = event.source_ref.kind,
      reference = event.source_ref.ref,
    },
  }, { max_steps = 12 })

  t.eq(trace.status, "quiescent")
  t.eq(trace.final.dead_letters, 0)
  t.eq(trace.final.pending, 0)
  t.eq(trace.final.deliveries, 0)
  local fix_deliveries = 0
  for _, step in ipairs(trace.steps or {}) do
    if step.queue == "github-devloop-pr.devloop_fixing"
      and step.consumer == "github-devloop-pr.fix" then
      fix_deliveries = fix_deliveries + 1
    end
  end
  t.eq(fix_deliveries, 1)
  -- One admitted fix reads the runtime root for its worktree and context bundle.
  t.eq(h.count_calls('printf %s "$FKST_RUNTIME_ROOT"'), 2)
  t.eq(h.count_calls("git worktree list --porcelain"), 1)
  t.eq(h.count_calls("merge --no-edit '" .. new_base .. "'"), 1)
  t.eq(h.count_calls("merge --no-edit '" .. old_base .. "'"), 0)
  t.eq(h.count_calls("codex exec"), 1)
end

local tests = {
  test_base_skewed_fix_delivery_recovers_via_canonical_observe_pr_replay = function()
    local old_event, canonical = base_skew_fixture()
    local _, canonical_matches, event_fact_visible = m_facts.merge_gate_fix_fact(
      { canonical },
      old_event.proposal_id,
      old_event.version,
      {
        review_proposal_id = old_event.review_proposal_id,
        review_dedup_key = old_event.review_dedup_key,
        reviewed_head_sha = old_event.reviewed_head_sha,
        gate_baseline_sha = old_event.gate_baseline_sha,
        match_gate_baseline_sha = true,
        predecessor_set = old_event.predecessor_set,
        match_predecessor_set = true,
        ci_failure_key = old_event.ci_failure_key,
        match_ci_failure_key = true,
      }
    )
    t.eq(canonical_matches, false)
    t.eq(event_fact_visible, false)
    t.eq(old_event.repair_input, "review-feedback")
    t.eq(old_event.ci_failure_key, nil)
    t.is_true(old_event.dedup_key:find(
      "/" .. old_base .. "/" .. predecessor_set .. "/noci/" .. old_event.reviewed_head_sha,
      1,
      true
    ) ~= nil)
    t.is_true(canonical.body:find(new_base, 1, true) ~= nil)
    t.is_true(canonical.body:find(old_base, 1, true) == nil)

    mock_runtime_config()
    mock_old_delivery(old_event, canonical)
    local stale = graph.run({
      queue = "github-devloop-pr.devloop_fixing",
      payload = old_event,
      source_ref = {
        kind = old_event.source_ref.kind,
        reference = old_event.source_ref.ref,
      },
    }, { max_steps = 2 })
    t.eq(stale.status, "quiescent")
    t.eq(stale.final.dead_letters, 0)
    t.eq(stale.final.pending, 0)
    t.eq(stale.final.deliveries, 0)
    graph.assert_covers(stale, {
      "github-devloop-pr.devloop_fixing -> github-devloop-pr.fix",
    })
    t.eq(stale.steps[1].status, "accepted", tostring(stale.steps[1].error))
    t.eq(stale.steps[1].exit_code, 0)
    t.eq(h.count_calls("codex exec"), 0)

    mock_replay_entry(old_event, canonical)
    mock_comment_handoff(old_event, canonical)
    mock_label_writes()
    mock_fix_execution(old_event, canonical)
    local recovered = graph.run(poll_event(), { max_steps = 24 })
    t.eq(recovered.status, "quiescent")
    t.eq(recovered.final.dead_letters, 0)
    t.eq(recovered.final.pending, 0)
    t.eq(recovered.final.deliveries, 0)
    t.is_true(#recovered.steps <= 24)
    graph.assert_covers(recovered, {
      "github-proxy.github_entity_changed -> github-devloop-pr.observe_pr",
      "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
      "github-proxy.github_comment_written -> github-devloop-pr.comment_handoff",
      "github-devloop-pr.devloop_fixing -> github-devloop-pr.fix",
    })
    for _, step in ipairs(recovered.steps or {}) do
      t.is_true(step.status ~= "error", tostring(step.error))
    end

    local replayed = graph.require_raise(recovered, "github-devloop-pr.devloop_fixing", function(raised)
      return raised.payload.gate_baseline_sha == new_base
    end)
    t.eq(replayed.payload.gate_baseline_sha, new_base)
    t.eq(replayed.payload.review_proposal_id, old_event.review_proposal_id)
    t.eq(replayed.payload.review_dedup_key, old_event.review_dedup_key)
    t.eq(replayed.payload.reviewed_head_sha, old_event.reviewed_head_sha)
    t.eq(replayed.payload.predecessor_set, old_event.predecessor_set)
    t.eq(replayed.payload.ci_failure_key, nil)
    t.eq(replayed.payload.work_unit_key, old_event.work_unit_key)
    t.eq(replayed.payload.version, old_event.version)
    t.is_true(replayed.payload.dedup_key ~= old_event.dedup_key)
    t.is_true(replayed.payload.dedup_key:find(
      "/" .. new_base .. "/" .. predecessor_set .. "/noci/" .. old_event.reviewed_head_sha,
      1,
      true
    ) ~= nil)
    t.eq(h.count_calls("merge --no-edit '" .. new_base .. "'"), 1)
    t.eq(h.count_calls("merge --no-edit '" .. old_base .. "'"), 0)
    t.eq(h.count_calls("codex exec"), 1)
    local reviewing = graph.require_raise(recovered, "github-proxy.github_pr_comment_request", function(raised)
      return raised.payload.handoff ~= nil
        and raised.payload.handoff.kind == "github-devloop.reviewing"
    end)
    t.eq(reviewing.payload.handoff.version, core.next_fix_version(old_event.version))
  end,

  test_ci_failure_base_skew_runs_rebase_instead_of_yielding = function()
    local ci_failure_key = "head:def456/checks:digest-0000000101"
    local old_event, canonical = base_skew_fixture(ci_failure_key)
    local _, canonical_matches, event_fact_visible = m_facts.merge_gate_fix_fact(
      { canonical },
      old_event.proposal_id,
      old_event.version,
      {
        review_proposal_id = old_event.review_proposal_id,
        review_dedup_key = old_event.review_dedup_key,
        reviewed_head_sha = old_event.reviewed_head_sha,
        gate_baseline_sha = old_event.gate_baseline_sha,
        match_gate_baseline_sha = true,
        predecessor_set = old_event.predecessor_set,
        match_predecessor_set = true,
        ci_failure_key = old_event.ci_failure_key,
        match_ci_failure_key = true,
      }
    )
    t.eq(canonical_matches, false)
    t.eq(event_fact_visible, false)
    t.eq(old_event.repair_input, "ci-failure")

    mock_runtime_config()
    h.mock_default_issue_claim(repo, issue_number)
    mock_replay_entry(old_event, canonical)
    mock_comment_handoff(old_event, canonical, false)
    mock_label_writes()
    mock_fix_execution(old_event, canonical)
    local recovered = graph.run({
      queue = "github-devloop-pr.devloop_fixing",
      payload = old_event,
      source_ref = {
        kind = old_event.source_ref.kind,
        reference = old_event.source_ref.ref,
      },
    }, { max_steps = 24 })
    t.eq(recovered.status, "quiescent")
    t.eq(recovered.final.dead_letters, 0)
    for _, step in ipairs(recovered.steps or {}) do
      t.is_true(step.status ~= "error", tostring(step.error))
    end
    t.eq(recovered.final.pending, 0)
    t.eq(recovered.final.deliveries, 0)
    graph.assert_covers(recovered, {
      "github-devloop-pr.devloop_fixing -> github-devloop-pr.fix",
      "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
      "github-proxy.github_comment_written -> github-devloop-pr.comment_handoff",
    })
    t.eq(h.count_calls("merge --no-edit '" .. new_base .. "'"), 1)
    t.eq(h.count_calls("merge --no-edit '" .. old_base .. "'"), 0)
    t.eq(h.count_calls("codex exec"), 1)
    local reviewing = graph.require_raise(recovered, "github-proxy.github_pr_comment_request", function(raised)
      return raised.payload.handoff ~= nil
        and raised.payload.handoff.kind == "github-devloop.reviewing"
    end)
    t.eq(reviewing.payload.handoff.version, core.next_fix_version(old_event.version))
    t.is_true(reviewing.payload.body:find("feedface", 1, true) ~= nil)
  end,

  test_no_change_ci_base_recovery_replay_performs_zero_second_execution = function()
    assert_ci_recovery_duplicate_executes_once({
      no_changes = true,
      codex_stdout = "No viable fix.",
    })
  end,

  test_codex_failure_ci_base_recovery_replay_performs_zero_second_execution = function()
    assert_ci_recovery_duplicate_executes_once({
      codex_exit_code = 1,
      codex_stdout = "",
      codex_stderr = "codex failed",
    })
  end,
}

local no_change_test = "test_no_change_ci_base_recovery_replay_performs_zero_second_execution"
local codex_failure_test = "test_codex_failure_ci_base_recovery_replay_performs_zero_second_execution"
if os.getenv("FKST_BASE_SKEW_DUPLICATE_NESTED") == "1" then
  return {
    [no_change_test] = tests[no_change_test],
    [codex_failure_test] = tests[codex_failure_test],
  }
end

tests[no_change_test] = nil
tests[codex_failure_test] = nil
tests.test_ci_base_recovery_duplicate_outcomes_execute_once = run_duplicate_recovery_fixture

return tests
