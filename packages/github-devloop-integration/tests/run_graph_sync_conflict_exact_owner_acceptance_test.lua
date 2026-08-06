local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local entity_mocks = require("tests.entity_read_mock_helpers")
local owner_fact = require("devloop.sync_conflict_owner")
local payloads_builders = require("devloop.payloads.builders")

local t = h.t
local core = h.core

local REPO = "ChronoAIProject/fkst-packages"
local BOT = "fkst-test-bot"
local ESCALATION_ISSUE = 3282
local OWNER_BRANCH = "devloop/issue/ChronoAIProject/fkst-packages/3204/ready-github-devloop-issue-ChronoAIProject-fkst-packages-3204-intake-0768218242-3305069031"
local UPSTREAM_BRANCH = "integration"
local UPSTREAM_HEAD = "b57a021c15fdfd65aef8959f375903ff1a30b8f1"
local OWNER_HEAD = "c0e40e4e0a11ac5b845aaa8f8063994ee4bb5eac"
local RESOLVED_HEAD = "d1e40e4e0a11ac5b845aaa8f8063994ee4bb5eac"
local ATTEMPT_LEDGER_SHA = "1111111111111111111111111111111111111111"
local ATTEMPT_LEDGER_TREE_SHA = "2222222222222222222222222222222222222222"
local PR_NUMBER = 3300
local PR_OPEN_COMMENT_ID = tostring(PR_NUMBER) .. "001"
local CONSENSUS_VERSION = "consensus:github-devloop/issue/ChronoAIProject/fkst-packages/3282/intake/2355091684/loop/1"
local PROPOSAL_ID = "github-devloop/issue/ChronoAIProject/fkst-packages/3282"
local UNMERGED = "100644 abcdef 1\tpackages/github-devloop/core.lua\n"

local function delivery_source_ref(source_ref)
  return {
    kind = source_ref.kind,
    reference = source_ref.ref,
  }
end

