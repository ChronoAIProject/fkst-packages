local author_policy = require("testkit_internal.github_author_policy")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local graph = require("testkit.graph")
local marker_builders = require("devloop.markers.builders")
local premise_correction = require("devloop.premise_correction")
local t = fkst.test
local context_fixtures = require("testkit_internal.devloop_helpers_fixtures")

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local decline_dedup = "github-devloop/issue/owner/repo/42/intake/decline-1"
local decline_reason = "The deployment requires a production credential."

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

local function correction_fixture()
  local premise = premise_correction.premise_fingerprint(proposal_id, decline_dedup, decline_reason)
  local evidence = "The repository fake adapter removes the production-credential requirement."
  local correction_id = "IC_graph_correction"
  local correction = premise_correction.correction_fingerprint(correction_id, evidence)
  return {
    premise = premise,
    correction = correction,
    comments = {
      {
        id = "IC_graph_decline",
        body = marker_builders.intake_decision_marker(
          proposal_id,
          "decline",
          decline_dedup,
          "standard",
          premise
        ),
        author = devloop_base._test_bot_login,
        created_at = "2026-07-27T10:00:00Z",
      },
      {
        id = correction_id,
        body = evidence .. '\n\n<!-- fkst:premise-correction:v1 premise="' .. premise
          .. '" correction="' .. correction .. '" -->',
        author = "trusted-human",
        created_at = "2026-07-27T10:01:00Z",
      },
    },
  }
end

local function issue_view_json(fixture)
  local comments = {}
  for _, comment in ipairs(fixture.comments) do
    table.insert(comments, string.format(
      '{"id":"%s","body":"%s","author":{"login":"%s"},"createdAt":"%s"}',
      json_string(comment.id),
      json_string(comment.body),
      json_string(comment.author),
      json_string(comment.created_at)
    ))
  end
  return string.format(
    '{"title":"Automate deployment","body":"Use the repository fake deployment adapter.","updatedAt":"2026-07-27T10:02:00Z","state":"OPEN","labels":[],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    table.concat(comments, ",")
  )
end

local function initial_event()
  local source_ref = entity_lib.issue_source_ref(repo, issue_number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      updated_at = "2026-07-27T10:02:00Z",
      dedup_key = "owner/repo#issue#42@2026-07-27T10:02:00Z",
      source_ref = source_ref,
    },
    source_ref = {
      kind = source_ref.kind,
      reference = source_ref.ref,
    },
  }
end

local function mock_env()
  author_policy.mock_env(t, nil, { times = 32 })
  for _ = 1, 32 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_OUTPUT_LANG"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_WORKFLOW_CATALOG_ROOT"', {
      stdout = "/tmp/fkst-packages-test/premise-correction/no-catalog",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/premise-correction/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_issue_reads(fixture)
  for _ = 1, 12 do
    t.mock_command("gh issue view", {
      stdout = issue_view_json(fixture),
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_context_bundle(fixture)
  local decision_key = premise_correction.decision_dedup_key(
    devloop_base.intake_decision_dedup_key(proposal_id, {
      title = "Automate deployment",
      body = "Use the repository fake deployment adapter.",
    }),
    { premise_fingerprint = fixture.premise, correction_fingerprint = fixture.correction }
  )
  context_fixtures.materialize_context_bundle({
    proposal_id = proposal_id,
    dedup_key = decision_key,
  }, "/tmp/fkst-packages-test/premise-correction/runtime",
    "/tmp/fkst-packages-test/premise-correction/runtime/context/.bundle-tmp.intake")
  local ok = { stdout = "", stderr = "", exit_code = 0 }
  for _ = 1, 3 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command("test -e", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", ok)
  t.mock_command("mktemp -d", {
    stdout = "/tmp/fkst-packages-test/premise-correction/runtime/context/.bundle-tmp.intake\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh issue view", {
    stdout = issue_view_json(fixture),
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
end

local function mock_codex()
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", {
    stdout = "⟦FKST:WORKFLOW_SELECT⟧ none",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", {
    stdout = "⟦FKST:INTAKE⟧ enable\n⟦FKST:CLASS⟧ standard\n⟦FKST:REASON⟧ The corrected evidence supports autonomous implementation.",
    stderr = "",
    exit_code = 0,
  })
end

local function find_step_raise(step, queue)
  for _, raised in ipairs(step and step.raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

return {
  test_run_graph_re_adjudicates_decline_from_premise_correction = function()
    local fixture = correction_fixture()
    mock_env()
    mock_issue_reads(fixture)
    mock_context_bundle(fixture)
    mock_codex()

    local trace = graph.run(initial_event(), { max_steps = 12 })
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-devloop-intake.admission",
      "github-devloop-intake.devloop_intake_candidate -> github-devloop-workflow.workflow_select",
    })

    local candidate = graph.require_raise(trace, "github-devloop-intake.devloop_intake_candidate")
    t.eq(candidate.payload.premise_fingerprint, fixture.premise)
    t.eq(candidate.payload.correction_fingerprint, fixture.correction)
    t.is_nil(candidate.payload.correction_evidence)

    local workflow_step = graph.require_delivery(trace, {
      queue = "github-devloop-intake.devloop_intake_candidate",
      consumer = "github-devloop-workflow.workflow_select",
    })
    t.eq(workflow_step.exit_code, 0)
    local decision = find_step_raise(workflow_step, "github-proxy.github_issue_comment_request")
    local execute = find_step_raise(workflow_step, "github-devloop.devloop_execute_request")
    t.is_true(decision ~= nil)
    t.is_true(decision.payload.body:find("github-devloop intake decision: enable", 1, true) ~= nil)
    t.is_true(execute ~= nil)
    t.eq(execute.payload.proposal_id, proposal_id)
  end,
}
