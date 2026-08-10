local author_policy = require("testkit_internal.github_author_policy")
local devloop_base = require("devloop.base")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")

local core = h.core
local t = h.t

local repo = "owner/repo"
local issue_number = 42
local blocker_issue_number = 99
local proposal_id = "github-devloop/issue/owner/repo/42"
local inner_version = "consensus-github-devloop/issue/owner/repo/42/2026-08-05T09-58-05Z"

local function source_ref()
  return {
    kind = "external",
    ref = repo .. "#issue/" .. tostring(issue_number),
  }
end

local function ready_payload()
  return payloads_builders.build_devloop_ready_payload({
    proposal_id = proposal_id,
    dedup_key = inner_version,
    source_ref = source_ref(),
  })
end

local function initial_event(ready)
  return {
    queue = "github-devloop.devloop_ready",
    payload = ready,
    source_ref = {
      kind = ready.source_ref.kind,
      reference = ready.source_ref.ref,
    },
  }
end

local function mock_empty_dependencies()
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_env(name, value, times)
  for _ = 1, times or 1 do
    t.mock_command(devloop_base.read_env_command(name), {
      stdout = value or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_runtime()
  author_policy.mock_env(t, nil, { times = 48 })
  mock_env("FKST_GITHUB_WRITE", "", 48)
  mock_env("FKST_DEVLOOP_UPSTREAM_BRANCH", "dev", 16)
  mock_env("FKST_DEVLOOP_INTEGRATION_BRANCH", "", 16)
  for _ = 1, 24 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop-precursor-refusal/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function refusal_receipt(ready)
  return '{"schema":"github-devloop.implementation-result.v1"'
    .. ',"outcome":"cannot-implement-here"'
    .. ',"proposal_id":"' .. proposal_id .. '"'
    .. ',"implementation_version":"' .. ready.dedup_key .. '"'
    .. ',"attempt":1'
    .. ',"reason":"precursor-missing"'
    .. ',"evidence":"Issue #99 must land before this implementation can proceed."'
    .. ',"blocker":{"repo":"' .. repo .. '","issue_number":99}}'
end

return {
  test_run_graph_precursor_refusal_reaches_blocked_by_adapter = function()
    local ready = ready_payload()
    mock_runtime()
    h.mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(proposal_id, "ready", ready.dedup_key),
    }, {
      repo = repo,
      number = issue_number,
      state = "OPEN",
    })
    mock_empty_dependencies()
    h.mock_context_bundle(ready)
    h.mock_existing_empty_implement_worktree({
      impl_version = ready.dedup_key,
      harvest_checks = 1,
    })
    h.mock_implement_codex(0, refusal_receipt(ready))
    h.mock_git_status("")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(initial_event(ready), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "github-proxy.github_issue_blocked_by_request -> github-proxy.github_issue_blocked_by",
    })

    local raised = graph.require_raise(
      trace,
      "github-proxy.github_issue_blocked_by_request"
    )
    t.eq(raised.payload.repo, repo)
    t.eq(raised.payload.blocked_issue_number, issue_number)
    t.eq(raised.payload.blocking_issue_number, blocker_issue_number)
    local delivered = graph.require_delivery(trace, {
      queue = "github-proxy.github_issue_blocked_by_request",
      consumer = "github-proxy.github_issue_blocked_by",
    })
    t.eq(delivered.exit_code, 0)
  end,
}