local function mock_env()
  local values = {
    FKST_GITHUB_WRITE = "1",
    FKST_GITHUB_BOT_LOGIN = BOT,
    FKST_GITHUB_REPO = REPO,
    FKST_GITHUB_CLAIM_MODE = "",
    FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
    FKST_DEVLOOP_INTEGRATION_BRANCH = UPSTREAM_BRANCH,
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "",
  }
  for name, value in pairs(values) do
    for _ = 1, 64 do
      t.mock_command(devloop_base.read_env_command(name), {
        stdout = value,
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function conflict_event()
  return {
    schema = "github-devloop.v1",
    repo = REPO,
    upstream_branch = UPSTREAM_BRANCH,
    integration_branch = OWNER_BRANCH,
    upstream_sha = UPSTREAM_HEAD,
    integration_sha = OWNER_HEAD,
    dedup_key = core.branch_sync_dedup_key(REPO, UPSTREAM_BRANCH, OWNER_BRANCH, UPSTREAM_HEAD),
    source_ref = core.branch_sync_source_ref(REPO, UPSTREAM_BRANCH, OWNER_BRANCH),
  }
end

local function mock_exhausted_conflict(event)
  local attempt_ref = core.sync_conflict_attempt_ref(event)
  t.mock_command("git fetch 'origin' '" .. UPSTREAM_BRANCH .. "'", {
    stdout = "", stderr = "", exit_code = 0,
  })
  t.mock_command("git fetch 'origin' '" .. OWNER_BRANCH .. "'", {
    stdout = "", stderr = "", exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. UPSTREAM_BRANCH .. "'^{commit}", {
    stdout = UPSTREAM_HEAD .. "\n", stderr = "", exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. OWNER_BRANCH .. "'^{commit}", {
    stdout = OWNER_HEAD .. "\n", stderr = "", exit_code = 0,
  })
  t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop-integration/exact-owner",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git worktree add --detach", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("merge --no-ff --no-commit", { stdout = "", stderr = "conflict", exit_code = 1 })
  t.mock_command("ls-files -u", { stdout = UNMERGED, stderr = "", exit_code = 0 })
  t.mock_command("git ls-remote origin " .. attempt_ref, {
    stdout = ATTEMPT_LEDGER_SHA .. "\t" .. attempt_ref .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git fetch origin " .. attempt_ref, { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git cat-file -p " .. ATTEMPT_LEDGER_SHA, {
    stdout = "tree " .. ATTEMPT_LEDGER_TREE_SHA .. "\n\n"
      .. core.sync_conflict_attempt_ledger(event, core.max_sync_conflict_attempts()) .. "\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree remove --force", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_escalation_creation()
  t.mock_command("gh issue list", { stdout = "[]\n", stderr = "", exit_code = 0 })
  t.mock_command("gh issue create", {
    stdout = "https://github.example/" .. REPO .. "/issues/" .. tostring(ESCALATION_ISSUE) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = BOT,
    created_at = "2026-08-06T01:24:07Z",
  }
end

local function mock_escalation_issue(ready, issue_body)
  local comments = {
    trusted_comment(h.projected_state_comment(PROPOSAL_ID, "ready", CONSENSUS_VERSION)),
  }
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
  entity_mocks.mock_issue_view_selector(t, {
    repo = REPO,
    number = ESCALATION_ISSUE,
    title = "Branch sync conflict requires manual resolution: integration into " .. OWNER_BRANCH,
    body = issue_body,
    state = "OPEN",
    labels = { "fkst-dev:enabled", "fkst-dev:ready" },
    comments = comments,
    assignees = { BOT },
    author_login = BOT,
  }, "title,body,labels,comments,state,author", 5)
  entity_mocks.mock_issue_view_selector(t, {
    repo = REPO,
    number = ESCALATION_ISSUE,
    assignees = { BOT },
    author_login = BOT,
  }, "assignees,author", 4)
  h.mock_context_bundle(ready)
end

local function ensure_directory(path)
  local quoted = "'" .. tostring(path):gsub("'", "'\\''") .. "'"
  local ok = os.execute("mkdir -p " .. quoted)
  if ok ~= true and ok ~= 0 then
    error("exact-owner acceptance fixture could not create worktree directory")
  end
end

local function mock_exact_owner_worktree(ready)
  local durable_root = "/tmp/fkst-packages-test/github-devloop/durable"
  local stable_root = devloop_base.implementation_worktree_root(durable_root)
  local worktree = devloop_base.implement_worktree_path(
    stable_root,
    REPO,
    ESCALATION_ISSUE,
    ready.dedup_key
  )
  ensure_directory(worktree .. "/.fkst")

  t.mock_command("git fetch 'origin' '" .. UPSTREAM_BRANCH .. "'", {
    stdout = "", stderr = "", exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. UPSTREAM_BRANCH .. "'^{commit}", {
    stdout = UPSTREAM_HEAD .. "\n", stderr = "", exit_code = 0,
  })
  t.mock_command("show-ref --verify --quiet", { stdout = "", stderr = "", exit_code = 1 })
  t.mock_command("git worktree list --porcelain", { stdout = "", stderr = "", exit_code = 0 })
  h.mock_force_clean(worktree)
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git fetch 'origin' '" .. OWNER_BRANCH .. "'", {
    stdout = "", stderr = "", exit_code = 0,
  })
  t.mock_command("refs/remotes/'origin'/'" .. OWNER_BRANCH .. "'^{commit}", {
    stdout = OWNER_HEAD .. "\n", stderr = "", exit_code = 0,
  })
  t.mock_command("git worktree add --force -B", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("reset --hard", { stdout = "HEAD is now at " .. OWNER_HEAD .. "\n", stderr = "", exit_code = 0 })
  t.mock_command("clean -fd", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("merge --no-edit '" .. UPSTREAM_HEAD .. "'", {
    stdout = "", stderr = "conflict", exit_code = 1,
  })
  t.mock_command("ls-files -u", { stdout = UNMERGED, stderr = "", exit_code = 0 })
  t.mock_command("git show " .. UPSTREAM_HEAD .. ":.fkst/substrate-ref", {
    stdout = "3333333333333333333333333333333333333333\n", stderr = "", exit_code = 0,
  })
  t.mock_command("git show " .. OWNER_BRANCH .. ":.fkst/substrate-ref", {
    stdout = "3333333333333333333333333333333333333333\n", stderr = "", exit_code = 0,
  })
  for _ = 1, 2 do
    t.mock_command("[ -d '" .. worktree .. "' ]", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git worktree list --porcelain", {
      stdout = "worktree " .. worktree .. "\nHEAD " .. RESOLVED_HEAD
        .. "\nbranch refs/heads/" .. OWNER_BRANCH .. "\n\n",
      stderr = "",
      exit_code = 0,
    })
  end
  return worktree
end

local function mock_comment_writes(number, count)
  local comments_path = "repos/" .. REPO .. "/issues/" .. tostring(number) .. "/comments?per_page=100"
  for index = 1, count do
    local comment_id = tostring(number) .. string.format("%03d", index)
    t.mock_command("gh api --paginate --slurp " .. comments_path, {
      stdout = "[[]]\n", stderr = "", exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp '" .. comments_path .. "'", {
      stdout = "[[]]\n", stderr = "", exit_code = 0,
    })
    t.mock_command("gh api --method POST repos/" .. REPO .. "/issues/" .. tostring(number) .. "/comments --field 'body=", {
      stdout = '{"id":' .. comment_id .. ',"body":"created","user":{"login":"' .. BOT .. '"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_implementation_outbound()
  mock_comment_writes(ESCALATION_ISSUE, 8)
  mock_comment_writes(PR_NUMBER, 4)
  t.mock_command("gh api --method GET 'repos/" .. REPO .. "/issues/comments/" .. PR_OPEN_COMMENT_ID .. "'", {
    stdout = '{"body":"' .. h.json_string(core.state_marker(PROPOSAL_ID, "pr-open", CONSENSUS_VERSION))
      .. '","user":{"login":"' .. BOT .. '"}}\n',
    stderr = "",
    exit_code = 0,
  })
  entity_mocks.mock_pr_view_selector(t, {
    repo = REPO,
    number = PR_NUMBER,
    title = "Existing exact-owner PR",
    head = OWNER_BRANCH,
    head_sha = RESOLVED_HEAD,
    base_branch = UPSTREAM_BRANCH,
    state = "OPEN",
    comments = {},
    labels = {},
    author_login = BOT,
  }, entity_mocks.pr_origin_selector, 1)
  for _, number in ipairs({ ESCALATION_ISSUE, PR_NUMBER }) do
    for _ = 1, 16 do
      t.mock_command("gh api repos/" .. REPO .. "/issues/" .. tostring(number), {
        stdout = '{"labels":[{"name":"fkst-dev:ready"}],"assignees":[{"login":"' .. BOT
          .. '"}],"user":{"login":"' .. BOT .. '"}}\n',
        stderr = "",
        exit_code = 0,
      })
    end
  end
  for _ = 1, 8 do
    t.mock_command("gh label list", {
      stdout = '[{"name":"fkst-dev:ready"},{"name":"fkst-dev:implementing"},{"name":"fkst-dev:awaiting-pr"}]\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh issue edit", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("gh pr edit", { stdout = "", stderr = "", exit_code = 0 })
  end
  t.mock_command(core.gh_pr_list_head_base_cmd(REPO, OWNER_BRANCH, UPSTREAM_BRANCH), {
    stdout = '[{"number":' .. tostring(PR_NUMBER)
      .. ',"head":{"ref":"' .. OWNER_BRANCH .. '","sha":"' .. RESOLVED_HEAD
      .. '"},"base":{"ref":"' .. UPSTREAM_BRANCH .. '"},"state":"open"}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function rendered_call_containing(text)
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(text, 1, true) ~= nil then
      return call
    end
  end
  return nil
end

return {
  test_exhausted_non_pr_conflict_updates_exact_owner_branch = function()
    mock_env()
    local conflict = conflict_event()
    mock_exhausted_conflict(conflict)
    mock_escalation_creation()

    local escalation = graph.require_quiescent(graph.run({
      queue = "github-devloop-integration.devloop_sync_conflict",
      payload = conflict,
      source_ref = delivery_source_ref(conflict.source_ref),
    }, { max_steps = 2 }))
    local create = graph.require_raise(escalation, "github-proxy.github_issue_create_request")
    local marker = owner_fact.find_marker(create.payload.body)
    t.eq(marker.branch, OWNER_BRANCH)
    t.eq(marker.head_sha, OWNER_HEAD)

    local ready = payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = PROPOSAL_ID,
      dedup_key = CONSENSUS_VERSION,
      source_ref = entity_lib.issue_source_ref(REPO, ESCALATION_ISSUE),
    })
    mock_escalation_issue(ready, create.payload.body)
    mock_exact_owner_worktree(ready)
    h.mock_implement_codex(0, "implemented", "")
    h.mock_git_status(" M packages/github-devloop/core.lua\n")
    h.mock_git_commit(RESOLVED_HEAD, OWNER_BRANCH)
    t.mock_command("diff --name-only", {
      stdout = "packages/github-devloop/core.lua\n", stderr = "", exit_code = 0,
    })
    t.mock_command("push origin HEAD:refs/heads/" .. OWNER_BRANCH, {
      stdout = "pushed " .. OWNER_BRANCH .. "\n", stderr = "", exit_code = 0,
    })
    mock_implementation_outbound()

    local implementation = graph.require_quiescent(graph.run({
      queue = "github-devloop.devloop_ready",
      payload = ready,
      source_ref = delivery_source_ref(ready.source_ref),
    }, { max_steps = 30 }))
    local step = graph.require_delivery(implementation, {
      queue = "github-devloop.devloop_ready",
      consumer = "github-devloop.implement",
    })
    t.eq(step.exit_code, 0)

    local escalation_branch = devloop_base.implement_branch(REPO, ESCALATION_ISSUE, ready.dedup_key)
    local add = rendered_call_containing("git worktree add --force -B")
    t.is_true(add ~= nil)
    t.is_true(add.rendered:find(OWNER_BRANCH, 1, true) ~= nil)
    t.is_true(rendered_call_containing("push origin HEAD:refs/heads/" .. OWNER_BRANCH) ~= nil)
    t.is_nil(rendered_call_containing(escalation_branch))
  end,
}
