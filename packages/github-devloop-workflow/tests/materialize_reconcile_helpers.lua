local base_ids = require("devloop.base_ids")
local core = require("core")
local digest = require("core.digest")
local materialization = require("core.materialization")
local materialize_reconcile = require("materialize_reconcile")
local marker = require("core.marker")
local testing = require("testkit_internal.testing")
local t = fkst.test

local repo = "owner/repo"
local origin_issue = 42
local origin = base_ids.proposal_id(repo, origin_issue)

local function blueprint()
  return {
    schema = "fkst.workflow.v1",
    id = "workflow-one",
    version = "2026-07-02",
    summary = "A bounded workflow.",
    applies_when = "The origin issue asks for this workflow.",
    steps = {
      {
        id = "first",
        title = "First static issue",
        content = {
          kind = "static",
          intent = "Implement the first static step.",
        },
      },
      {
        id = "second",
        title = "Second generated issue",
        content = {
          kind = "generated",
          generator = "Use the predecessor result to write the next issue.",
        },
      },
    },
  }
end

local function blueprint_marker()
  local built, err = marker.build_blueprint_marker(origin, "workflow-one", digest.blueprint_digest(blueprint()))
  t.is_nil(err)
  return built
end

local function comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-07-02T00:00:00Z",
  }
end

