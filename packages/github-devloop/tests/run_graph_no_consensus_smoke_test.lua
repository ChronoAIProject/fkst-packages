local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local conv_reconcile = require("devloop.convergence.reconcile")

local t = h.t
local core = h.core
local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function state_marker()
  return core.state_marker(
    "github-devloop/issue/owner/repo/42",
    "thinking",
    base_version
  )
end

-- Owner directive (#2725): the continuation ROUND-BUDGET is no longer terminal, so a
-- budget-exhausted lineage now REDRIVES instead of routing to blocked. This graph smoke
-- test therefore exercises the GENUINE no-progress terminal that REMAINS terminal under
-- #2725: three identical convergence rounds (same angle=verdict) are a true-stall
-- (no-semantic-progress), which still routes reconcile -> blocked. The blocked delivery
-- chain (loop -> comment -> handoff -> reconcile -> blocked comment + label) is unchanged.
local function true_stall_round_marker(round)
  return conv_rounds.converge_round_marker(
    "github-devloop/issue/owner/repo/42",
    base_version,
    convergence_shared.source_ref_digest(source_ref()),
    round,
    base_version .. "/loop/" .. tostring(round),
    "Unchanged question round " .. tostring(round),
    {
      { angle = "minimal", verdict = "abstain", digest = "same-stall-" .. tostring(round) },
    },
    "open:\nunchanged finding round " .. tostring(round)
  )
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
  }
end

local function mock_runtime_and_context()
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop-run-graph/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 32 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 4 do
    t.mock_command("gh api repos/owner/repo/issues/42", {
      stdout = '{"labels":[{"name":"fkst-dev:thinking"}],"assignees":[{"login":"fkst-test-bot"}]}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_github_proxy_writes(blocked_version)
  local blocked_comments = '[[{"id":123457,"body":"'
    .. h.json_string(core.state_marker("github-devloop/issue/owner/repo/42", "blocked", blocked_version))
    .. '","user":{"login":"fkst-test-bot"}}]]\n'
  for _, command in ipairs({
    "gh api --paginate --slurp repos/owner/repo/issues/42/comments?per_page=100",
    "gh api --paginate --slurp 'repos/owner/repo/issues/42/comments?per_page=100'",
  }) do
    for _ = 1, 2 do
      t.mock_command(command, {
        stdout = "[[]]\n",
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command(command, {
      stdout = blocked_comments,
      stderr = "",
      exit_code = 0,
    })
  end
  for comment_id = 123456, 123457 do
    t.mock_command("gh api --method POST repos/owner/repo/issues/42/comments --field 'body=", {
      stdout = '{"id":' .. tostring(comment_id) .. ',"body":"created","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("gh label list --repo owner/repo --limit 1000 --json name", {
    stdout = '[{"name":"fkst-dev:thinking"},{"name":"fkst-dev:blocked"}]\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue edit 42 --repo owner/repo", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_reads()
  local comments = {
    trusted_comment(state_marker()),
    trusted_comment(true_stall_round_marker(1)),
    trusted_comment(true_stall_round_marker(2)),
  }
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:thinking" },
    comments,
    {
      repo = "owner/repo",
      number = 42,
      title = "Implement decision recorder",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
    }
  )
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    title = "Implement decision recorder",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = { "fkst-dev:thinking" },
    comments = comments,
  }, "title,updatedAt,labels,comments,state,author", 2)
  t.mock_command("gh issue view 42 --repo owner/repo --json 'title,updatedAt,labels,comments,state'", {
    stdout = entity_read_mocks.issue_view_stdout({
      repo = "owner/repo",
      number = 42,
      title = "Implement decision recorder",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
      labels = { "fkst-dev:thinking" },
      comments = comments,
    }),
    stderr = "",
    exit_code = 0,
  })
end

local function evidence_continuation_unresolved()
  -- Round 3 with the two identical prior rounds visible: three consecutive rounds with the
  -- same angle=verdict is a true-stall (no-semantic-progress), the genuine no-progress
  -- terminal that stays terminal under #2725 and routes to blocked.
  return {
    schema = "consensus.consensus_converge.v1",
    proposal_id = "github-devloop/issue/owner/repo/42",
    dedup_key = base_version .. "/loop/3",
    source_ref = source_ref(),
    round = 3,
    narrowed_question = "Unchanged question round 3",
    angle_digests = {
      { angle = "minimal", verdict = "abstain", digest = "same-stall-3" },
    },
    findings_record = "open:\nunchanged finding round 3",
  }
end

local function initial_event()
  return {
    queue = "devloop_consensus_continue",
    payload = evidence_continuation_unresolved(),
    source_ref = {
      kind = "external",
      reference = "owner/repo#issue/42",
    },
  }
end

return {
  test_run_graph_no_consensus_handoffs_reconcile_to_blocked = function()
    mock_runtime_and_context()
    mock_github_proxy_writes(conv_reconcile.reconcile_terminal_state_version(base_version, 3))
    mock_issue_reads()

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "github-devloop.devloop_consensus_continue -> github-devloop.loop",
      "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      "github-proxy.github_comment_written -> github-devloop.comment_handoff",
      "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
    })

    local loop_step, loop_index = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_consensus_continue",
      consumer = "github-devloop.loop",
    })
    t.eq(loop_step.exit_code, 0)

    local written, _, written_index = graph.require_raise(
      trace,
      "github-proxy.github_comment_written",
      function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop.reconcile"
      end
    )
    t.is_true(written_index > loop_index)
    t.is_true(written.payload.dedup_key:find("/written/", 1, true) ~= nil)

    local reconcile, _, reconcile_index = graph.require_raise(trace, "github-devloop.devloop_reconcile")
    t.is_true(reconcile_index > written_index)
    t.eq(reconcile.payload.schema, "github-devloop.reconcile.v1")

    local blocked_comment, _, blocked_index = graph.require_raise(
      trace,
      "github-proxy.github_issue_comment_request",
      function(raised)
        return graph.payload_contains(raised, "github-devloop reconcile action: drop")
          and graph.payload_contains(raised, "no-semantic-progress-after-")
          and graph.payload_contains(raised, 'state="blocked"')
      end
    )
    t.is_true(blocked_index > reconcile_index)
    t.is_true(blocked_comment.payload.body:find("fkst:github-devloop:reconcile:v1", 1, true) ~= nil)

    graph.require_raise(trace, "github-proxy.github_issue_label_request", function(raised)
      return raised.payload.add_labels[1] == "fkst-dev:blocked"
    end)
  end,
}
