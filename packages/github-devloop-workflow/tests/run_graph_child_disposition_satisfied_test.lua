local base_ids = require("devloop.base_ids")
local core = require("core")
local digest = require("core.digest")
local entity = require("devloop.entity")
local github_fake = require("forge.github_fake")
local materialization = require("core.materialization")
local materialize_reconcile = require("materialize_reconcile")
local marker = require("core.marker")
local saga = require("workflow.saga")
local testing = require("testkit_internal.testing")

local t = fkst.test

local repo = "owner/repo"
local origin_issue = 42
local child_issue = 108
local origin = base_ids.proposal_id(repo, origin_issue)

local function blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "workflow-one",
    version = "2026-08-05",
    summary = "Exercise one satisfied workflow child.",
    applies_when = "The acceptance fixture selects this workflow.",
    steps = {
      {
        id = "first",
        title = "First child",
        content = {
          kind = "static",
          intent = "Complete the first child.",
        },
      },
    },
  }
end

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-05T00:00:00Z",
  }
end

local function fixture()
  local plan = blueprint()
  local blueprint_digest = digest.blueprint_digest(plan)
  local blueprint_marker = assert(marker.build_blueprint_marker(origin, plan.id, blueprint_digest))
  local generated_spec = {
    title = "First child",
    body = "Complete the first child.",
  }
  local entry = assert(materialization.write_generated_entry(
    origin,
    blueprint_digest,
    plan.steps[1],
    materialization.EMPTY_PREDECESSOR_REF_DIGEST,
    generated_spec
  ))
  local materialization_marker = assert(marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    tostring(child_issue),
    "created"
  ))
  local lineage = assert(marker.build_lineage_header(origin, blueprint_digest, "first"))
  local issues = {
    [repo .. "#issue/" .. tostring(origin_issue)] = {
      number = origin_issue,
      title = "Workflow origin",
      body = "Run the one-slot workflow.",
      state = "OPEN",
      labels = {},
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      comments = {
        trusted_comment(blueprint_marker),
        trusted_comment(materialization_marker),
      },
    },
    [repo .. "#issue/" .. tostring(child_issue)] = {
      number = child_issue,
      title = "First child",
      body = lineage .. "\n\nComplete the first child.",
      state = "OPEN",
      labels = { "fkst-dev:enabled", "fkst-dev:implementing" },
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      comments = {},
    },
  }
  return {
    plan = plan,
    blueprint_digest = blueprint_digest,
    issues = issues,
  }
end

local function load_department()
  local previous_pipeline = _G.pipeline
  local module = require("departments.workflow_child_disposition.main")
  _G.pipeline = previous_pipeline
  return module
end

