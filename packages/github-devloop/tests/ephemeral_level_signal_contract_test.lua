local t = fkst.test

local expected_ephemeral = {
  sync_scan = {
    module = "departments.sync_scan.main",
    queues = { "devloop_branch_tick" },
  },
  rollup_scan = {
    module = "departments.rollup_scan.main",
    queues = { "devloop_branch_tick" },
  },
  pr_freshness_scan = {
    module = "departments.pr_freshness_scan.main",
    queues = { "devloop_branch_tick" },
  },
  intake_scan = {
    module = "departments.intake_scan.main",
    queues = { "devloop_intake_tick" },
  },
  intake_probe = {
    module = "departments.intake_probe.main",
    queues = { "devloop_intake_probe_tick" },
  },
  merge = {
    module = "departments.merge.main",
    queues = { "devloop_merge_queue_tick" },
  },
  observability = {
    module = "departments.observability.main",
    queues = { "devloop_observe_tick" },
  },
  liveness_scan = {
    module = "departments.liveness_scan.main",
    queues = { "devloop_liveness_tick" },
  },
  ensure_repo = {
    module = "departments.ensure_repo.main",
    queues = { "devloop_ensure_repo_tick" },
  },
}

local department_modules = {
  "departments.consensus_result.main",
  "departments.dead_letter.main",
  "departments.decompose.main",
  "departments.ensure_repo.main",
  "departments.fix.main",
  "departments.implement.main",
  "departments.intake_judge.main",
  "departments.intake_probe.main",
  "departments.intake_scan.main",
  "departments.liveness_scan.main",
  "departments.loop.main",
  "departments.merge.main",
  "departments.observability.main",
  "departments.observe_issue.main",
  "departments.observe_pr.main",
  "departments.open_pr.main",
  "departments.pr_freshness_scan.main",
  "departments.reconcile.main",
  "departments.review_loop.main",
  "departments.review_meta.main",
  "departments.review_pr.main",
  "departments.review_result.main",
  "departments.rollup_merge.main",
  "departments.rollup_scan.main",
  "departments.sync_conflict.main",
  "departments.sync_scan.main",
}

local fact_queues = {
  "consensus.proposal",
  "consensus.consensus_reached",
  "consensus.consensus_converge",
  "devloop_ready",
  "devloop_open_pr",
  "devloop_reviewing",
  "devloop_fixing",
  "devloop_review_meta",
  "devloop_decompose",
  "devloop_merge_ready",
  "devloop_reconcile",
  "devloop_review_reconcile",
  "devloop_fix_reconcile",
  "devloop_timeout_reconcile",
  "devloop_sync_conflict",
  "devloop_rollup_ready",
  "dead_letter",
}

local function set_from_list(list)
  local set = {}
  for _, value in ipairs(list or {}) do
    set[value] = true
  end
  return set
end

local function load_spec(module_name)
  local module = require(module_name)
  t.is_true(type(module) == "table", module_name .. " must return a module table")
  t.is_true(type(module.spec) == "table", module_name .. " must expose M.spec")
  return module.spec
end

return {
  test_level_signals_are_ephemeral = function()
    for dept, expected in pairs(expected_ephemeral) do
      local spec = load_spec(expected.module)
      local ephemeral = set_from_list(spec.ephemeral)
      for _, queue in ipairs(expected.queues) do
        t.is_true(ephemeral[queue] == true, dept .. " must mark " .. queue .. " ephemeral")
      end
    end
  end,

  test_fact_queues_are_never_ephemeral = function()
    local forbidden = set_from_list(fact_queues)
    for _, module_name in ipairs(department_modules) do
      local spec = load_spec(module_name)
      for _, queue in ipairs(spec.ephemeral or {}) do
        t.eq(forbidden[queue], nil)
        t.is_true(tostring(queue):match("^github%-proxy%.github_.*_request$") == nil)
      end
    end
  end,
}
