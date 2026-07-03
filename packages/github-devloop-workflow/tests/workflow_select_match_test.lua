local core = require("core")
local base_ids = require("devloop.base_ids")
local blueprint = require("core.blueprint")
local digest = require("core.digest")
local devloop_base = require("devloop.base")
local devloop_facts = require("devloop.markers.facts")
local devloop_marker_builders = require("devloop.markers.builders")
local graph = require("testkit.graph")
local marker = require("core.marker")
local payloads_builders = require("devloop.payloads.builders")
local testing = require("testkit.testing")
local t = fkst.test

local candidate_queue = "github-devloop-intake.devloop_intake_candidate"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

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
  for index, comment in ipairs(comments or {}) do
    local c = type(comment) == "table" and comment or { body = tostring(comment or "") }
    table.insert(rendered, string.format(
      '{"id":"%s","body":"%s","createdAt":"%s","author":{"login":"%s"}}',
      json_string(c.id or ("comment-" .. tostring(index))),
      json_string(c.body or ""),
      json_string(c.created_at or "2026-06-03T01:03:00Z"),
      json_string(c.author_login or "fkst-test-bot")
    ))
  end
  return table.concat(rendered, ",")
end

local function issue_view_stdout(fields)
  local f = fields or {}
  return string.format(
    '{"title":"%s","body":"%s","createdAt":"%s","updatedAt":"%s","state":"%s","labels":[%s],"comments":[%s],"assignees":[{"login":"%s"}],"author":{"login":"%s"}}\n',
    json_string(f.title or "Run the release workflow"),
    json_string(f.body or "Please run the release workflow for this repository."),
    json_string(f.created_at or "2026-06-03T01:00:00Z"),
    json_string(f.updated_at or "2026-06-03T01:02:03Z"),
    json_string(f.state or "OPEN"),
    encode_labels(f.labels or {}),
    encode_comments(f.comments or {}),
    json_string(f.assignee or "fkst-test-bot"),
    json_string(f.author_login or "fkst-test-bot")
  )
end

local function workflow_json(id, selector_json, step_intent)
  local selector = selector_json ~= nil and (',"selector":' .. selector_json) or ""
  return string.format(
    '{"schema":"fkst.workflow.v1","id":"%s","version":"2026-07-02","summary":"%s summary","applies_when":"%s applies to matching origin issues","steps":[{"id":"first","title":"First step","content":{"kind":"static","intent":"%s"}}]%s}',
    json_string(id),
    json_string(id),
    json_string(id),
    json_string(step_intent),
    selector
  )
end

local function test_root()
  local token = tostring({}):gsub("[^A-Za-z0-9]", "")
  return "/tmp/fkst-workflow-select-match-" .. token
end

local function cleanup(root)
  os.remove(root .. "/workflow-alpha.json")
  os.remove(root .. "/workflow-beta.json")
  os.execute("rmdir " .. shell_quote(root) .. " >/dev/null 2>&1")
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if ok ~= true and ok ~= 0 then
    error("failed to create temp workflow catalog")
  end
end

local function with_catalog(files, fn)
  local root = test_root()
  cleanup(root)
  mkdir_p(root)
  for name, source in pairs(files or {}) do
    file.write(root .. "/" .. name, source)
  end
  local ok, err = pcall(function()
    fn(root)
  end)
  cleanup(root)
  if not ok then
    error(err, 0)
  end
end

local function candidate()
  return payloads_builders.build_devloop_intake_candidate_payload(core, "owner/repo", 42, "2026-06-03T01:02:03Z")
end

local function decision_key_for_current(payload, current)
  local c = current or {}
  return devloop_base.intake_decision_dedup_key(payload.proposal_id, {
    title = c.title or "Run the release workflow",
    body = c.body or "Please run the release workflow for this repository.",
  })
end

local function event(payload)
  return {
    queue = candidate_queue,
    payload = payload,
    ts = "2026-06-03T01:02:03Z",
  }
end

