local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local consensus_core = require("consensus.core")

local t = h.t
local core = h.core

local proposal_id = "github-devloop/issue/owner/repo/42"
local proposal_version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local consensus_version = "consensus:" .. proposal_version
local ready_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local lean_proposal_version = "github-devloop/issue/owner/repo/42/2026-06-03T02-02-03Z"
local lean_consensus_version = "consensus:" .. lean_proposal_version
local lean_ready_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T02-02-03Z"
local runtime_root = "/tmp/fkst-packages-test/github-devloop-run-graph-ready/runtime"
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local lean_framing = "Change `Proofs/Target.lean` only."
local lean_checker_command = "lake env lean -E hasSorry Proofs/Target.lean"

local function lean_complete_receipt()
  return '{"schema":"github-devloop.lean-proof-result.v1"'
    .. ',"status":"complete"'
    .. ',"phase":"construction"'
    .. ',"proposal_id":"' .. proposal_id .. '"'
    .. ',"implementation_version":"' .. lean_ready_version .. '"'
    .. ',"attempt":1'
    .. ',"target":"Proofs/Target.lean"'
    .. ',"declaration":"target_theorem"'
    .. ',"checker_command":"' .. lean_checker_command .. '"}'
end

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function state_marker(state, version)
  return core.state_marker(proposal_id, state, version)
end

local function blocked_by_json()
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n'
end

local function mock_empty_dependencies()
  t.mock_command(core.gh_blocked_by_cmd("owner/repo", 42), {
    stdout = blocked_by_json(),
    stderr = "",
    exit_code = 0,
  })
end

