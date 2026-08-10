local actions = require("core.materialize.actions")
local conv_reconcile = require("devloop.convergence.reconcile")
local decompose_lib = require("devloop.decompose")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local entity_read_mocks = require("testkit_internal.entity_read_mock_fixtures").new(require("core"))
local graph = require("testkit.graph")
local m_builders = require("devloop.markers.builders")
local payloads_builders = require("devloop.payloads.builders")
local author_policy = require("testkit_internal.github_author_policy")
local context_fixtures = require("testkit_internal.devloop_helpers_fixtures")
local t = fkst.test

local repo = "owner/repo"
local root_proposal = "github-devloop/issue/owner/repo/42"
local child_proposal = "github-devloop/issue/owner/repo/43"
local pr_number = 7
local version = "ready/consensus-github-devloop/issue/owner/repo/43/2026-06-03T01-02-03Z/fix/3"
local runtime_root = "/tmp/fkst-packages-test/github-devloop-workflow/decompose-lineage-chain"

local function mock_command_times(command, stdout, times)
  for _ = 1, times or 1 do
    t.mock_command(command, { stdout = stdout, stderr = "", exit_code = 0 })
  end
end

local function source_ref()
  return {
    kind = "external",
    ref = repo .. "#pr/" .. tostring(pr_number),
  }
end

local function decompose_payload()
  local review_proposal_id = devloop_base.pr_review_proposal_id(
    repo,
    pr_number,
    version,
    "def456"
  )
  return payloads_builders.build_devloop_decompose_payload({
    proposal_id = child_proposal,
    pr_number = pr_number,
    issue_version = version,
    review_proposal_id = review_proposal_id,
    review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
    reviewed_head_sha = "def456",
    head_sha = "def456",
    round = 3,
    source_ref = source_ref(),
  })
end

local function blocked_comments()
  return {
    m_builders.pr_origin_marker(child_proposal, "43", "devloop-owner-repo-43-01HY", version, "dev"),
    require("core").state_marker(child_proposal, "blocked", version),
    conv_reconcile.fix_reconcile_marker(child_proposal, version, "drop"),
  }
end