local function with_test_locks(fn)
  local previous_with_lock = with_lock
  local locks = {}
  with_lock = function(key, locked)
    locks[#locks + 1] = key
    return locked()
  end
  local ok, result = pcall(fn, locks)
  with_lock = previous_with_lock
  if not ok then
    error(result, 0)
  end
  return result
end

local function count(values, expected)
  local total = 0
  for _, value in ipairs(values) do
    if value == expected then
      total = total + 1
    end
  end
  return total
end

local function index_of(values, expected)
  for index, value in ipairs(values) do
    if value == expected then
      return index
    end
  end
  return nil
end

return {
  test_run_graph_satisfied_receipt_closes_child_and_completes_origin = function()
    local facts = fixture()
    local order = {}
    local stored_receipt = nil
    local receipt_store = {
      put_once = function(identity)
        order[#order + 1] = "receipt-put"
        stored_receipt = {
          schema = core.child_disposition_receipt.RECEIPT_SCHEMA,
          repo = identity.repo,
          origin = identity.origin,
          blueprint_digest = identity.blueprint_digest,
          slot = identity.slot,
          child_issue = identity.child_issue,
          disposition = identity.disposition,
          commit_sha = string.rep("a", 40),
        }
        return stored_receipt
      end,
      read = function(identity)
        order[#order + 1] = "receipt-read"
        if stored_receipt == nil then
          return nil
        end
        t.eq(identity.origin, stored_receipt.origin)
        t.eq(identity.blueprint_digest, stored_receipt.blueprint_digest)
        t.eq(identity.slot, stored_receipt.slot)
        t.eq(tostring(identity.child_issue), stored_receipt.child_issue)
        return stored_receipt
      end,
    }
    local github = github_fake.new(github_fake.model({ issues = facts.issues }))
    local read_issue = github.read_issue
    github.read_issue = function(source_ref, opts)
      order[#order + 1] = "read-" .. tostring(source_ref.ref)
      t.eq(opts.force_fresh, true)
      return read_issue(source_ref, opts)
    end
    local issue_close = github.issue_close
    github.issue_close = function(close_repo, number, disposition, timeout)
      order[#order + 1] = "close"
      t.eq(close_repo, repo)
      t.eq(tostring(number), tostring(child_issue))
      t.eq(disposition.kind, "completed")
      facts.issues[repo .. "#issue/" .. tostring(child_issue)].state = "CLOSED"
      return issue_close(close_repo, number, disposition, timeout)
    end

    local request = core.child_disposition_request.build({
      repo = repo,
      origin = origin,
      blueprint_digest = facts.blueprint_digest,
      slot = "first",
      child_issue = tostring(child_issue),
      disposition = "satisfied",
    })
    local department = load_department().make_department({
      github = github,
      receipt_store = receipt_store,
      write_enabled = function() return true end,
      claim_owner = function() return "fkst-test-bot" end,
    })

    local disposition_result = with_test_locks(function(locks)
      local result = testing.run_fake(department, {
        queue = "github-devloop-workflow.workflow_child_disposition_request",
        payload = request,
        source_ref = request.source_ref,
      })
      t.eq(locks[1], entity.merge_lane_lock_key(repo))
      return result
    end)

    t.is_nil(disposition_result.failure)
    t.eq(count(order, "read-owner/repo#issue/42"), 1)
    t.eq(count(order, "read-owner/repo#issue/108"), 2)
    t.eq(count(order, "close"), 1)
    t.is_true(index_of(order, "receipt-put") < index_of(order, "receipt-read"))
    t.is_true(index_of(order, "receipt-read") < index_of(order, "close"))

    local previous_pipeline = _G.pipeline
    local materializer = saga.department({
      consumes = { "workflow_materialization_tick" },
      produces = {
        "github-proxy.github_issue_create_request",
        "github-proxy.github_issue_comment_request",
        "github-proxy.github_issue_label_request",
      },
      stall_window = "2m",
    }, materialize_reconcile.handlers(core, {
      deps = {
        read_repo = function() return repo end,
        list_open_issues = function()
          return { { number = origin_issue, title = "Workflow origin" } }
        end,
        read_issue = function()
          return github.read_issue(base_ids.issue_source_ref(repo, origin_issue), { force_fresh = true })
        end,
        verify_issue_claim = function() return true end,
        child_disposition_receipt_store = receipt_store,
        load_blueprints = function()
          return {
            valid = {
              [facts.plan.id] = {
                path = "test:workflow-one",
                blueprint = facts.plan,
              },
            },
          }
        end,
      },
    }))
    _G.pipeline = previous_pipeline
    local materialization_result = with_test_locks(function()
      return testing.run_fake(materializer, {
        queue = "github-devloop-workflow.workflow_materialization_tick",
        payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      })
    end)
    local terminal = nil
    for _, raised in ipairs(materialization_result.raises) do
      if raised.queue == "github-proxy.github_issue_comment_request"
        and tostring(raised.payload and raised.payload.body or ""):find(
          'state="done"',
          1,
          true
        ) ~= nil then
        terminal = raised.payload
      end
    end

    t.is_true(terminal ~= nil)
    t.is_true(terminal.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
    t.eq(#facts.issues[repo .. "#issue/" .. tostring(child_issue)].comments, 0)
  end,
}
