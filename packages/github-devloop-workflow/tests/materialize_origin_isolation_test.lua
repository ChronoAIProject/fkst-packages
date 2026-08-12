local base_ids = require("devloop.base_ids")
local actions = require("core.materialize.actions")
local core = require("core")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local digest = require("core.digest")
local marker = require("core.marker")
local materialization = require("core.materialization")
local materialize_reconcile = require("materialize_reconcile")
local saga = require("workflow.saga")
local testing = require("testkit_internal.testing")
local t = fkst.test

local repo = "owner/repo"
local issue_numbers = { 42, 43 }

local function blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "workflow-one",
    version = "2026-07-30",
    summary = "A single-step workflow.",
    applies_when = "The origin issue has a workflow blueprint.",
    steps = {
      {
        id = "implement",
        title = "Implement the change",
        content = {
          kind = "static",
          intent = "Implement the requested change.",
        },
      },
    },
  }
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-07-30T00:00:00Z",
  }
end

local function ready_origin(issue_number)
  local origin = base_ids.proposal_id(repo, issue_number)
  local plan = blueprint()
  local blueprint_digest = digest.blueprint_digest(plan)
  local blueprint_body, blueprint_err = marker.build_blueprint_marker(origin, plan.id, blueprint_digest)
  t.is_nil(blueprint_err)

  local entry = materialization.write_generated_entry(
    origin,
    blueprint_digest,
    plan.steps[1],
    materialization.EMPTY_PREDECESSOR_REF_DIGEST,
    { title = "Implement the change", body = "Implement the requested change." }
  )
  local materialization_body, materialization_err = marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    tostring(issue_number + 1000),
    "created"
  )
  t.is_nil(materialization_err)

  return {
    title = "Workflow origin " .. tostring(issue_number),
    body = "Run the workflow.",
    state = "OPEN",
    labels = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    comments = {
      trusted_comment(blueprint_body),
      trusted_comment(materialization_body),
    },
    repo = repo,
    number = issue_number,
  }
end

local function event()
  return {
    queue = "github-devloop-workflow.workflow_materialization_tick",
    payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
    source_ref = { kind = "external", ref = repo .. "#materialization-tick" },
    attempt = 3,
    ts = "2026-07-30T00:00:00Z",
  }
end