local function proposal(extra)
  local value = {
    schema = "consensus.proposal.v1",
    verdict_mode = "converge",
    proposal_id = proposal_id,
    title = "Implement decision recorder",
    body = "Judge the current GitHub issue from the full source content.",
    content_fetch = "Issue owner/repo#42 requests a decision recorder.",
    worktree = ".",
    dedup_key = proposal_version,
    source_ref = source_ref(),
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function initial_event(payload)
  return {
    queue = "devloop_consensus_request",
    payload = payload or proposal(),
    source_ref = {
      kind = "external",
      reference = "owner/repo#issue/42",
    },
  }
end

local function mock_consensus_approval()
  for _ = 1, 5 do
    t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 5 do
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("codex exec", {
      stdout = verdict_label .. " approve\n" .. reply_label .. " ready handoff approves.\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_consensus_lean_approval()
  local angles = {
    "teleology",
    "parsimony",
    "fidelity",
    "natural-ownership",
    "proportional-containment",
  }
  for _ = 1, 11 do
    t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, angle in ipairs(angles) do
    local verdict = angle == "parsimony" and "abstain" or "approve"
    t.mock_command("codex exec", {
      stdout = verdict_label .. " " .. verdict .. "\n"
        .. reply_label .. " " .. angle .. " Phase P1 accepts the bounded Lean source claim.\n",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, angle in ipairs(angles) do
    local verdict = angle == "parsimony" and "abstain" or "approve"
    local stance = angle == "parsimony"
      and "⟦FKST:STANCE⟧ update because teleology bounded Lean source claim"
      or "⟦FKST:STANCE⟧ defend"
    t.mock_command("codex exec", {
      stdout = stance .. "\n"
        .. verdict_label .. " " .. verdict .. "\n"
        .. reply_label .. " " .. angle .. " Phase P2 accepts the bounded Lean source claim.\n",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("codex exec", {
    stdout = "reached:approve " .. lean_framing .. "\n"
      .. "verified-move: angle=parsimony phase=P2 citation=teleology bounded Lean source claim\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_runtime_and_context()
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = runtime_root,
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
      stdout = '{"labels":[{"name":"fkst-dev:ready"}],"assignees":[{"login":"fkst-test-bot"}],"user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_MAX_INFLIGHT"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_comment_writes(number, count)
  for _ = 1, count do
    for _, command in ipairs({
      "gh api --paginate --slurp repos/owner/repo/issues/" .. number .. "/comments?per_page=100",
      "gh api --paginate --slurp 'repos/owner/repo/issues/" .. number .. "/comments?per_page=100'",
    }) do
      t.mock_command(command, {
        stdout = "[[]]\n",
        stderr = "",
        exit_code = 0,
      })
    end
    t.mock_command("gh api --method POST repos/owner/repo/issues/" .. number .. "/comments --field 'body=", {
      stdout = '{"id":123456,"body":"created","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_github_proxy_comment_write(issue_count, pr_count)
  mock_comment_writes("42", issue_count or 1)
  mock_comment_writes("7", pr_count or 0)
end

local function mock_label_write()
  t.mock_command("gh label list --repo owner/repo --limit 1000 --json name", {
    stdout = '[{"name":"fkst-dev:thinking"},{"name":"fkst-dev:ready"}]\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue edit 42 --repo owner/repo", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_child_adoptable(branch)
  t.mock_command(core.gh_pr_list_head_base_cmd("owner/repo", branch, "dev"), {
    stdout = '[{"number":7,"head":{"ref":"' .. branch
      .. '","sha":"def456"},"base":{"ref":"dev"},"state":"open"}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_consensus_result_issue_read(version)
  local selected_version = version or consensus_version
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:thinking" },
    { state_marker("thinking", selected_version) },
    {
      repo = "owner/repo",
      number = 42,
      title = "Implement decision recorder",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
      times = 1,
    }
  )
end

local function mock_implement_issue_read()
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    title = "Implement decision recorder",
    updated_at = "2026-06-03T01:02:03Z",
    state = "CLOSED",
    labels = { "fkst-dev:ready" },
    comments = { state_marker("ready", ready_version) },
  }, "title,body,comments,labels,state,createdAt,updatedAt,assignees,author", 1)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    title = "Implement decision recorder",
    updated_at = "2026-06-03T01:02:03Z",
    state = "CLOSED",
    labels = { "fkst-dev:ready" },
    comments = { state_marker("ready", ready_version) },
  }, "title,body,labels,comments,state,author", 1)
end

return {
  test_run_graph_consensus_reached_handoffs_ready_to_implement = function()
    mock_runtime_and_context()
    mock_consensus_approval()
    mock_empty_dependencies()
    mock_consensus_result_issue_read()
    mock_github_proxy_comment_write()
    mock_label_write()
    mock_implement_issue_read()

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "github-devloop.devloop_consensus_request -> github-devloop.consensus_result",
      "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      "github-proxy.github_comment_written -> github-devloop.comment_handoff",
    })

    local result_step, result_index = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_consensus_request",
      consumer = "github-devloop.consensus_result",
    })
    t.eq(result_step.exit_code, 0)

    local ready_request, _, ready_request_index = graph.require_raise(
      trace,
      "github-proxy.github_issue_comment_request",
      function(raised)
        return graph.payload_contains(raised, 'state="ready"')
          and raised.payload.handoff ~= nil
        and raised.payload.handoff.kind == "github-devloop.ready"
      end
    )
    t.eq(ready_request_index, result_index)
    t.eq(ready_request.payload.handoff.proposal_id, proposal_id)
    t.eq(ready_request.payload.handoff.marker_version, consensus_version)

    local written, _, written_index = graph.require_raise(
      trace,
      "github-proxy.github_comment_written",
      function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop.ready"
      end
    )
    t.is_true(written_index > ready_request_index)
    t.is_true(written.payload.dedup_key:find("/written/", 1, true) ~= nil)

    local ready, _, ready_index = graph.require_raise(trace, "github-devloop.devloop_ready")
    t.is_true(ready_index > written_index)
    t.eq(ready.payload.schema, "github-devloop.ready.v1")
    t.eq(ready.payload.proposal_id, proposal_id)
    t.eq(ready.payload.dedup_key, ready_version)
    t.eq(ready.payload.ready_hand_off.comment_id, "123456")

    local implement_step, implement_index = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
    })
    t.eq(implement_step.exit_code, 0)
    t.is_true(implement_index > ready_index)
  end,

  test_run_graph_preserves_lean_framing_and_dispatches_proof_aware_implementation = function()
    local request = proposal({
      title = "Complete Proofs/Target.lean",
      dedup_key = lean_proposal_version,
    })
    local branch = h.deterministic_branch_for({
      proposal_id = proposal_id,
      dedup_key = lean_ready_version,
    })
    mock_runtime_and_context()
    mock_consensus_lean_approval()
    mock_empty_dependencies()
    mock_empty_dependencies()
    mock_consensus_result_issue_read(lean_consensus_version)
    mock_github_proxy_comment_write(5, 1)
    mock_label_write()
    h.mock_issue_implement({ "fkst-dev:ready" }, { state_marker("ready", lean_ready_version) }, {
      repo = "owner/repo",
      number = 42,
      title = "Complete Proofs/Target.lean",
      state = "OPEN",
    })
    h.mock_context_bundle({
      proposal_id = proposal_id,
      source_ref = source_ref(),
    })
    h.mock_fresh_implement_worktree({
      runtime = runtime_root,
      impl_version = lean_ready_version,
    })
    t.mock_command("git cat-file -t " .. branch .. ":lean-toolchain", {
      stdout = "blob\n",
      stderr = "",
      exit_code = 0,
    })
    h.mock_implement_codex(0, lean_complete_receipt())
    t.mock_command(lean_checker_command, {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    h.mock_git_status(" M Proofs/Target.lean\n")
    h.mock_git_commit("def456", branch)
    h.mock_git_push(branch)
    mock_pr_child_adoptable(branch)

    local trace = graph.require_quiescent(graph.run(initial_event(request), { max_steps = 20 }))

    graph.assert_covers(trace, {
      "github-devloop.devloop_consensus_request -> github-devloop.consensus_result",
      "github-proxy.github_issue_comment_request -> github-proxy.github_comment",
      "github-proxy.github_comment_written -> github-devloop.comment_handoff",
      "github-devloop.devloop_ready -> github-devloop.implement",
    })
    local ready_request = graph.require_raise(
      trace,
      "github-proxy.github_issue_comment_request",
      function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop.ready"
      end
    )
    t.eq(ready_request.payload.handoff.framing, lean_framing,
      "result comment request preserves accepted framing")

    local written = graph.require_raise(
      trace,
      "github-proxy.github_comment_written",
      function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop.ready"
      end
    )
    t.eq(written.payload.handoff.framing, lean_framing,
      "comment-written acknowledgment preserves accepted framing")

    local ready = graph.require_raise(trace, "github-devloop.devloop_ready")
    t.eq(ready.payload.framing, lean_framing,
      "devloop-ready payload preserves accepted framing")

    local implement_step = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
    })
    t.eq(implement_step.exit_code, 0)
    local output = graph.require_raise(
      trace,
      "github-proxy.github_issue_comment_request",
      function(raised)
        return tostring(raised.payload.body or ""):find("github-devloop implementation output published", 1, true) ~= nil
      end
    )
    t.is_true(output ~= nil)

    local prompt = nil
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil
        and tostring(call.stdin or ""):find("Implementation profile: `lean-proof`", 1, true) ~= nil then
        prompt = call.stdin
      end
    end
    t.is_true(prompt ~= nil)
    t.is_true(prompt:find("actual goal or error state before editing", 1, true) ~= nil)
    t.eq(h.count_calls("scripts/run.sh test-affected"), 1)
  end,
}
