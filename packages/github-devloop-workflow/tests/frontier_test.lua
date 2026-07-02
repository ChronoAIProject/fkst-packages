local frontier = require("core.frontier")
local t = fkst.test

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
        title = "First",
        content = {
          kind = "static",
          intent = "Do the first step.",
        },
      },
      {
        id = "second",
        title = "Second",
        content = {
          kind = "generated",
          generator = "Generate the second step.",
        },
      },
    },
  }
end

local function created(slot, child)
  return {
    state = "created",
    child_ref = child or {
      proposal_id = "child-" .. slot,
      source_ref = {
        kind = "external",
        ref = "owner/repo#issue/" .. slot,
      },
    },
  }
end

local function generated()
  return {
    state = "generated",
  }
end

local function status_map(map)
  return function(child)
    return map[child.proposal_id] or "running"
  end
end

local tests = {
  test_slot_one_is_immediately_materializable = function()
    local action = frontier.compute_frontier(blueprint(), {}, status_map({}))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "first")
    t.is_nil(action.predecessor)
  end,

  test_predecessor_running_waits = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "running" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "predecessor-running")
  end,

  test_predecessor_merged_materializes_next_slot = function()
    local predecessor = { proposal_id = "child-first" }
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", predecessor),
    }, status_map({ ["child-first"] = "result_ready" }))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "second")
    t.eq(action.predecessor, predecessor)
  end,

  test_fatal_materialized_child_blocks_workflow = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "fatal" }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "blocked")
    t.eq(action.reason_code, "child-fatal")
  end,

  test_recoverable_materialized_child_waits = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "recoverable" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "child-recoverable")
  end,

  test_all_created_and_merged_is_done = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
      second = created("second", { proposal_id = "child-second" }),
    }, status_map({
      ["child-first"] = "result_ready",
      ["child-second"] = "result_ready",
    }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "done")
  end,

  test_corrupt_blueprint_is_terminal_error = function()
    local action = frontier.compute_frontier({ schema = "wrong" }, {}, status_map({}))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "corrupt-blueprint")
  end,

  test_impossible_ledger_is_terminal_error = function()
    local action = frontier.compute_frontier(blueprint(), {
      unknown_slot = { state = "created", child_ref = { proposal_id = "x" } },
    }, status_map({}))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "impossible-ledger")
  end,

  test_created_before_predecessor_is_impossible_ledger = function()
    local action = frontier.compute_frontier(blueprint(), {
      second = created("second", { proposal_id = "child-second" }),
    }, status_map({ ["child-second"] = "running" }))
    t.eq(action.action, "terminal")
    t.eq(action.state, "error")
    t.eq(action.reason_code, "impossible-ledger")
  end,

  test_generated_without_created_is_still_frontier = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = generated(),
    }, status_map({}))
    t.eq(action.action, "materialize")
    t.eq(action.slot, "first")
    t.is_nil(action.predecessor)
  end,

  test_unknown_status_waits_without_materializing_next = function()
    local action = frontier.compute_frontier(blueprint(), {
      first = created("first", { proposal_id = "child-first" }),
    }, status_map({ ["child-first"] = "unknown" }))
    t.eq(action.action, "wait")
    t.eq(action.why, "predecessor-unknown")
  end,
}

return tests
