local devloop_base = require("devloop.base")
local escalation = require("devloop.implementation_escalation")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local transition_version = require("contract.transition_version")
local t = h.t
local core = h.core

local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/github-devloop/issue/owner/repo/42/intake/123"
local checkpoint_head = "1111111111111111111111111111111111111111"
local base_head = "2222222222222222222222222222222222222222"

local function trusted_comment(body)
  return {
    body = body,
    author_login = devloop_base.trusted_bot_login(),
    created_at = "2026-08-05T01:00:00Z",
  }
end

local function payload()
  return escalation.build_payload({
    proposal_id = proposal_id,
    version = version,
    branch = "devloop-owner-repo-42-123",
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  }, {
    policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
    previous_attempt = 1,
    attempt = 2,
    head_sha = checkpoint_head,
  })
end

local function current_comments(event, extra)
  local comments = {
    core.state_marker(proposal_id, "implementation-escalating", version),
    m_builders.implement_checkpoint_marker(proposal_id, version,
      event.branch, checkpoint_head, "dev", base_head, 2, "wall-clock-exhausted"),
    escalation.escalation_marker(proposal_id, version, {
      policy_id = event.evidence_policy,
      previous_attempt = event.previous_attempt,
      attempt = event.attempt,
      head_sha = event.head_sha,
    }),
  }
  for _, marker in ipairs(extra or {}) do
    table.insert(comments, marker)
  end
  return comments
end

local function mock_supervisor_codex(stdout)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 2 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime/context/.bundle-tmp.implementation-decompose\n",
    stderr = "",
    exit_code = 0,
  })
  h.mock_decompose_context_bundle()
  for _ = 1, 4 do
    t.mock_command(" > ", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command("python3 -c", { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 2 do
    t.mock_command("test -r", { stdout = "", stderr = "", exit_code = 0 })
  end
  for _ = 1, 6 do
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", { stdout = stdout, stderr = "", exit_code = 0 })
end

return {
  test_stationary_timeout_supervisor_plans_native_blocking_children = function()
    local event = payload()
    local comments = current_comments(event)
    local plan = [[{"issues":[{"title":"Extract parser","body":"Implement the parser as an independent change."},{"title":"Adopt parser","body":"Wire the parser after the first child lands."}]}]]

    h.mock_bot_env()
    h.mock_default_issue_claim("owner/repo", 42)
    for _ = 1, 4 do
      t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
    end
    h.mock_issue_decompose({ "fkst-dev:implementing" }, comments, {
      title = "Large implementation",
      body = "The full issue remains available through source_ref.",
    })
    h.mock_issue_state({ "fkst-dev:implementing" }, "OPEN", comments)
    mock_supervisor_codex(plan)
    t.mock_command("gh issue comment", { stdout = "", stderr = "", exit_code = 0 })
    h.mock_issue_decompose({ "fkst-dev:implementing" }, current_comments(event, {
      escalation.decomposition_marker(event, 2),
    }), {
      title = "Large implementation",
      body = "The full issue remains available through source_ref.",
    })

    local result = h.run_department("departments/implementation_decompose/main.lua", {
      queue = "devloop_implementation_decompose",
      payload = event,
      ts = "2026-08-05T01:01:00Z",
    }, h.opts("implementation-decompose-two-children", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0, tostring(result.error))
    t.eq(#result.raises, 2)
    for _, raised in ipairs(result.raises) do
      t.eq(raised.queue, "github-proxy.github_issue_create_request")
      t.eq(raised.payload.parent, 42)
      t.eq(raised.payload.parent_comment_target.issue_number, 42)
      t.eq(raised.payload.post_create_blocked_by.blocked_issue_number, 42)
    end
  end,

  test_advanced_parent_replays_durable_decomposition_effects = function()
    local event = payload()
    local comments = current_comments(event, {
      escalation.decomposition_marker(event, 2),
      core.state_marker(proposal_id, "ready", transition_version.next_ready_split(version)),
    })
    local plan = [[{"issues":[{"title":"Extract parser","body":"Implement the parser as an independent change."},{"title":"Adopt parser","body":"Wire the parser after the first child lands."}]}]]

    h.mock_bot_env()
    h.mock_default_issue_claim("owner/repo", 42)
    for _ = 1, 4 do
      t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "1", stderr = "", exit_code = 0 })
    end
    h.mock_issue_decompose({ "fkst-dev:ready" }, comments, {
      title = "Large implementation",
      body = "The full issue remains available through source_ref.",
    })
    h.mock_issue_state({ "fkst-dev:ready" }, "OPEN", comments)
    mock_supervisor_codex(plan)

    local result = h.run_department("departments/implementation_decompose/main.lua", {
      queue = "devloop_implementation_decompose",
      payload = event,
      ts = "2026-08-05T01:02:00Z",
    }, h.opts("implementation-decompose-advanced-parent", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0, tostring(result.error))
    t.eq(#result.raises, 2)
  end,
}
