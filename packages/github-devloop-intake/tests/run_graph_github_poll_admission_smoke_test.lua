local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local graph = require("testkit.graph")
local t = fkst.test
local core = require("core")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local entity_list_cache = require("devloop.entity_list_cache")
local author_policy = require("testkit_internal.github_author_policy")
local h = require("tests.devloop_helpers")

local repo = "graph-fixture/admission-poll"
local issue_number = 42

local function source_ref()
  return entity_lib.issue_source_ref(repo, issue_number)
end

local function mock_env()
  for _ = 1, 8 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), { stdout = repo, stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"), { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_POLL_LABEL_PREFIX"', { stdout = "fkst-dev:,fkst-class:", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_REPLAY_BUDGET"', { stdout = "1", stderr = "", exit_code = 0 })
  end
  for _ = 1, 3 do
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_FORK_GRACE_HOURS"), { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function mock_proxy_poll_lists()
  t.mock_command("gh api --paginate --slurp 'repos/graph-fixture/admission-poll/issues?state=open&per_page=100'", {
    stdout = '[[{"number":42,"title":"Fresh unmanaged issue","html_url":"https://github.example/graph-fixture/admission-poll/issues/42","updated_at":"2026-06-03T01:02:03Z","state":"open","labels":[{"name":"bug"}]}]]\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/graph-fixture/admission-poll/pulls?state=open&per_page=100'", {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_empty_delivery_snapshot()
  t.mock_observe({
    truncated = { deliveries = false, dead_letters = false },
    deliveries = json.decode("[]"),
    dead_letters = json.decode("[]"),
  })
end

local function mock_admission_issue_view()
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    title = "Fresh unmanaged issue",
    body = "",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = { "bug" },
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

local function trace_has_raise(trace, queue)
  for _, step in ipairs(trace.steps or {}) do
    for _, raised in ipairs(step.raises or {}) do
      if raised.queue == queue then
        return true
      end
    end
  end
  return false
end

local function mock_transient_peer_replay_env()
  author_policy.mock_env(t, nil, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 12,
  })
  for _ = 1, 12 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), { stdout = repo, stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"), { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_FORK_GRACE_HOURS"), { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), { stdout = "dev", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), { stdout = "integration-fkst-test-bot", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_POLL_LABEL_PREFIX"', { stdout = "fkst-class:", stderr = "", exit_code = 0 })
    t.mock_command('printf %s "$FKST_GITHUB_PROXY_REPLAY_BUDGET"', { stdout = "1", stderr = "", exit_code = 0 })
  end
end

local function mock_labelled_poll_snapshot()
  t.mock_command("gh api --paginate --slurp 'repos/graph-fixture/admission-poll/issues?state=open&per_page=100'", {
    stdout = '[[{"number":42,"title":"Fresh unmanaged issue","html_url":"https://github.example/graph-fixture/admission-poll/issues/42","updated_at":"2026-06-03T01:02:03Z","state":"open","labels":[{"name":"fkst-class:expedite"}],"assignees":[]}]]\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/graph-fixture/admission-poll/pulls?state=open&per_page=100'", {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_other_authored_admission_view()
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    title = "Fresh unmanaged issue",
    body = "",
    created_at = "2026-06-03T01:00:00Z",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = { "fkst-class:expedite" },
    comments = {},
    assignees = {},
    author_login = "trusted-human",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

return {
  test_run_graph_github_poll_reaches_intake_admission_candidate_without_intake_poll = function()
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    mock_env()
    mock_proxy_poll_lists()
    mock_admission_issue_view()
    mock_empty_delivery_snapshot()

    local trace = graph.require_quiescent(graph.run("github-proxy.github_poll", { max_steps = 4 }))
    graph.assert_covers(trace, {
      "github-proxy.github_poll_tick -> github-proxy.github_poll",
      "github-proxy.github_entity_changed -> github-devloop-intake.admission",
    })

    local spec = require("departments.admission.main").spec
    t.eq(spec.consumes[1], "github-proxy.github_entity_changed")
    t.eq(#spec.consumes, 1)
    t.eq(spec.produces[1], "devloop_intake_candidate")

    local replay_spec = require("departments.replay_admission.main").spec
    t.eq(replay_spec.consumes[1], "github-proxy.github_issue_observed")
    t.eq(#replay_spec.consumes, 1)
    t.eq(replay_spec.produces[1], "devloop_intake_candidate")

    local _, admission_index = graph.require_delivery(trace, {
      queue = "github-proxy.github_entity_changed",
      consumer = "github-devloop-intake.admission",
    })
    local raised, _, raised_step_index = graph.require_raise(trace, "github-devloop-intake.devloop_intake_candidate", function(item)
      local payload = item.payload or {}
      return payload.schema == "github-devloop.intake-candidate.v1"
        and payload.repo == repo
        and tostring(payload.issue_number) == tostring(issue_number)
        and payload.source_ref ~= nil
        and payload.source_ref.ref == source_ref().ref
    end)
    t.eq(raised_step_index, admission_index)
    t.eq(raised.payload.proposal_id, base_ids.proposal_id(repo, issue_number))

    for _, step in ipairs(trace.steps or {}) do
      t.is_true(step.consumer ~= "github-devloop-intake.intake_scan")
      t.is_true(step.consumer ~= "github-devloop-intake.intake_probe")
    end
  end,

  test_configured_prefix_issue_replays_after_transient_peer_failure_and_reaches_admission_effect = function()
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    mock_transient_peer_replay_env()
    mock_labelled_poll_snapshot()
    mock_labelled_poll_snapshot()
    mock_other_authored_admission_view()
    mock_other_authored_admission_view()
    mock_empty_delivery_snapshot()
    t.mock_command("gh issue list --repo 'graph-fixture/admission-poll' --state all --limit 100 --json number,comments,author", {
      stdout = "",
      stderr = "transient peer discovery failure",
      exit_code = 1,
    })
    t.mock_command("gh issue list --repo 'graph-fixture/admission-poll' --state all --limit 100 --json number,comments,author", {
      stdout = "[]",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr list --repo 'graph-fixture/admission-poll' --state all --limit 100 --json number,headRefName,baseRefName,comments,author", {
      stdout = "[]",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(core.gh_issue_view_state_cmd(repo, tostring(issue_number)), {
      stdout = '{"title":"Fresh unmanaged issue","createdAt":"2026-06-03T01:00:00Z","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":["fkst-class:expedite"],"comments":[],"assignees":[],"author":{"login":"trusted-human"}}\n',
      stderr = "",
      exit_code = 0,
    })

    local first = graph.run("github-proxy.github_poll", { max_steps = 4 })
    t.eq(trace_has_raise(first, "github-proxy.github_issue_create_request"), false)
    t.eq(trace_has_raise(first, "github-devloop-intake.devloop_intake_candidate"), false)

    local second = graph.run("github-proxy.github_poll", { max_steps = 4 })
    graph.require_raise(second, "github-proxy.github_issue_create_request", function(item)
      return item.payload.external_effect_saga == "fork-and-block"
        and tonumber(item.payload.parent_comment_target.issue_number) == issue_number
    end)
  end,
}
