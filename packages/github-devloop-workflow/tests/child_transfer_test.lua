local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local marker_builders = require("devloop.markers.builders")
local core = require("core")
local marker = require("core.marker")
local materialize_reconcile = require("materialize_reconcile")
local saga = require("workflow.saga")
local testing = require("testkit_internal.testing")

local t = fkst.test

local REPO = "owner/repo"
local BOT = "fkst-test-bot"
local ORIGIN_ISSUE = 42
local PREDECESSOR_ISSUE = 108
local SUCCESSOR_ISSUE = 109
local ORIGIN = base_ids.proposal_id(REPO, ORIGIN_ISSUE)
local TREE_SHA = string.rep("1", 40)

local function source_ref(issue_number)
  return base_ids.issue_source_ref(REPO, issue_number)
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = BOT,
    created_at = "2026-08-05T00:00:00Z",
  }
end

local function workflow_blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "transfer-walking-skeleton",
    version = "1",
    summary = "Transfer one materialized child.",
    applies_when = "The origin requests a child transfer.",
    steps = {
      {
        id = "first",
        title = "First",
        content = {
          kind = "static",
          intent = "Complete the first step.",
        },
      },
    },
  }
end

local function origin_comments(owned_child_issue)
  local blueprint = workflow_blueprint()
  local blueprint_digest = core.digest.blueprint_digest(blueprint)
  local blueprint_marker = assert(marker.build_blueprint_marker(
    ORIGIN,
    blueprint.id,
    blueprint_digest
  ))
  local materialization_marker = assert(marker.build_materialization_marker(
    ORIGIN,
    blueprint_digest,
    "first",
    "d-0000000000",
    "d-1111111111",
    "d-2222222222",
    "workflow/owner/repo/42/first",
    tostring(owned_child_issue or PREDECESSOR_ISSUE),
    "created"
  ))
  return {
    trusted_comment(blueprint_marker),
    trusted_comment(materialization_marker),
  }
end

local function issue(number, state, comments)
  return {
    number = number,
    repo = REPO,
    title = "Issue " .. tostring(number),
    body = "Fixture issue.",
    state = state or "OPEN",
    labels = {},
    assignees = {},
    author_login = "trusted-human",
    comments = comments or {},
  }
end

local function result(stdout, stderr, exit_code)
  return {
    stdout = stdout or "",
    stderr = stderr or "",
    exit_code = exit_code or 0,
  }
end

local function commit_stdout(message)
  return table.concat({
    "tree " .. TREE_SHA,
    "author FKST Test <test@example.com> 0 +0000",
    "committer FKST Test <test@example.com> 0 +0000",
    "",
    tostring(message),
  }, "\n")
end