local function department(options)
  local config = options or {}
  return saga.department({
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
        return repo
      end,
      list_open_issues = function()
        if config.shared_discovery_failure then
          error("shared-discovery-failed")
        end
        return {
          { number = issue_numbers[1] },
          { number = issue_numbers[2] },
        }
      end,
      read_issue = function(_core, _repo, issue_number)
        if config.read_failures and config.read_failures[issue_number] then
          error("github-devloop-workflow: materialization-issue-view-failed: transient origin read")
        end
        local current = ready_origin(issue_number)
        if config.done_origins and config.done_origins[issue_number] then
          local origin = base_ids.proposal_id(repo, issue_number)
          local terminal_body, terminal_err = marker.build_terminal_marker(origin, "done", "all-slots-merged")
          t.is_nil(terminal_err)
          current.comments[#current.comments + 1] = trusted_comment(terminal_body)
        end
        if config.merged_origins and config.merged_origins[issue_number] then
          current.labels = { "fkst-dev:merged" }
        end
        return current
      end,
      verify_issue_claim = function()
        return true
      end,
      child_status = function()
        return "result_ready"
      end,
      load_blueprints = function()
        if config.shared_catalog_failure then
          error("shared-catalog-failed")
        end
        return {
          valid = {
            ["workflow-one"] = {
              path = "test-workflow.json",
              blueprint = blueprint(),
            },
          },
        }
      end,
      release_done_claim = function(_core, _repo, issue_number)
        if config.release_failures and config.release_failures[issue_number] then
          error("origin-release-failed")
        end
        config.released_claims = config.released_claims or {}
        config.released_claims[#config.released_claims + 1] = issue_number
        return true
      end,
      close_done_origin = function(_core, _repo, issue_number)
        config.closed_origins = config.closed_origins or {}
        config.closed_origins[#config.closed_origins + 1] = issue_number
        return true
      end,
      search_created_issue = function()
        return nil
      end,
    },
  }))
end

local function run_tick(options, expecting_failure)
  local config = options or {}
  local captured_logs = {}
  local old_log = log
  local old_with_lock = with_lock
  local old_assert_trusted_bot_configured = parsers_misc.assert_trusted_bot_configured
  local old_raise_request = actions.raise_request
  log = {
    info = function(message) captured_logs[#captured_logs + 1] = tostring(message) end,
    warn = function(message) captured_logs[#captured_logs + 1] = tostring(message) end,
    error = function(message) captured_logs[#captured_logs + 1] = tostring(message) end,
  }
  with_lock = function(_key, fn)
    return fn()
  end
  if config.shared_configuration_failure then
    parsers_misc.assert_trusted_bot_configured = function()
      error("shared-configuration-failed")
    end
  end
  if config.commit_failure then
    actions.raise_request = function()
      error("shared-effect-commit-failed")
    end
  end

  local ok, result = pcall(function()
    if expecting_failure then
      return testing.run_fake_expecting_failure(department(config), event())
    end
    return testing.run_fake(department(config), event())
  end)
  log = old_log
  with_lock = old_with_lock
  parsers_misc.assert_trusted_bot_configured = old_assert_trusted_bot_configured
  actions.raise_request = old_raise_request
  if not ok then
    error(result, 0)
  end
  return result, captured_logs
end

local function joined_logs(logs)
  return table.concat(logs or {}, "\n")
end

local function count_logs(logs, needle)
  local count = 0
  for _, line in ipairs(logs or {}) do
    if line:find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function count_logs_with_all(logs, needles)
  local count = 0
  for _, line in ipairs(logs or {}) do
    local matched = true
    for _, needle in ipairs(needles) do
      if line:find(needle, 1, true) == nil then
        matched = false
        break
      end
    end
    if matched then
      count = count + 1
    end
  end
  return count
end

local function raised_issue_numbers(raises)
  local numbers = {}
  for _, effect in ipairs(raises or {}) do
    numbers[#numbers + 1] = effect.payload.issue_number
  end
  return numbers
end

return {
  test_origin_read_failure_records_structured_fact_and_continues_sibling = function()
    local result, logs = run_tick({ read_failures = { [42] = true } })
    t.eq(#result.raises, 1)
    t.eq(raised_issue_numbers(result.raises)[1], 43)

    local text = joined_logs(logs)
    t.is_true(text:find("proposal_id=" .. base_ids.proposal_id(repo, 42), 1, true) ~= nil)
    t.is_true(text:find("tag=ORIGIN_FAILURE", 1, true) ~= nil)
    t.is_true(text:find("error_class=materialization-issue-view-failed", 1, true) ~= nil)
    t.is_true(text:find("fingerprint=fp-", 1, true) ~= nil)
    t.is_true(text:find("source_ref=external:" .. repo .. "#issue/42", 1, true) ~= nil)
    t.is_true(text:find("attempt=3", 1, true) ~= nil)
    t.is_true(text:find("terminal=false", 1, true) ~= nil)
  end,

  test_origin_effects_are_discarded_when_later_claim_release_fails = function()
    local result, logs = run_tick({
      done_origins = { [42] = true },
      merged_origins = { [42] = true },
      release_failures = { [42] = true },
    })
    t.eq(#result.raises, 1)
    t.eq(raised_issue_numbers(result.raises)[1], 43)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 1)
    t.eq(count_logs_with_all(logs, {
      "proposal_id=" .. base_ids.proposal_id(repo, 42),
      "outcome=applied(done)",
    }), 0)
  end,

  test_all_origin_failures_remain_origin_facts_without_count_based_tick_failure = function()
    local result, logs = run_tick({ read_failures = { [42] = true, [43] = true } })
    t.eq(#result.raises, 0)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 2)
  end,

  test_shared_discovery_failure_remains_tick_fatal = function()
    local result, logs = run_tick({ shared_discovery_failure = true }, true)
    t.is_true(tostring(result.failure.error):find("shared-discovery-failed", 1, true) ~= nil)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 0)
    t.eq(count_logs(logs, "tag=FAILURE"), 1)
  end,

  test_shared_configuration_failure_remains_tick_fatal = function()
    local result, logs = run_tick({ shared_configuration_failure = true }, true)
    t.is_true(tostring(result.failure.error):find("shared-configuration-failed", 1, true) ~= nil)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 0)
    t.eq(count_logs(logs, "tag=FAILURE"), 1)
  end,


  test_shared_catalog_failure_remains_tick_fatal = function()
    local result, logs = run_tick({ shared_catalog_failure = true }, true)
    t.is_true(tostring(result.failure.error):find("shared-catalog-failed", 1, true) ~= nil)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 0)
    t.eq(count_logs(logs, "tag=FAILURE"), 1)
  end,

  test_effect_commit_failure_remains_tick_fatal = function()
    local config = { commit_failure = true, released_claims = {} }
    local result, logs = run_tick(config, true)
    t.is_true(tostring(result.failure.error):find("shared-effect-commit-failed", 1, true) ~= nil)
    t.eq(count_logs(logs, "tag=ORIGIN_FAILURE"), 0)
    t.eq(count_logs(logs, "tag=FAILURE"), 1)
    t.eq(#config.released_claims, 0)
    t.eq(count_logs_with_all(logs, {
      "proposal_id=" .. base_ids.proposal_id(repo, 42),
      "outcome=applied(done)",
    }), 0)
  end,

  test_effect_commit_failure_does_not_close_done_origin = function()
    local config = {
      commit_failure = true,
      done_origins = { [42] = true },
      closed_origins = {},
    }
    local result = run_tick(config, true)
    t.is_true(tostring(result.failure.error):find("shared-effect-commit-failed", 1, true) ~= nil)
    t.eq(#config.closed_origins, 0)
  end,
}
