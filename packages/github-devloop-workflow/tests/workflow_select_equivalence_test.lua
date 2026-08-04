local core = require("core")
local devloop_base = require("devloop.base")
local marker_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit_internal.testing")
local t = fkst.test
local author_policy = require("testkit_internal.github_author_policy")

local candidate_queue = "github-devloop-intake.devloop_intake_candidate"

local function json_string(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
    :gsub("[%z\1-\31]", function(char)
      return string.format("\\u%04X", string.byte(char))
    end)
end

local function encode_labels(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, '{"name":"' .. json_string(label) .. '"}')
  end
  return table.concat(rendered, ",")
end

local function encode_comments(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    local body = type(comment) == "table" and comment.body or comment
    local author = type(comment) == "table" and comment.author_login or "fkst-test-bot"
    local created_at = type(comment) == "table" and comment.created_at or "2026-06-03T01:00:00Z"
    table.insert(rendered, '{"body":"' .. json_string(body)
      .. '","author":{"login":"' .. json_string(author)
      .. '"},"createdAt":"' .. json_string(created_at) .. '"}')
  end
  return table.concat(rendered, ",")
end

local function issue_view_stdout(fields)
  local f = fields or {}
  return string.format(
    '{"title":"%s","body":"%s","createdAt":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"%s"}],"author":{"login":"%s"}}\n',
    json_string(f.title or "Repair retry backoff for failed widget sync"),
    json_string(f.body or "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries."),
    json_string(f.created_at or "2026-06-03T01:00:00Z"),
    json_string(f.updated_at or "2026-06-03T01:02:03Z"),
    json_string(f.state or "OPEN"),
    encode_labels(f.labels),
    encode_comments(f.comments),
    json_string(f.assignee or "fkst-test-bot"),
    json_string(f.author_login or "fkst-test-bot")
  )
end

local function issue_list_stdout(issues)
  local rendered = {}
  for _, issue in ipairs(issues or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"title":"%s","body":"%s","updatedAt":"%s","labels":[%s],"assignees":[{"login":"%s"}],"author":{"login":"%s"},"closedAt":"%s"}',
      tonumber(issue.number) or 1,
      json_string(issue.title or "Issue"),
      json_string(issue.body or ""),
      json_string(issue.updated_at or "2026-06-03T01:02:03Z"),
      encode_labels(issue.labels or {}),
      json_string(issue.assignee or "fkst-test-bot"),
      json_string(issue.author_login or "fkst-test-bot"),
      json_string(issue.closed_at or "2026-06-02T01:02:03Z")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_OUTPUT_LANG"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_WORKFLOW_CATALOG_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop-workflow/no-catalog",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view(current, times)
  local result = {
    stdout = issue_view_stdout(current),
    stderr = "",
    exit_code = 0,
  }
  for _ = 1, times or 2 do
    t.mock_command("gh issue view", result)
  end
end

local function mock_context_bundle(current)
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  author_policy.mock_env(t, {
    env = {
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
      FKST_GITHUB_AUTHORIZED_LOGINS = "",
    },
  }, {
    times = 4,
  })
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop-workflow/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  for _ = 1, 8 do
    t.mock_command("test -e", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", ok)
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/github-devloop-workflow/runtime/context/.bundle-tmp.intake\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue view", {
    stdout = issue_view_stdout(current),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr list", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 8 do
    t.mock_command("touch ", ok)
  end
  for _ = 1, 8 do
    t.mock_command("printf %s '", ok)
    t.mock_command(" > ", ok)
  end
  t.mock_command("python3 -c", ok)
  t.mock_command("rm -rf ", ok)
  for _ = 1, 8 do
    t.mock_command("test -r", ok)
  end
  for _ = 1, 8 do
    t.mock_command("wc -c < ", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("mkdir -p", ok)
end

local function mock_codex(stdout, current)
  mock_context_bundle(current)
  t.mock_command("codex exec", {
    stdout = stdout,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_workflow_none()
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop-workflow/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("codex exec", {
    stdout = "⟦FKST:WORKFLOW_SELECT⟧ none",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_class_escalation_lists(siblings)
  t.mock_command("gh issue list", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list", {
    stdout = issue_list_stdout(siblings),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_workflow_select_path(case, current)
  mock_env()
  mock_issue_view(current, 2)
  mock_workflow_none()
  mock_codex(case.codex, current)
  if case.class_siblings ~= nil then
    mock_class_escalation_lists(case.class_siblings)
  end
end

local function candidate()
  return payloads_builders.build_devloop_intake_candidate_payload("owner/repo", 42, "2026-06-03T01:02:03Z")
end

local function expected_decision_key(payload)
  return devloop_base.intake_decision_dedup_key(payload.proposal_id, {
    title = "Repair retry backoff for failed widget sync",
    body = "Implement exponential backoff for widget sync retries. Acceptance: unit tests cover 1s, 2s, and capped retries.",
  })
end

local function event(payload)
  return {
    queue = candidate_queue,
    payload = payload,
    ts = "2026-06-03T01:02:03Z",
  }
end

local function run_workflow_select(payload, name)
  local _ = name
  return testing.run_fake(require("departments.workflow_select.main"), event(payload))
end

local function exercise_default_policy(case)
  local payload = candidate()
  local current = case.current or {}
  mock_workflow_select_path(case, current)
  local workflow_result = run_workflow_select(payload, "workflow-select-" .. case.name)

  t.eq(#workflow_result.raises, #case.expected_queues)
  for index, expected_queue in ipairs(case.expected_queues) do
    t.eq(workflow_result.raises[index].queue, expected_queue)
  end
  local decision = workflow_result.raises[1]
  t.eq(decision.queue, "github-proxy.github_issue_comment_request")
  t.is_true(decision.payload.body:find('decision="' .. case.action .. '"', 1, true) ~= nil)
end

local class_siblings = {
  { number = 80, title = "Widget sync retry patch", labels = { "fingerprint:widget-sync" } },
  { number = 81, title = "Widget sync retry overflow fix", labels = { "fingerprint:widget-sync" } },
  { number = 82, title = "Widget sync timeout fix", labels = { "fingerprint:widget-sync" } },
}

local tests = {
  test_non_workflow_enable_uses_default_policy = function()
    exercise_default_policy({
      name = "enable",
      action = "enable",
      expected_queues = {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
        "github-devloop.devloop_execute_request",
      },
      codex = "⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ expedite\n⟦FKST:REASON⟧ Clear bounded implementation task.",
    })
  end,

  test_non_workflow_track_uses_default_policy = function()
    exercise_default_policy({
      name = "track",
      action = "track",
      expected_queues = {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
      },
      codex = "⟦FKST:INTAKE⟧ track\n⟦FKST:CLASS⟧ background\n⟦FKST:REASON⟧ Umbrella tracker issue; individual waves should be separate proposals.",
    })
  end,

  test_non_workflow_decline_uses_default_policy = function()
    exercise_default_policy({
      name = "decline",
      action = "decline",
      expected_queues = {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
      },
      current = {
        body = "Rotate production credentials after human confirmation.",
        labels = { "fkst-class:background" },
      },
      codex = "⟦FKST:INTAKE⟧ decline\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Requires production credentials and human confirmation.",
    })
  end,

  test_non_workflow_escalate_to_class_uses_default_policy = function()
    exercise_default_policy({
      name = "escalate",
      action = "enable",
      expected_queues = {
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
        "github-devloop.devloop_execute_request",
      },
      current = {
        title = "Fix widget sync retry overflow again",
        body = "Third recurrence after #80 and #81; decide whether this needs a class-level retry policy.",
      },
      class_siblings = class_siblings,
      codex = "⟦FKST:INTAKE⟧ escalate-to-class\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Cites #80 and #81 as prior siblings; Rule of Three requires class-level retry policy.",
    })
  end,

  test_pr_state_marker_does_not_satisfy_issue_thinking_milestone = function()
    local payload = candidate()
    local decision_key = expected_decision_key(payload)
    local current = {
      labels = { "fkst-dev:enabled" },
      comments = {
        marker_builders.intake_decision_marker(payload.proposal_id, "enable", decision_key, "expedite"),
        core.state_marker(payload.proposal_id, "reviewing", decision_key),
      },
    }
    mock_workflow_select_path({
      codex = "⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ expedite\n⟦FKST:REASON⟧ Replay must not run intake codex.",
    }, current)

    local result = run_workflow_select(payload, "workflow-select-pr-state-marker")

    t.eq(#result.raises, 2)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_label_request")
    t.eq(result.raises[2].queue, "github-devloop.devloop_execute_request")
  end,
}

return tests