local function mock_claim_and_reads(materialized_body, payload)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 43,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = 43,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    labels = { "fkst-dev:blocked" },
  }, "assignees,author,labels", 30)
  local issue_fields = {
    repo = repo,
    number = 43,
    title = "Workflow child",
    body = materialized_body,
    labels = { "fkst-dev:blocked" },
    comments = blocked_comments(),
  }
  entity_read_mocks.mock_issue_view_selector(t, issue_fields, "title,body,labels,comments,author")
  mock_command_times(
    "gh issue view 43 --repo owner/repo --json 'assignees,author,labels'",
    entity_read_mocks.issue_view_stdout({
      repo = repo,
      number = 43,
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      labels = { "fkst-dev:blocked" },
    }),
    30
  )
  mock_command_times(
    "gh issue view 43 --repo owner/repo --json 'title,body,labels,comments,author'",
    entity_read_mocks.issue_view_stdout(issue_fields)
  )

  local initial_pr = {
    repo = repo,
    number = pr_number,
    comments = blocked_comments(),
    head = "devloop-owner-repo-43-01HY",
    head_sha = "def456",
    base_branch = "dev",
    state = "OPEN",
  }
  entity_read_mocks.mock_pr_view_selector(t, initial_pr, entity_read_mocks.pr_origin_selector, 2)
  local pr_view_command = "gh pr view 7 --repo owner/repo --json '" .. entity_read_mocks.pr_origin_selector .. "'"
  mock_command_times(pr_view_command, entity_read_mocks.pr_view_stdout(initial_pr), 2)

  local confirmed_pr = {}
  for key, value in pairs(initial_pr) do
    confirmed_pr[key] = value
  end
  confirmed_pr.comments = blocked_comments()
  confirmed_pr.comments[#confirmed_pr.comments + 1] = decompose_lib.decomposed_marker(
    payload.proposal_id,
    payload.version,
    payload.pr_number,
    1
  )
  entity_read_mocks.mock_pr_view_selector(t, confirmed_pr, entity_read_mocks.pr_origin_selector, 1)
  mock_command_times(pr_view_command, entity_read_mocks.pr_view_stdout(confirmed_pr), 1)
  t.mock_command("gh pr comment", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  t.mock_command(
    "gh issue list --repo owner/repo --state all --limit 100 --search 'fkst:github-devloop:decompose-child:v1 github-devloop/issue/owner/repo/43' --json 'number,title,state,author,body,url'",
    { stdout = "[]\n", stderr = "", exit_code = 0 }
  )
end

local function mock_decompose_codex(payload)
  local tmp_dir = runtime_root .. "/context/.bundle-tmp.decompose"
  context_fixtures.materialize_context_bundle(payload, runtime_root, tmp_dir)
  for _ = 1, 4 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = runtime_root,
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 2 do
    t.mock_command("test -d", { stdout = "", stderr = "", exit_code = 1 })
  end
  t.mock_command("install -d -m 0755", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", { stdout = tmp_dir .. "\n", stderr = "", exit_code = 0 })
  local issue_context_stdout = '{"title":"Workflow child","body":"Materialized body","updatedAt":"2026-06-03T01:02:03Z","state":"OPEN","labels":[{"name":"fkst-dev:blocked"}],"comments":[],"author":{"login":"fkst-test-bot"}}\n'
  entity_read_mocks.mock_issue_view_raw_selector(t, {
    repo = repo,
    number = 43,
  }, "title,body,updatedAt,labels,comments,state,author", {
    stdout = issue_context_stdout,
  })
  mock_command_times(
    "gh issue view 43 --repo owner/repo --json 'title,body,updatedAt,labels,comments,state,author'",
    issue_context_stdout
  )
  local pr_context_stdout = '{"title":"PR title","body":"PR body","headRefName":"devloop-owner-repo-43-01HY","headRefOid":"def456","baseRefName":"dev","state":"OPEN","updatedAt":"2026-06-03T02:03:04Z","comments":[],"labels":[],"author":{"login":"fkst-test-bot"}}\n'
  entity_read_mocks.mock_pr_view_raw_selector(t, {
    repo = repo,
    number = pr_number,
  }, "title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author", {
    stdout = pr_context_stdout,
  })
  mock_command_times(
    "gh pr view 7 --repo owner/repo --json 'title,body,headRefName,headRefOid,baseRefName,state,updatedAt,comments,labels,author'",
    pr_context_stdout
  )
  t.mock_command("gh pr diff", {
    stdout = "diff --git a/file.lua b/file.lua\n+return true\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr diff '7' --repo 'owner/repo' --name-only", {
    stdout = "file.lua\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh pr diff 7 --repo owner/repo --name-only", {
    stdout = "file.lua\n",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 8 do
    t.mock_command(" > ", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("test -r", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("wc -c < ", { stdout = "1\n", stderr = "", exit_code = 0 })
  end
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  for _ = 1, 3 do
    t.mock_command("python3 -c", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command("codex exec", {
    stdout = [[{"issues":[{"title":"Split the workflow child","body":"Smaller scope: split the workflow child.\nNon-goals: no unrelated changes.\nAcceptance: the focused test passes."}]}]],
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_workflow_materialized_child_decomposes_with_incremented_root_lineage = function()
    local parent_body = "Parent body.\n\n" .. decompose_lib.decompose_lineage_marker(root_proposal, 0)
    local materialized = actions.issue_create_request(
      repo,
      42,
      root_proposal,
      "d-3588118930",
      "implement",
      { child_dedup = "workflow-child-43" },
      { title = "Workflow child", body = "Implement the workflow child." },
      parent_body
    )
    local inherited = decompose_lib.decompose_lineage(materialized.body)
    t.eq(inherited.root, root_proposal)
    t.eq(inherited.depth, 0)

    local payload = decompose_payload()
    author_policy.mock_env(t, {
      env = {
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "ElonSG",
        FKST_GITHUB_AUTHORIZED_LOGINS = "authorized-human",
      },
    }, {
      configure_trusted_bot_login = parsers_misc.configure_trusted_bot_login,
      times = 8,
    })
    for _ = 1, 4 do
      t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
        stdout = "1",
        stderr = "",
        exit_code = 0,
      })
    end
    for _ = 1, 8 do
      t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
    end
    mock_claim_and_reads(materialized.body, payload)
    mock_decompose_codex(payload)

    local trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-decompose.devloop_decompose",
      payload = payload,
      source_ref = { kind = "external", reference = repo .. "#pr/" .. tostring(pr_number) },
    }, { max_steps = 4 }))
    graph.assert_covers(trace, {
      "github-devloop-decompose.devloop_decompose -> github-devloop-decompose.decompose",
    })
    local step = graph.require_delivery(trace, {
      queue = "github-devloop-decompose.devloop_decompose",
      consumer = "github-devloop-decompose.decompose",
    })
    t.eq(step.exit_code, 0)

    local child = graph.require_raise(trace, "github-proxy.github_issue_create_request")
    local lineage = decompose_lib.decompose_lineage(child.payload.body)
    t.eq(lineage.root, root_proposal)
    t.eq(lineage.depth, 1)
  end,
}