local function mock_env(root)
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
  t.mock_command('printf %s "$FKST_WORKFLOW_CATALOG_ROOT"', {
    stdout = root,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view(current, times)
  for _ = 1, times or 1 do
    t.mock_command("gh issue view", {
      stdout = issue_view_stdout(current),
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_issue_views(...)
  for _, current in ipairs({ ... }) do
    mock_issue_view(current, 1)
  end
end

local function mock_workflow_codex(stdout, exit_code)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop-workflow/workflow-select-runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", {
    stdout = stdout,
    stderr = "",
    exit_code = exit_code or 0,
  })
end

local function mock_default_context_bundle(current)
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop-workflow/default-intake-runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("test -e", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", ok)
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/github-devloop-workflow/default-intake-runtime/context/.bundle-tmp.intake\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue view", {
    stdout = issue_view_stdout(current),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  t.mock_command("gh pr list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  for _ = 1, 8 do
    t.mock_command("touch ", ok)
    t.mock_command("printf %s '", ok)
    t.mock_command(" > ", ok)
    t.mock_command("test -r", ok)
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("python3 -c", ok)
  t.mock_command("rm -rf ", ok)
  t.mock_command("mkdir -p", ok)
end

local function mock_default_codex(stdout, current)
  t.mock_command('printf %s "$FKST_OUTPUT_LANG"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  mock_default_context_bundle(current)
  t.mock_command("codex exec", {
    stdout = stdout or "⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ Clear bounded implementation task.",
    stderr = "",
    exit_code = 0,
  })
end

local function run_workflow_select(payload)
  return testing.run_fake(require("departments.workflow_select.main"), event(payload))
end

local function raises_to_queue(raises, queue)
  local result = {}
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      table.insert(result, raised)
    end
  end
  return result
end

local function codex_calls()
  local calls = {}
  for _, call in ipairs(t.command_calls()) do
    if call.rendered:find("codex exec", 1, true) ~= nil then
      table.insert(calls, call)
    end
  end
  return calls
end

local function assert_default_enable_raised(result)
  t.is_true(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request") == 1)
  t.is_true(#raises_to_queue(result.raises, "github-proxy.github_issue_create_request") == 0)
  for _, raised in ipairs(result.raises) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      t.is_nil(raised.payload.body:find("github-devloop-workflow:blueprint:v1", 1, true))
    end
  end
end

local function run_fallthrough_case(root, current, workflow_stdout)
  local payload = candidate()
  mock_env(root)
  mock_issue_view(current, 2)
  if workflow_stdout ~= nil then
    mock_workflow_codex(workflow_stdout)
  end
  mock_default_codex(nil, current)
  local result = run_workflow_select(payload)
  assert_default_enable_raised(result)
  return result, codex_calls()
end

local function run_selected_workflow_case(root, first_current, fresh_current)
  local payload = candidate()
  mock_env(root)
  mock_issue_views(first_current, fresh_current or first_current)
  mock_workflow_codex("⟦FKST:WORKFLOW_SELECT⟧ workflow-alpha")
  return run_workflow_select(payload), payload
end

local function blueprint_comment(payload, workflow_id, plan_digest)
  return marker.build_blueprint_marker(payload.proposal_id, workflow_id, plan_digest)
end

local function intake_decision_comment(payload)
  return devloop_marker_builders.intake_decision_marker(core, payload.proposal_id, "track", decision_key_for_current(payload), "standard")
end

local tests = {
  test_selector_match_writes_one_blueprint_track_decision_without_default_or_child = function()
    local source = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "SECRET STEP BODY MUST NOT ENTER PROMPT OR PAYLOAD")
    with_catalog({
      ["workflow-alpha.json"] = source,
    }, function(root)
      local payload = candidate()
      local parsed = blueprint.parse_blueprint(source)
      local plan_digest = digest.blueprint_digest(parsed)

      mock_env(root)
      mock_issue_view({ labels = { "workflow" } }, 2)
      mock_workflow_codex("⟦FKST:WORKFLOW_SELECT⟧ workflow-alpha")

      local result = run_workflow_select(payload)
      t.eq(#result.raises, 1)
      t.eq(result.raises[1].queue, "github-proxy.github_issue_comment_request")
      t.eq(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_create_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_label_request"), 0)

      local request = result.raises[1].payload
      t.eq(request.dedup_key, base_ids.dedup_key({
        "workflow",
        "blueprint-decision",
        tostring(payload.proposal_id),
        tostring(payload.dedup_key),
      }))
      local blueprint_marker = marker.parse_blueprint_marker(request.body, payload.proposal_id)
      t.eq(blueprint_marker.workflow, "workflow-alpha")
      t.eq(blueprint_marker.digest, plan_digest)

      local intake = devloop_facts.intake_decision_fact(core, {
        { body = request.body, author_login = "fkst-test-bot", created_at = "2026-07-03T00:00:00Z" },
      }, payload.proposal_id)
      t.eq(intake.decision, "track")
      t.eq(intake.dedup_key, payload.dedup_key)
      t.is_nil(request.body:find("SECRET STEP BODY", 1, true))

      local calls = codex_calls()
      t.eq(#calls, 1)
      t.is_true(calls[1].stdin:find("⟦FKST:WORKFLOW_SELECT⟧", 1, true) ~= nil)
      t.is_nil(calls[1].stdin:find("⟦FKST:INTAKE⟧", 1, true))
      t.is_true(calls[1].stdin:find("workflow-alpha summary", 1, true) ~= nil)
      t.is_nil(calls[1].stdin:find("SECRET STEP BODY", 1, true))
    end)
  end,

  test_workflow_selection_skips_blueprint_when_fresh_issue_is_closed = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local result = run_selected_workflow_case(root, {
        labels = { "workflow" },
      }, {
        labels = { "workflow" },
        state = "CLOSED",
      })

      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_comment_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request"), 0)
      t.eq(#codex_calls(), 1)
    end)
  end,

  test_workflow_selection_skips_blueprint_when_fresh_decision_dedup_changes = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local result = run_selected_workflow_case(root, {
        labels = { "workflow" },
        body = "Original content that selected the workflow.",
      }, {
        labels = { "workflow" },
        body = "Changed content makes the slow workflow selection stale.",
        updated_at = "2026-06-03T01:04:00Z",
      })

      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_comment_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request"), 0)
      t.eq(#codex_calls(), 1)
    end)
  end,

  test_workflow_selection_skips_blueprint_when_fresh_intake_decision_exists = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local payload = candidate()
      mock_env(root)
      mock_issue_views({
        labels = { "workflow" },
      }, {
        labels = { "workflow" },
        comments = {
          {
            body = intake_decision_comment(payload),
            author_login = "fkst-test-bot",
          },
        },
      })
      mock_workflow_codex("⟦FKST:WORKFLOW_SELECT⟧ workflow-alpha")

      local result = run_workflow_select(payload)
      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_comment_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request"), 0)
      t.eq(#codex_calls(), 1)
    end)
  end,

  test_workflow_selection_skips_duplicate_when_fresh_blueprint_exists = function()
    local source = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step.")
    with_catalog({
      ["workflow-alpha.json"] = source,
    }, function(root)
      local payload = candidate()
      local parsed = blueprint.parse_blueprint(source)
      local plan_digest = digest.blueprint_digest(parsed)
      mock_env(root)
      mock_issue_views({
        labels = { "workflow" },
      }, {
        labels = { "workflow" },
        comments = {
          {
            body = blueprint_comment(payload, "workflow-alpha", plan_digest),
            author_login = "fkst-test-bot",
          },
        },
      })
      mock_workflow_codex("⟦FKST:WORKFLOW_SELECT⟧ workflow-alpha")

      local result = run_workflow_select(payload)
      t.eq(#raises_to_queue(result.raises, "github-proxy.github_issue_comment_request"), 0)
      t.eq(#raises_to_queue(result.raises, "github-devloop.devloop_execute_request"), 0)
      t.eq(#codex_calls(), 1)
    end)
  end,

  test_selector_no_match_falls_through_to_default_intake = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"],"title_contains_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local _result, calls = run_fallthrough_case(root, {
        title = "Repair ordinary retry backoff",
        labels = { "bug" },
      }, nil)

      t.eq(#calls, 1)
      t.is_true(calls[1].stdin:find("⟦FKST:INTAKE⟧", 1, true) ~= nil)
      t.is_nil(calls[1].stdin:find("⟦FKST:WORKFLOW_SELECT⟧", 1, true))
    end)
  end,

  test_workflow_codex_none_falls_through_to_default_intake = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local _result, calls = run_fallthrough_case(root, {
        labels = { "workflow" },
      }, "⟦FKST:WORKFLOW_SELECT⟧ none")

      t.eq(#calls, 2)
      t.is_true(calls[1].stdin:find("⟦FKST:WORKFLOW_SELECT⟧", 1, true) ~= nil)
      t.is_true(calls[2].stdin:find("⟦FKST:INTAKE⟧", 1, true) ~= nil)
    end)
  end,

  test_workflow_codex_noneligible_id_falls_through_to_default_intake = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the matching workflow step."),
      ["workflow-beta.json"] = workflow_json("workflow-beta", '{"labels_any":["other"]}', "Do another workflow step."),
    }, function(root)
      local _result, calls = run_fallthrough_case(root, {
        labels = { "workflow" },
      }, "⟦FKST:WORKFLOW_SELECT⟧ workflow-beta")

      t.eq(#calls, 2)
      t.is_true(calls[1].stdin:find("workflow-alpha summary", 1, true) ~= nil)
      t.is_nil(calls[1].stdin:find("workflow-beta summary", 1, true))
      t.is_true(calls[2].stdin:find("⟦FKST:INTAKE⟧", 1, true) ~= nil)
    end)
  end,

  test_workflow_codex_garbage_falls_through_to_default_intake = function()
    with_catalog({
      ["workflow-alpha.json"] = workflow_json("workflow-alpha", '{"labels_any":["workflow"]}', "Do the workflow step."),
    }, function(root)
      local _result, calls = run_fallthrough_case(root, {
        labels = { "workflow" },
      }, "not a valid workflow id")

      t.eq(#calls, 2)
      t.is_true(calls[1].stdin:find("⟦FKST:WORKFLOW_SELECT⟧", 1, true) ~= nil)
      t.is_true(calls[2].stdin:find("⟦FKST:INTAKE⟧", 1, true) ~= nil)
    end)
  end,
}

return tests
