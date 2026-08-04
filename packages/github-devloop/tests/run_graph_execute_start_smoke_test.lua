local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local execution_start = require("devloop.execution_start")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local consensus_core = require("consensus.core")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local request_dedup_key = "intake/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/run-graph-execute-start"
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"

local function command_call_count(command)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if call.rendered == command then
      count = count + 1
    end
  end
  return count
end

local env_command_contract = {
  {
    command = devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"),
    count = 8,
    result = { stdout = "fkst-test-bot", stderr = "", exit_code = 0 },
  },
  {
    command = devloop_base.read_env_command("FKST_GITHUB_WRITE"),
    count = 13,
    result = { stdout = "", stderr = "", exit_code = 0 },
  },
  {
    command = devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"),
    count = 6,
    result = { stdout = "", stderr = "", exit_code = 0 },
  },
  {
    command = 'printf %s "$FKST_RUNTIME_ROOT"',
    count = 2,
    result = {
      stdout = "/tmp/fkst-packages-test/github-devloop-run-graph-execute-start/runtime",
      stderr = "",
      exit_code = 0,
    },
  },
}

local function assert_env_command_contract()
  for _, expectation in ipairs(env_command_contract) do
    local actual = command_call_count(expectation.command)
    if actual ~= expectation.count then
      error(
        "external command call count mismatch command="
          .. expectation.command
          .. " expected="
          .. tostring(expectation.count)
          .. " actual="
          .. tostring(actual),
        2
      )
    end
  end
end

local function source_ref()
  return {
    kind = "external",
    ref = repo .. "#issue/" .. tostring(issue_number),
  }
end

local function execution_request(dedup_key)
  return execution_start.build_execution_request_payload({
    proposal_id = proposal_id,
    dedup_key = dedup_key or request_dedup_key,
    source_ref = source_ref(),
    origin = {
      package = "github-devloop-intake",
      route = "intake_judge",
      decision = "enable",
    },
    service_class = "expedite",
  })
end

local function initial_event(dedup_key)
  return {
    queue = "devloop_execute_request",
    payload = execution_request(dedup_key),
    source_ref = {
      kind = "external",
      reference = repo .. "#issue/" .. tostring(issue_number),
    },
  }
end

local function mock_env()
  for _, expectation in ipairs(env_command_contract) do
    for _ = 1, expectation.count do
      t.mock_command(expectation.command, expectation.result)
    end
  end
end

local function mock_execute_start_issue()
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    title = "Add retry backoff to failed widget sync",
    body = "Implement exponential backoff for widget sync retries.",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone", 1)
end

local function mock_consensus_result_issue(dedup_key)
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:thinking" },
    { core.state_marker(proposal_id, "thinking", dedup_key or request_dedup_key) },
    {
      repo = repo,
      number = issue_number,
      title = "Add retry backoff to failed widget sync",
      body = "Implement exponential backoff for widget sync retries.",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
      times = 1,
    }
  )
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_consensus_approval(opts)
  opts = opts or {}
  for _ = 1, #consensus_core.angles({}) do
    if not opts.omit_checkout_probe_mock then
      t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("codex exec", {
      stdout = verdict_label .. " approve\n" .. reply_label .. " execute start approves.\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function run_execute_start_graph(opts)
  opts = opts or {}
  local dedup_key = opts.request_dedup_key or request_dedup_key
  local request = execution_request(dedup_key)
  mock_env()
  mock_execute_start_issue()
  mock_consensus_result_issue(dedup_key)
  mock_consensus_approval(opts)
  h.mock_context_bundle(request, {
    strict_context_path_probe_mocks = opts.omit_checkout_probe_mock,
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop-run-graph-execute-start/runtime",
    },
  })
  return graph.run(initial_event(dedup_key), { max_steps = 8 })
end

return {
  test_run_graph_execution_request_handoffs_to_execute_start = function()
    local trace = graph.require_quiescent(run_execute_start_graph())
    graph.assert_covers(trace, {
      "github-devloop.devloop_execute_request -> github-devloop.execute_start",
      "github-devloop.devloop_consensus_request -> github-devloop.consensus_result",
      "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
    })

    local step = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_execute_request",
      consumer = "github-devloop.execute_start",
    })
    t.eq(step.exit_code, 0)

    local consensus_step = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_consensus_request",
      consumer = "github-devloop.consensus_result",
    })
    t.eq(consensus_step.exit_code, 0)

    t.eq(#step.raises, 3)
    t.eq(step.raises[1].queue, "github-proxy.github_issue_comment_request")
    t.eq(step.raises[2].queue, "github-proxy.github_issue_label_request")
    t.eq(step.raises[3].queue, "github-devloop.devloop_consensus_request")

    local comment = step.raises[1].payload
    t.eq(comment.schema, "github-proxy.v1")
    t.eq(comment.repo, repo)
    t.eq(tostring(comment.issue_number), tostring(issue_number))
    t.is_true(comment.body:find(h.state_comment_request(proposal_id, "thinking", request_dedup_key).body, 1, true) ~= nil)

    local label = step.raises[2].payload
    t.eq(label.schema, "github-proxy.label.v1")
    t.eq(label.add_labels[1], "fkst-dev:thinking")
    t.eq(label.dedup_key, request_dedup_key .. "/label/thinking")

    local proposal = step.raises[3].payload
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.proposal_id, proposal_id)
    t.eq(proposal.dedup_key, request_dedup_key)
    t.eq(proposal.effect_version, request_dedup_key)
    t.eq(proposal.intake_hand_off.kind, "own-intake-decision")
    t.eq(proposal.intake_hand_off.dedup_key, request_dedup_key)
    t.eq(proposal.source_ref.ref, repo .. "#issue/" .. tostring(issue_number))

    assert_env_command_contract()
  end,

  test_run_graph_unmocked_checkout_probe_failure_names_the_command = function()
    local trace = run_execute_start_graph({
      omit_checkout_probe_mock = true,
      request_dedup_key = request_dedup_key .. "/unmocked-command",
    })
    local ok, err = pcall(function()
      graph.require_quiescent(trace)
    end)
    local expected = "unmocked external command: " .. consensus_core.checkout_root_exists_cmd(".")

    t.eq(ok, false)
    if tostring(err):find(expected, 1, true) == nil then
      error("missing producer-owned command diagnostic expected=" .. expected .. " actual=" .. tostring(err), 2)
    end
  end,
}
