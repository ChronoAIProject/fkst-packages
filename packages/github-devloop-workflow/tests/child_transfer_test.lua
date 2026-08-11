local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_entity = require("devloop.entity")
local parsers_misc = require("devloop.parsers.misc")
local devloop_logging = require("devloop.logging")
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
local FINAL_SUCCESSOR_ISSUE = 110
local OFF_CHAIN_SUCCESSOR_ISSUE = 111
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

local function verified_delivery_blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "software-feature-flow",
    version = "1",
    summary = "Deliver a feature in two increments.",
    applies_when = "The feature needs a production slice.",
    steps = {
      { id = "walking-skeleton", title = "Walking skeleton", content = { kind = "static", intent = "Build the skeleton." } },
      { id = "production-slice", title = "Production slice", content = { kind = "static", intent = "Finish production." } },
    },
  }
end

local function origin_comments(owned_child_issue, selected_blueprint, selected_slot)
  local blueprint = selected_blueprint or workflow_blueprint()
  local slot = selected_slot or blueprint.steps[1].id
  local blueprint_digest = core.digest.blueprint_digest(blueprint)
  local blueprint_marker = assert(marker.build_blueprint_marker(
    ORIGIN,
    blueprint.id,
    blueprint_digest
  ))
  local materialization_marker = assert(marker.build_materialization_marker(
    ORIGIN,
    blueprint_digest,
    slot,
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
    if type(model.after_successful_push) == "function" then
      model.after_successful_push()
    end
    return result()
  end

  return git, model
end

local function install_github_fake(events, owned_child_issue, selected_blueprint, selected_slot)
  local model = github_fake.model({
    issues = {
      [source_ref(ORIGIN_ISSUE).ref] = issue(
        ORIGIN_ISSUE,
        "OPEN",
        origin_comments(owned_child_issue, selected_blueprint, selected_slot)
      ),
      [source_ref(PREDECESSOR_ISSUE).ref] = issue(PREDECESSOR_ISSUE, "OPEN"),
      [source_ref(SUCCESSOR_ISSUE).ref] = issue(SUCCESSOR_ISSUE, "OPEN"),
      [source_ref(FINAL_SUCCESSOR_ISSUE).ref] = issue(FINAL_SUCCESSOR_ISSUE, "OPEN"),
      [source_ref(OFF_CHAIN_SUCCESSOR_ISSUE).ref] = issue(OFF_CHAIN_SUCCESSOR_ISSUE, "OPEN"),
    },
  })
  model.fail_closes = 0
  model.successful_closes = 0
  model.reads = {}
  local github = github_fake.new(model)
  local fake_read_issue = github.read_issue

  function github.read_issue(target_source_ref, opts)
    t.eq(type(opts), "table")
    t.eq(opts.force_fresh, true)
    t.is_true(type(opts.consumer) == "string" and opts.consumer ~= "")
    model.reads[#model.reads + 1] = {
      source_ref = target_source_ref,
      consumer = opts.consumer,
    }
    return fake_read_issue(target_source_ref, opts)
  end

  function github.issue_comment_create(repo, issue_number, body_file)
    t.eq(repo, REPO)
    local target = model.issues[source_ref(issue_number).ref]
    local body = assert(file.read(body_file))
    if model.hide_comment_write ~= true then
      target.comments[#target.comments + 1] = trusted_comment(body)
    end
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
    t.eq(disposition.kind, "duplicate")
    t.is_true(model.issues[source_ref(issue_number).ref] ~= nil)
    t.is_true(model.issues[source_ref(disposition.duplicate_of).ref] ~= nil)
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

local function fixture(owned_child_issue, selected_blueprint, selected_slot)
  local events = {}
  local github, github_model = install_github_fake(
    events,
    owned_child_issue,
    selected_blueprint,
    selected_slot
  )
  local git, git_model = install_receipt_git_fake(events)
  return {
    events = events,
    github = github,
    github_model = github_model,
    git = git,
    git_model = git_model,
  }
end

local function request(predecessor_issue, successor_issue, selected_blueprint, selected_slot)
  local blueprint = selected_blueprint or workflow_blueprint()
  return core.child_transfer.build_request({
    origin = ORIGIN,
    blueprint_digest = core.digest.blueprint_digest(blueprint),
    slot = selected_slot or blueprint.steps[1].id,
    predecessor_source_ref = source_ref(predecessor_issue or PREDECESSOR_ISSUE),
    successor_source_ref = source_ref(successor_issue or SUCCESSOR_ISSUE),
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
  parsers_misc.configure_trusted_bot_login(BOT)
end

local function run_transfer(state, expecting_failure, payload)
  mock_write_env()
  local transfer_department = require("departments.workflow_transfer_child.main")
  local department = transfer_department.make_department({
    github = state.github,
    git = state.git,
  })
  local previous_with_lock = with_lock
  with_lock = state.with_lock or function(_key, fn) return fn() end
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

local function capture_transfer_logs(fn)
  local captured = {}
  local previous_log_line = devloop_logging.log_line
  devloop_logging.log_line = function(_level, _dept, _proposal_id, _tag, fields)
    captured[#captured + 1] = table.concat(fields or {}, " ")
  end
  local ok, outcome = pcall(fn)
  devloop_logging.log_line = previous_log_line
  if not ok then
    error(outcome, 0)
  end
  return outcome, captured
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

local function materialized_child_ref(selected_blueprint, selected_slot)
  local blueprint = selected_blueprint or workflow_blueprint()
  return {
    kind = "issue",
    repo = REPO,
    issue_number = tostring(PREDECESSOR_ISSUE),
    proposal_id = base_ids.proposal_id(REPO, PREDECESSOR_ISSUE),
    source_ref = source_ref(PREDECESSOR_ISSUE),
    origin = ORIGIN,
    blueprint_digest = core.digest.blueprint_digest(blueprint),
    slot = selected_slot or blueprint.steps[1].id,
  }
end

local function read_materialized_child_status(state, receipt_store)
  local child_status = require("core.materialize.child_status")
  local reader = child_status.reader(core, {
    github = state.github,
    git = state.git,
    receipt_store = receipt_store,
  }, REPO)
  return reader(materialized_child_ref())
end

local function resolved_materialized_child_ref(state)
  local child_status = require("core.materialize.child_status")
  local observer = child_status.observer(core, {
    github = state.github,
    git = state.git,
  }, REPO)
  return observer.resolved_ref(materialized_child_ref())
end

local function add_verified_satisfaction(state, blueprint, slot, child_issue)
  local origin = state.github_model.issues[source_ref(ORIGIN_ISSUE).ref]
  origin.comments[#origin.comments + 1] = trusted_comment(assert(marker.build_verified_satisfaction_marker({
    origin = ORIGIN,
    workflow = blueprint.id,
    blueprint_digest = core.digest.blueprint_digest(blueprint),
    slot = slot,
    child_issue = tostring(child_issue),
    predecessor_commit = string.rep("2", 40),
    tree = string.rep("3", 40),
    verification = "PASS",
  })))
end

local function add_merged_evidence(state, issue_number)
  local successor_issue = issue_number or SUCCESSOR_ISSUE
  local successor = state.github_model.issues[source_ref(successor_issue).ref]
  local proposal_id = base_ids.proposal_id(REPO, successor_issue)
  local version = "ready/" .. proposal_id .. "/intake/1"
  local pr_number = successor_issue + 101
  local pr_proposal_id = "github-devloop/pr/" .. REPO .. "/" .. tostring(pr_number)
  local head_sha = "0123456789abcdef0123456789abcdef01234567"
  successor.comments[#successor.comments + 1] = trusted_comment(table.concat({
    core.state_marker(proposal_id, "merged", version),
    marker_builders.pr_delegation_marker(proposal_id, pr_proposal_id, pr_number, version, "g1"),
    marker_builders.merged_marker(proposal_id, pr_number, version, head_sha),
  }, "\n"))
  successor.state = "CLOSED"
end

local tests = {
  test_verified_satisfaction_freezes_the_current_tip_before_terminal_publication = function()
    local blueprint = verified_delivery_blueprint()
    local slot = "production-slice"
    local state = fixture(PREDECESSOR_ISSUE, blueprint, slot)
    add_verified_satisfaction(state, blueprint, slot, PREDECESSOR_ISSUE)

    local child_status = require("core.materialize.child_status")
    local guarded_tip = child_status.observer(core, {
      github = state.github,
      git = state.git,
    }, REPO).resolved_ref(materialized_child_ref(blueprint, slot))
    t.eq(guarded_tip.issue_number, tostring(PREDECESSOR_ISSUE))

    local lock_keys = {}
    state.with_lock = function(key, fn)
      lock_keys[#lock_keys + 1] = key
      return fn()
    end
    local outcome = run_transfer(
      state,
      true,
      request(PREDECESSOR_ISSUE, SUCCESSOR_ISSUE, blueprint, slot)
    )

    t.eq(lock_keys[1], devloop_entity.observe_lock_key(REPO, ORIGIN_ISSUE))
    t.is_true(tostring(outcome.failure.error):find(
      "transfer-tip-satisfaction-verified",
      1,
      true
    ) ~= nil)
    t.eq(state.git_model.successful_pushes, 0)
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "OPEN")
  end,

  test_verified_satisfaction_fences_only_new_edges_from_the_exact_current_tip = function()
    local blueprint = verified_delivery_blueprint()
    local slot = "production-slice"
    local state = fixture(PREDECESSOR_ISSUE, blueprint, slot)
    local first_edge = request(PREDECESSOR_ISSUE, SUCCESSOR_ISSUE, blueprint, slot)
    local second_edge = request(SUCCESSOR_ISSUE, FINAL_SUCCESSOR_ISSUE, blueprint, slot)

    run_transfer(state, false, first_edge)
    add_verified_satisfaction(state, blueprint, slot, PREDECESSOR_ISSUE)
    run_transfer(state, false, second_edge)

    add_verified_satisfaction(state, blueprint, slot, FINAL_SUCCESSOR_ISSUE)
    run_transfer(state, false, second_edge)
    t.eq(state.git_model.successful_pushes, 2)
    t.eq(state.github_model.successful_closes, 2)
  end,

  test_non_transfer_receipts_fail_closed_before_child_status_projection = function()
    for _, disposition in ipairs({ "satisfied", "undeliverable" }) do
      local state = fixture()
      local ok, err = pcall(read_materialized_child_status, state, {
        read = function()
          return { disposition = disposition }
        end,
      })

      t.eq(ok, false)
      t.is_true(tostring(err):find("transfer-chain-receipt-invalid", 1, true) ~= nil)
    end
  end,

  test_transfer_orders_acceptance_receipt_and_close_then_parent_follows_successor = function()
    local state = fixture()

    run_transfer(state)

    t.eq(table.concat(state.events, ","), "acceptance,receipt,close")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "CLOSED")
    t.eq(state.git_model.successful_pushes, 1)
    t.eq(state.github_model.successful_closes, 1)
    local transfer_reads = {}
    for index = 1, 7 do
      transfer_reads[index] = state.github_model.reads[index].consumer
    end
    t.eq(table.concat(transfer_reads, ","), table.concat({
      "workflow_transfer_child:origin",
      "workflow_transfer_child:predecessor",
      "workflow_transfer_child:successor",
      "workflow_transfer_child:acceptance-readback",
      "workflow_transfer_child:pre-close-predecessor",
      "workflow_transfer_child:pre-close-successor",
      "workflow_transfer_child:close-readback",
    }, ","))

    local waiting = run_materialization_poll(state)
    t.is_nil(terminal_request(waiting.raises))

    add_merged_evidence(state)
    local completed = run_materialization_poll(state)
    local terminal = terminal_request(completed.raises)
    t.is_true(terminal ~= nil)
    t.is_true(terminal.body:find('state="done"', 1, true) ~= nil)

    run_transfer(state)
    t.eq(count_writes(state.github_model, "issue_comment_create"), 1)
    t.eq(state.git_model.successful_pushes, 1)
    t.eq(state.github_model.successful_closes, 1)
  end,

  test_transfer_follows_the_full_production_chain_and_projects_only_the_final_tip = function()
    local state = fixture()

    run_transfer(state, false, request(PREDECESSOR_ISSUE, SUCCESSOR_ISSUE))
    run_transfer(state, false, request(SUCCESSOR_ISSUE, FINAL_SUCCESSOR_ISSUE))

    t.eq(table.concat(state.events, ","), "acceptance,receipt,close,acceptance,receipt,close")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "CLOSED")
    t.eq(state.github_model.issues[source_ref(SUCCESSOR_ISSUE).ref].state, "CLOSED")
    t.eq(state.github_model.issues[source_ref(FINAL_SUCCESSOR_ISSUE).ref].state, "OPEN")

    local resolved = resolved_materialized_child_ref(state)
    t.eq(resolved.issue_number, tostring(FINAL_SUCCESSOR_ISSUE))
    t.eq(resolved.source_ref.ref, source_ref(FINAL_SUCCESSOR_ISSUE).ref)

    local waiting = run_materialization_poll(state)
    t.is_nil(terminal_request(waiting.raises))
    add_merged_evidence(state, PREDECESSOR_ISSUE)
    add_merged_evidence(state, SUCCESSOR_ISSUE)
    local predecessors_merged = run_materialization_poll(state)
    t.is_nil(terminal_request(predecessors_merged.raises))

    add_merged_evidence(state, FINAL_SUCCESSOR_ISSUE)
    local completed = run_materialization_poll(state)
    local terminal = terminal_request(completed.raises)
    t.is_true(terminal ~= nil)
    t.is_true(terminal.body:find('state="done"', 1, true) ~= nil)

    run_transfer(state, false, request(PREDECESSOR_ISSUE, SUCCESSOR_ISSUE))
    run_transfer(state, false, request(SUCCESSOR_ISSUE, FINAL_SUCCESSOR_ISSUE))
    t.eq(count_writes(state.github_model, "issue_comment_create"), 2)
    t.eq(state.git_model.successful_pushes, 2)
    t.eq(state.github_model.successful_closes, 2)
  end,

  test_transfer_rejects_stale_predecessors_and_cycles_before_external_effects = function()
    local state = fixture()
    run_transfer(state, false, request(PREDECESSOR_ISSUE, SUCCESSOR_ISSUE))

    local effect_count = #state.events
    local stale_origin = run_transfer(
      state,
      true,
      request(PREDECESSOR_ISSUE, FINAL_SUCCESSOR_ISSUE)
    )
    t.is_true(tostring(stale_origin.failure.error):find("transfer-chain-predecessor-stale", 1, true) ~= nil)
    t.eq(#state.events, effect_count)

    local two_hop_cycle = run_transfer(
      state,
      true,
      request(SUCCESSOR_ISSUE, PREDECESSOR_ISSUE)
    )
    t.is_true(tostring(two_hop_cycle.failure.error):find("transfer-chain-cycle", 1, true) ~= nil)
    t.eq(#state.events, effect_count)

    run_transfer(state, false, request(SUCCESSOR_ISSUE, FINAL_SUCCESSOR_ISSUE))
    effect_count = #state.events
    local stale_middle = run_transfer(
      state,
      true,
      request(SUCCESSOR_ISSUE, OFF_CHAIN_SUCCESSOR_ISSUE)
    )
    t.is_true(tostring(stale_middle.failure.error):find("transfer-chain-predecessor-stale", 1, true) ~= nil)
    t.eq(#state.events, effect_count)

    local longer_cycle = run_transfer(
      state,
      true,
      request(FINAL_SUCCESSOR_ISSUE, PREDECESSOR_ISSUE)
    )
    t.is_true(tostring(longer_cycle.failure.error):find("transfer-chain-cycle", 1, true) ~= nil)
    t.eq(#state.events, effect_count)
  end,

  test_committed_transfer_with_invalid_acceptance_fails_closed = function()
    local cases = {
      function(successor)
        successor.comments = {}
      end,
      function(successor)
        successor.comments[1].author_login = "untrusted-user"
      end,
      function(successor)
        successor.comments[1] = trusted_comment(
          successor.comments[1].body:gsub('successor_ref="[^"]+"', 'successor_ref="invalid"')
        )
      end,
      function(successor)
        successor.comments[1] = trusted_comment(assert(marker.build_transfer_accept_marker({
          origin = ORIGIN,
          blueprint_digest = core.digest.blueprint_digest(workflow_blueprint()),
          slot = "first",
          predecessor_source_ref = source_ref(PREDECESSOR_ISSUE),
          successor_source_ref = source_ref(FINAL_SUCCESSOR_ISSUE),
        })))
      end,
    }

    for _, mutate in ipairs(cases) do
      local state = fixture()
      run_transfer(state)
      mutate(state.github_model.issues[source_ref(SUCCESSOR_ISSUE).ref])

      local effect_count = #state.events
      local transfer_outcome = run_transfer(state, true)
      t.is_true(tostring(transfer_outcome.failure.error):find(
        "transfer-chain-acceptance-invalid",
        1,
        true
      ) ~= nil)
      t.eq(#state.events, effect_count)

      local ok, err = pcall(read_materialized_child_status, state)
      t.eq(ok, false)
      t.is_true(tostring(err):find("transfer-chain-acceptance-invalid", 1, true) ~= nil)

      local poll = run_materialization_poll(state)
      t.is_nil(terminal_request(poll.raises))
    end
  end,

  test_committed_cross_repository_transfer_fails_closed = function()
    local state = fixture()
    local store = core.child_disposition_receipt.new({ git = state.git })
    store.put_once({
      repo = REPO,
      origin = ORIGIN,
      blueprint_digest = core.digest.blueprint_digest(workflow_blueprint()),
      slot = "first",
      child_issue = tostring(PREDECESSOR_ISSUE),
      disposition = "transferred",
      successor_source_ref = base_ids.issue_source_ref("other/repo", SUCCESSOR_ISSUE),
    })

    local ok, err = pcall(read_materialized_child_status, state)
    t.eq(ok, false)
    t.is_true(tostring(err):find("transfer-chain-cross-repository", 1, true) ~= nil)

    local poll = run_materialization_poll(state)
    t.is_nil(terminal_request(poll.raises))
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

  test_acceptance_visible_log_requires_source_readback = function()
    local state = fixture()
    state.github_model.hide_comment_write = true

    local outcome, logs = capture_transfer_logs(function()
      return run_transfer(state, true)
    end)

    t.is_true(tostring(outcome.failure.error):find("transfer-acceptance-readback-missing", 1, true) ~= nil)
    local text = table.concat(logs, "\n")
    t.is_true(text:find("action=acceptance-issued", 1, true) ~= nil)
    t.is_nil(text:find("action=acceptance-visible", 1, true))
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

  test_committed_receipt_redirects_parent_while_predecessor_close_retries = function()
    local state = fixture()
    local predecessor = state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref]
    predecessor.comments[#predecessor.comments + 1] = trusted_comment(core.state_marker(
      base_ids.proposal_id(REPO, PREDECESSOR_ISSUE),
      "blocked",
      "ready/github-devloop/issue/owner/repo/108/intake/1"
    ))
    state.github_model.fail_closes = 1

    run_transfer(state, true)

    t.eq(table.concat(state.events, ","), "acceptance,receipt")
    t.eq(predecessor.state, "OPEN")
    local waiting = run_materialization_poll(state)
    t.is_nil(terminal_request(waiting.raises))
  end,

  test_successor_closure_after_receipt_does_not_strand_predecessor_close = function()
    local state = fixture()
    state.git_model.after_successful_push = function()
      state.github_model.issues[source_ref(SUCCESSOR_ISSUE).ref].state = "CLOSED"
    end

    run_transfer(state)

    t.eq(table.concat(state.events, ","), "acceptance,receipt,close")
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "CLOSED")
    t.eq(state.github_model.successful_closes, 1)
  end,

  test_parent_follows_committed_receipt_while_predecessor_close_is_blocked = function()
    local state = fixture()
    state.github_model.fail_closes = 1

    run_transfer(state, true)
    add_merged_evidence(state)
    local completed = run_materialization_poll(state)

    local terminal = terminal_request(completed.raises)
    t.is_true(terminal ~= nil)
    t.is_true(terminal.body:find('state="done"', 1, true) ~= nil)
    t.eq(state.github_model.issues[source_ref(PREDECESSOR_ISSUE).ref].state, "OPEN")
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
