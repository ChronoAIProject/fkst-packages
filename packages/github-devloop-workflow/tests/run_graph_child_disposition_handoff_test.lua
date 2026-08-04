local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local digest = require("core.digest")
local graph = require("testkit.graph")
local marker = require("core.marker")
local materialization = require("core.materialization")
local core = require("core")
local gh_argv = require("testkit_internal.gh_argv_mock")

local t = fkst.test
gh_argv.install(t, core)

local repo = "owner/repo"
local origin_issue = 42
local child_issue = 108
local origin = base_ids.proposal_id(repo, origin_issue)

local plan = {
  schema = "fkst.workflow.v1",
  id = "workflow-one",
  version = "1",
  summary = "One bounded step.",
  applies_when = "The origin requests the bounded step.",
  steps = {
    {
      id = "first",
      title = "First step",
      content = {
        kind = "static",
        intent = "Implement the first step.",
      },
    },
  },
}

local blueprint_digest = digest.blueprint_digest(plan)
local created_entry = materialization.created_entry(
  origin,
  blueprint_digest,
  plan.steps[1],
  materialization.EMPTY_PREDECESSOR_REF_DIGEST,
  { title = "First step", body = "Implement the first step." },
  child_issue
)

local function json_escape(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function issue_rest_json(number, body, author)
  return string.format(
    '{"number":%d,"title":"Fixture","body":"%s","state":"open","created_at":"2026-08-05T00:00:00Z","updated_at":"2026-08-05T00:01:00Z","labels":[],"user":{"login":"%s"},"assignees":[{"login":"fkst-test-bot"}]}\n',
    number,
    json_escape(body),
    tostring(author or "fkst-test-bot")
  )
end

local function comments_rest_json(comments)
  local rendered = {}
  for index, body in ipairs(comments or {}) do
    rendered[index] = string.format(
      '{"id":%d,"body":"%s","user":{"login":"fkst-test-bot"},"created_at":"2026-08-05T00:00:0%dZ"}',
      index,
      json_escape(body),
      index
    )
  end
  return "[[" .. table.concat(rendered, ",") .. "]]\n"
end

local function mock_command_times(command, result, times)
  for _ = 1, times do
    t.mock_command(command, result)
  end
end

local function fixture_markers()
  local blueprint_body, blueprint_err = marker.build_blueprint_marker(
    origin,
    plan.id,
    blueprint_digest
  )
  t.is_nil(blueprint_err)
  local materialization_body, materialization_err = marker.build_materialization_marker(
    origin,
    created_entry.blueprint_digest,
    created_entry.slot,
    created_entry.predecessor_ref_digest,
    created_entry.gen_contract_digest,
    created_entry.gen_spec_digest,
    created_entry.child_dedup,
    created_entry.child_issue,
    created_entry.state
  )
  t.is_nil(materialization_err)
  local lineage_body, lineage_err = marker.build_lineage_header(
    origin,
    blueprint_digest,
    "first"
  )
  t.is_nil(lineage_err)
  local disposition_body, disposition_err = marker.build_child_disposition_marker({
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = "first",
    child_issue = tostring(child_issue),
    disposition = "satisfied",
  })
  t.is_nil(disposition_err)
  return {
    origin = { blueprint_body, materialization_body },
    child_body = lineage_body,
    disposition = disposition_body,
  }
end

local function mock_authority_and_proxy(markers)
  devloop_base.configure_trusted_bot_login("fkst-test-bot")
  mock_command_times(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
    stdout = "1",
    stderr = "",
    exit_code = 0,
  }, 8)
  mock_command_times(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  }, 8)

  local origin_path = "repos/" .. repo .. "/issues/" .. tostring(origin_issue)
  mock_command_times("gh api '" .. origin_path .. "'", {
    stdout = issue_rest_json(origin_issue, "Workflow origin.", "human"),
    stderr = "",
    exit_code = 0,
  }, 2)
  mock_command_times("gh api --paginate --slurp '" .. origin_path .. "/comments?per_page=100'", {
    stdout = comments_rest_json(markers.origin),
    stderr = "",
    exit_code = 0,
  }, 2)

  local child_path = "repos/" .. repo .. "/issues/" .. tostring(child_issue)
  mock_command_times("gh api '" .. child_path .. "'", {
    stdout = issue_rest_json(child_issue, markers.child_body, "fkst-test-bot"),
    stderr = "",
    exit_code = 0,
  }, 3)
  t.mock_command("gh api --paginate --slurp '" .. child_path .. "/comments?per_page=100'", {
    stdout = comments_rest_json({}),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp '" .. child_path .. "/comments?per_page=100'", {
    stdout = comments_rest_json({}),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp '" .. child_path .. "/comments?per_page=100'", {
    stdout = comments_rest_json({ markers.disposition }),
    stderr = "",
    exit_code = 0,
  })

  t.mock_command("gh api --method POST repos/owner/repo/issues/108/comments --field 'body=", {
    stdout = '{"id":123456,"body":"created","user":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_close_cmd(repo, child_issue, { kind = "completed" }), {
    stdout = "closed\n",
    stderr = "",
    exit_code = 0,
  })
end

local function initial_event()
  return {
    queue = "github-devloop-workflow.workflow_child_disposition_request",
    payload = {
      schema = "github-devloop-workflow.child-disposition.v1",
      repo = repo,
      origin_issue_number = origin_issue,
      child_issue_number = child_issue,
      blueprint_digest = blueprint_digest,
      slot = "first",
      disposition = "satisfied",
      dedup_key = "workflow/child-disposition/request",
      source_ref = base_ids.issue_source_ref(repo, child_issue),
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#issue/" .. tostring(child_issue),
    },
  }
end

return {
  test_run_graph_records_receipt_before_exactly_one_child_close = function()
    mock_authority_and_proxy(fixture_markers())

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 5 }))
    graph.assert_covers(trace, {
      "github-proxy.github_comment_written -> github-devloop-workflow.workflow_child_disposition_handoff",
    })

    local request_step, request_index = graph.require_delivery(trace, {
      queue = "github-devloop-workflow.workflow_child_disposition_request",
      consumer = "github-devloop-workflow.workflow_child_disposition",
    })
    t.eq(request_step.exit_code, 0)
    local written, _, written_index = graph.require_raise(
      trace,
      "github-proxy.github_comment_written",
      function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop-workflow.child-disposition"
      end
    )
    t.is_true(written_index > request_index)

    local handoff_step, handoff_index = graph.require_delivery(trace, {
      queue = "github-proxy.github_comment_written",
      consumer = "github-devloop-workflow.workflow_child_disposition_handoff",
    })
    t.eq(handoff_step.exit_code, 0)
    t.is_true(handoff_index > written_index)

    local close_command = core.gh_issue_close_cmd(repo, child_issue, { kind = "completed" })
    local close_calls = 0
    for _, call in ipairs(t.command_calls()) do
      if gh_argv.call_contains(call, close_command) then
        close_calls = close_calls + 1
      end
    end
    t.eq(close_calls, 1)
  end,
}