local function install_receipt_git_fake(events)
  local model = git_fake.model({})
  model.commits = {}
  model.next_commit = 10
  model.fail_pushes = 0
  model.successful_pushes = 0
  local git = git_fake.new(model)

  function git.ls_remote_ref(_remote, ref)
    local sha = model.refs[ref]
    return result(sha and (sha .. "\t" .. ref .. "\n") or "")
  end

  function git.fetch_ref()
    return result()
  end

  function git.rev_parse_ref_commit(ref)
    if model.commits[ref] == nil then
      return result("", "missing commit", 1)
    end
    return result(ref .. "\n")
  end

  function git.rev_parse_ref_tree()
    return result(TREE_SHA .. "\n")
  end

  function git.cat_file_pretty(ref)
    local message = model.commits[ref]
    if message == nil then
      return result("", "missing commit", 1)
    end
    return result(commit_stdout(message))
  end

  function git.commit_tree(_tree_sha, _parent_sha, message_file)
    local sha = string.format("%040x", model.next_commit)
    model.next_commit = model.next_commit + 1
    model.commits[sha] = assert(file.read(message_file))
    return result(sha .. "\n")
  end

  function git.push_ref_update(_remote, sha, ref)
    if model.fail_pushes > 0 then
      model.fail_pushes = model.fail_pushes - 1
      return result("", "injected receipt push failure", 1)
    end
    if model.refs[ref] ~= nil then
      return result("", "non-fast-forward", 1)
    end
    model.refs[ref] = sha
    model.successful_pushes = model.successful_pushes + 1
    events[#events + 1] = "receipt"
    return result()
  end

  return git, model
end

local function install_github_fake(events, owned_child_issue)
  local model = github_fake.model({
    issues = {
      [source_ref(ORIGIN_ISSUE).ref] = issue(ORIGIN_ISSUE, "OPEN", origin_comments(owned_child_issue)),
      [source_ref(PREDECESSOR_ISSUE).ref] = issue(PREDECESSOR_ISSUE, "OPEN"),
      [source_ref(SUCCESSOR_ISSUE).ref] = issue(SUCCESSOR_ISSUE, "OPEN"),
    },
  })
  model.fail_closes = 0
  model.successful_closes = 0
  local github = github_fake.new(model)

  function github.issue_comment_create(repo, issue_number, body_file)
    t.eq(repo, REPO)
    local target = model.issues[source_ref(issue_number).ref]
    local body = assert(file.read(body_file))
    target.comments[#target.comments + 1] = trusted_comment(body)
    model.writes[#model.writes + 1] = {
      kind = "issue_comment_create",
      issue_number = tonumber(issue_number),
      body = body,
    }
    events[#events + 1] = "acceptance"
    return result()
  end

  function github.issue_close(repo, issue_number, disposition)
    t.eq(repo, REPO)
    t.eq(tonumber(issue_number), PREDECESSOR_ISSUE)
    t.eq(disposition.kind, "duplicate")
    t.eq(tonumber(disposition.duplicate_of), SUCCESSOR_ISSUE)
    model.writes[#model.writes + 1] = {
      kind = "issue_close",
      issue_number = tonumber(issue_number),
      disposition = disposition,
    }
    if model.fail_closes > 0 then
      model.fail_closes = model.fail_closes - 1
      error("forge.github: gh issue close failed: gh-command-failed: injected close failure", 0)
    end
    model.issues[source_ref(issue_number).ref].state = "CLOSED"
    model.successful_closes = model.successful_closes + 1
    events[#events + 1] = "close"
    return result()
  end

  return github, model
end

local function fixture(owned_child_issue)
  local events = {}
  local github, github_model = install_github_fake(events, owned_child_issue)
  local git, git_model = install_receipt_git_fake(events)
  return {
    events = events,
    github = github,
    github_model = github_model,
    git = git,
    git_model = git_model,
  }
end

local function request()
  return core.child_transfer.build_request({
    origin = ORIGIN,
    blueprint_digest = core.digest.blueprint_digest(workflow_blueprint()),
    slot = "first",
    predecessor_source_ref = source_ref(PREDECESSOR_ISSUE),
    successor_source_ref = source_ref(SUCCESSOR_ISSUE),
  })
end

local function event(payload)
  return {
    queue = "github-devloop-workflow.workflow_child_transfer_request",
    payload = payload or request(),
    ts = "2026-08-05T00:00:00Z",
  }
end

local function mock_write_env()
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', result("1"))
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', result(BOT))
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', result("1"))
  devloop_base.configure_trusted_bot_login(BOT)
end

local function run_transfer(state, expecting_failure, payload)
  mock_write_env()
  local transfer_department = require("departments.workflow_transfer_child.main")
  local department = transfer_department.make_department({
    github = state.github,
    git = state.git,
  })
  local previous_with_lock = with_lock
  with_lock = function(_key, fn)
    return fn()
  end
  local ok, outcome = pcall(function()
    if expecting_failure then
      return testing.run_fake_expecting_failure(department, event(payload))
    end
    return testing.run_fake(department, event(payload))
  end)
  with_lock = previous_with_lock
  if not ok then
    error(outcome, 0)
  end
  return outcome
end

local function run_materialization_poll(state)
  local blueprint = workflow_blueprint()
  local department = saga.department({
    consumes = { "workflow_materialization_tick" },
    produces = {
      "github-proxy.github_issue_create_request",
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    },
    stall_window = "2m",
  }, materialize_reconcile.handlers(core, {
    deps = {
      read_repo = function()
        return REPO
      end,
      list_open_issues = function()
        return { { number = ORIGIN_ISSUE, title = "Workflow origin" } }
      end,
      github = state.github,
      git = state.git,
      verify_issue_claim = function()
        return true
      end,
      dependency_gate = function()
        return { ok = true, kind = "satisfied", reason = "satisfied", unmet = {} }
      end,
      load_blueprints = function()
        return {
          valid = {
            [blueprint.id] = {
              path = "transfer-walking-skeleton.json",
              blueprint = blueprint,
            },
          },
        }
      end,
      release_done_claim = function()
        return true
      end,
      close_done_origin = function()
        return true
      end,
    },
  }))
  local previous_with_lock = with_lock
  with_lock = function(_key, fn)
    return fn()
  end
  local ok, outcome = pcall(function()
    return testing.run_fake(department, {
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      ts = "2026-08-05T00:05:00Z",
    })
  end)
  with_lock = previous_with_lock
  if not ok then
    error(outcome, 0)
  end
  return outcome
end

local function count_writes(model, kind)
  local count = 0
  for _, write in ipairs(model.writes or {}) do
    if write.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function terminal_request(raises)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request"
      and tostring(raised.payload and raised.payload.body or ""):find(
        "fkst:github-devloop-workflow:terminal:v1",
        1,
        true
      ) ~= nil then
      return raised.payload
    end
  end
  return nil
end

local function add_successor_merged_evidence(state)
  local successor = state.github_model.issues[source_ref(SUCCESSOR_ISSUE).ref]
  local proposal_id = base_ids.proposal_id(REPO, SUCCESSOR_ISSUE)
  local version = "ready/github-devloop/issue/owner/repo/109/intake/1"
  local pr_number = 210
  local pr_proposal_id = "github-devloop/pr/owner/repo/210"
  local head_sha = "0123456789abcdef0123456789abcdef01234567"
  successor.comments[#successor.comments + 1] = trusted_comment(table.concat({
    core.state_marker(proposal_id, "merged", version),
    marker_builders.pr_delegation_marker(proposal_id, pr_proposal_id, pr_number, version, "g1"),
    marker_builders.merged_marker(core, proposal_id, pr_number, version, head_sha),
  }, "\n"))
  successor.state = "CLOSED"
end

local tests = {
  test_transfer_orders_acceptance_receipt_and_close_then_parent_follows_successor = function()
    local state = fixture()

    run_transfer(state)

    t.eq(table.concat(state.events, ","), "acceptance,receipt,close")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "CLOSED")
    t.eq(state.git_model.successful_pushes, 1)
    t.eq(state.github_model.successful_closes, 1)

    local waiting = run_materialization_poll(state)
    t.is_nil(terminal_request(waiting.raises))

    add_successor_merged_evidence(state)
    local completed = run_materialization_poll(state)
    local terminal = terminal_request(completed.raises)
    t.is_true(terminal ~= nil)
    t.is_true(terminal.body:find('state="done"', 1, true) ~= nil)

    run_transfer(state)
    t.eq(count_writes(state.github_model, "issue_comment_create"), 1)
    t.eq(state.git_model.successful_pushes, 1)
    t.eq(state.github_model.successful_closes, 1)
  end,

  test_replay_after_acceptance_visibility_commits_receipt_before_close = function()
    local state = fixture()
    state.git_model.fail_pushes = 1

    run_transfer(state, true)

    t.eq(table.concat(state.events, ","), "acceptance")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "OPEN")
    run_transfer(state)
    t.eq(table.concat(state.events, ","), "acceptance,receipt,close")
    t.eq(count_writes(state.github_model, "issue_comment_create"), 1)
  end,

  test_replay_after_receipt_visibility_closes_without_rewriting_durable_facts = function()
    local state = fixture()
    state.github_model.fail_closes = 1

    run_transfer(state, true)

    t.eq(table.concat(state.events, ","), "acceptance,receipt")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "OPEN")
    run_transfer(state)
    t.eq(table.concat(state.events, ","), "acceptance,receipt,close")
    t.eq(count_writes(state.github_model, "issue_comment_create"), 1)
    t.eq(state.git_model.successful_pushes, 1)
    t.eq(state.github_model.successful_closes, 1)
  end,

  test_malformed_identity_fails_before_any_external_effect = function()
    local state = fixture()
    local malformed = request()
    malformed.successor_source_ref = source_ref(PREDECESSOR_ISSUE)

    local outcome = run_transfer(state, true, malformed)

    t.is_true(tostring(outcome.failure.error):find("transfer-identity-invalid", 1, true) ~= nil)
    t.eq(#state.events, 0)
    t.eq(#state.github_model.writes, 0)
    t.eq(state.git_model.successful_pushes, 0)
  end,

  test_origin_ledger_mismatch_fails_before_acceptance = function()
    local state = fixture(107)

    local outcome = run_transfer(state, true)

    t.is_true(tostring(outcome.failure.error):find("transfer-origin-ledger-mismatch", 1, true) ~= nil)
    t.eq(#state.events, 0)
    t.eq(count_writes(state.github_model, "issue_comment_create"), 0)
    t.eq(state.git_model.successful_pushes, 0)
  end,
}

return tests