local function issue(comments, fields)
  local extra = fields or {}
  return {
    title = "Workflow origin",
    body = extra.body or "Run the workflow.",
    state = extra.state or "OPEN",
    labels = extra.labels or {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    comments = comments or { comment(blueprint_marker()) },
    repo = repo,
    number = origin_issue,
  }
end

local function event()
  return {
    queue = "github-devloop-workflow.workflow_materialization_tick",
    payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
    ts = "2026-07-02T00:00:00Z",
  }
end

local function generated_spec(slot, body)
  return {
    title = slot == "second" and "Generated child issue" or "First static issue",
    body = body or (slot == "second" and "Generated follow-up body." or "Implement the first static step."),
  }
end

local function build_entry(slot_id, predecessor_ref_digest, spec, child_issue, state)
  local slot = slot_id == "second" and blueprint().steps[2] or blueprint().steps[1]
  local entry = materialization.write_generated_entry(origin, digest.blueprint_digest(blueprint()), slot, predecessor_ref_digest, spec)
  local built, err = marker.build_materialization_marker(
    origin,
    entry.blueprint_digest,
    entry.slot,
    entry.predecessor_ref_digest,
    entry.gen_contract_digest,
    entry.gen_spec_digest,
    entry.child_dedup,
    child_issue ~= nil and tostring(child_issue) or nil,
    state or "generated"
  )
  t.is_nil(err)
  return entry, built
end

local function generated_comment(slot_id, predecessor_ref_digest, spec)
  local _entry, built = build_entry(slot_id, predecessor_ref_digest, spec, nil, "generated")
  return comment(built)
end

local function created_comment(slot_id, predecessor_ref_digest, spec, child_issue)
  local _entry, built = build_entry(slot_id, predecessor_ref_digest, spec, child_issue, "created")
  return comment(built)
end

local function label_projection_comment(state, generation)
  local built, err = marker.build_label_projection_marker(origin, state, generation)
  t.is_nil(err)
  return comment(built)
end

local function comments_with(comments, extra)
  local out = {}
  for _, item in ipairs(comments or {}) do
    out[#out + 1] = item
  end
  out[#out + 1] = extra
  return out
end


local function parent_created_comment(entry, child_issue)
  return comment('<!-- fkst:github-proxy:issue-created:v1 dedup="' .. entry.child_dedup .. '" issue="' .. tostring(child_issue) .. '" -->')
end

local function parent_intent_comment(entry)
  return comment('<!-- fkst:github-proxy:issue-create-intent:v1 dedup="' .. entry.child_dedup .. '" -->')
end

local function child_body(slot_id, spec, child_dedup)
  local lineage = marker.build_lineage_header(origin, digest.blueprint_digest(blueprint()), slot_id)
  return lineage .. "\n\n" .. spec.body .. "\n\n<!-- fkst:github-proxy:issue-create:" .. child_dedup .. " -->"
end

local function child_body_with_blueprint(slot_id, spec, child_dedup, bp)
  local lineage = marker.build_lineage_header(origin, digest.blueprint_digest(bp or blueprint()), slot_id)
  return lineage .. "\n\n" .. spec.body .. "\n\n<!-- fkst:github-proxy:issue-create:" .. child_dedup .. " -->"
end

local function raise_capture(fn, lock)
  local old_with_lock = with_lock
  with_lock = lock or function(_key, locked)
    return locked()
  end
  local ok, result = pcall(fn)
  with_lock = old_with_lock
  if not ok then
    error(result, 0)
  end
  return result
end

local function run_with(fakes)
  local fake = fakes or {}
  local dept = require("workflow.saga").department({
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
        return fake.issues or { { number = origin_issue, title = "Workflow origin" } }
      end,
      read_issue = function(...)
        if type(fake.read_issue) == "function" then
          return fake.read_issue(...)
        end
        return fake.current or issue()
      end,
      verify_issue_claim = fake.verify_issue_claim or function()
        return fake.claim ~= false
      end,
      dependency_gate = fake.dependency_gate or function()
        return {
          ok = true,
          kind = "satisfied",
          reason = "satisfied",
          unmet = {},
        }
      end,
      child_status = function(_core, child_ref)
        local key = tostring(child_ref.issue_number or child_ref.proposal_id or "")
        local result = (fake.child_statuses or {})[key] or fake.child_status or "running"
        if type(result) == "table" then
          return result.status, result.detail
        end
        return result
      end,
      child_current_implementation_refusal = fake.child_current_implementation_refusal,
      child_merged_pr = fake.child_merged_pr,
      child_resolved_ref = fake.child_resolved_ref,
      current_checkout = fake.current_checkout,
      is_ancestor = fake.is_ancestor,
      run_local_iteration = fake.run_local_iteration,
      load_blueprints = function()
        if fake.workflow_missing then
          return { valid = {} }
        end
        local selected = fake.blueprint or blueprint()
        return {
          valid = {
            [selected.id] = {
              path = "test-workflow.json",
              blueprint = selected,
            },
          },
        }
      end,
      spawn_codex = fake.spawn_codex,
      spawn_codex_sync = fake.spawn_codex_sync,
      content_fetch = fake.content_fetch,
      release_done_claim = fake.release_done_claim or function()
        return true
      end,
      close_done_origin = fake.close_done_origin or function()
        return true
      end,
      read_created_issue = fake.read_created_issue,
      search_created_issue = fake.search_created_issue or function()
        return nil
      end,
    },
  }))
  local result = raise_capture(function()
    return testing.run_fake(dept, event())
  end, fake.with_lock)
  return result.raises
end

local function only_queue(raised, queue)
  local out = {}
  for _, item in ipairs(raised or {}) do
    if item.queue == queue then
      out[#out + 1] = item
    end
  end
  return out
end

return {
  base_ids = base_ids,
  core = core,
  digest = digest,
  materialization = materialization,
  materialize_reconcile = materialize_reconcile,
  marker = marker,
  testing = testing,
  t = t,
  repo = repo,
  origin_issue = origin_issue,
  origin = origin,
  blueprint = blueprint,
  blueprint_marker = blueprint_marker,
  comment = comment,
  issue = issue,
  event = event,
  generated_spec = generated_spec,
  build_entry = build_entry,
  generated_comment = generated_comment,
  created_comment = created_comment,
  label_projection_comment = label_projection_comment,
  comments_with = comments_with,
  parent_created_comment = parent_created_comment,
  parent_intent_comment = parent_intent_comment,
  child_body = child_body,
  child_body_with_blueprint = child_body_with_blueprint,
  raise_capture = raise_capture,
  run_with = run_with,
  only_queue = only_queue,
}
