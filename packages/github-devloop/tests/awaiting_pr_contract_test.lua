local entity_lib = require("devloop.entity")
local h = require("tests.devloop_core_helpers")
local core = h.core
local contract_time = require("contract.time")
local devloop_logging = require("devloop.logging")
local pr_partition_contract = require("devloop.restart.issue.pr_partition_contract")
local t = h.t

local has_value = require("testkit_internal.values").has_value

local function table_by_state()
  local by_state = {}
  for _, row in ipairs(core.restart_transition_table()) do
    by_state[row.from_state] = row
  end
  return by_state
end

return {
  test_awaiting_pr_declares_typed_child_dependency = function()
    local row = table_by_state()["awaiting-pr"]
    local dependency = row.child_dependency
    t.is_true(type(dependency) == "table")
    t.eq(dependency.kind, "delegated-child-pr")
    t.eq(dependency.identity.source, "pr-delegation:v1")
    t.eq(dependency.identity.pr_proposal_id, "pr-delegation.pr_proposal_id")
    t.eq(dependency.identity.pr_number, "pr-delegation.pr_number")
    t.eq(dependency.identity.repository, "parent.repo")
    t.eq(dependency.predicate, "pr_partition_contract.child_terminal_predicate")
    t.eq(dependency.unknown_state_outcome, "child-state-unrecognized")
    local saw_typed_fact = false
    for _, required in ipairs(row.required_facts or {}) do
      saw_typed_fact = saw_typed_fact or required.family == "child-pr-dependency"
    end
    t.is_true(saw_typed_fact)
  end,

  test_pr_partition_child_state_fact_preserves_unknown_state_and_exact_identity = function()
    local comments = {{
      author_login = "fkst-test-bot",
      body = '<!-- fkst:github-devloop:state:v1 proposal="github-devloop/issue/owner/repo/42" state="vendor-paused" version="v1" -->',
    }}
    local fact = pr_partition_contract.child_state_fact({
      repo = "owner/repo",
      number = 7,
      comments = comments,
    }, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = "v1",
      pr_proposal_id = "github-devloop/pr/owner/repo/7",
      pr_number = 7,
    }, "owner/repo")
    t.eq(fact.state, nil)
    t.eq(fact.raw_state, "vendor-paused")
    t.eq(fact.pr_proposal_id, "github-devloop/pr/owner/repo/7")
    t.eq(fact.pr_number, 7)
    t.eq(fact.identity_valid, true)
    t.eq(pr_partition_contract.child_terminal_predicate("merged"), true)
    t.eq(pr_partition_contract.child_terminal_predicate("reviewing"), false)
    t.eq(pr_partition_contract.child_terminal_predicate("vendor-paused"), false)
    local wrong_observed_child = pr_partition_contract.child_state_fact({
      repo = "owner/repo",
      number = 8,
      comments = comments,
    }, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = "v1",
      pr_proposal_id = "github-devloop/pr/owner/repo/7",
      pr_number = 7,
    }, "owner/repo")
    t.eq(wrong_observed_child.identity_valid, false)
    t.eq(wrong_observed_child.observed_repo, "owner/repo")
    t.eq(wrong_observed_child.observed_pr_number, 8)
    t.eq(wrong_observed_child.raw_state, nil)
    local cross_repo = pr_partition_contract.child_state_fact({
      repo = "other/repo",
      number = 7,
      comments = comments,
    }, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = "v1",
      pr_proposal_id = "github-devloop/pr/owner/repo/7",
      pr_number = 7,
    }, "owner/repo")
    t.eq(cross_repo.identity_valid, false)
    local unversioned = pr_partition_contract.child_state_fact({
      repo = "owner/repo",
      number = 7,
      comments = {{
        author_login = "fkst-test-bot",
        body = '<!-- fkst:github-devloop:state:v1 proposal="github-devloop/issue/owner/repo/42" state="merged" -->',
      }},
    }, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      pr_proposal_id = "github-devloop/pr/owner/repo/7",
      pr_number = 7,
    }, "owner/repo")
    t.eq(unversioned, nil)
  end,

  test_awaiting_pr_restart_row_declares_child_workflow_boundary = function()
    local row = table_by_state()["awaiting-pr"]
    t.is_true(row ~= nil)
    t.eq(row.driving_queue, "devloop_observe_redrive")
    t.eq(row.on_timeout.queue, "devloop_observe_redrive")
    t.eq(row.liveness_class_id, "child_workflow_wait")
    t.eq(row.watchdog.mode, "live-defer")
    t.eq(row.defer.kind, "child_workflow_wait")
    t.eq(row.defer.live_marker, "state:v1")
    t.eq(row.defer.delegation_marker, "pr-delegation:v1")
    t.eq(row.actionable_epoch.source, "child_workflow_wait:v1")
    t.eq(row.liveness_contract.signal.family, "state")
    t.eq(row.liveness_contract.signal.resolver, "child-state")
    t.eq(row.liveness_contract.signal.surface, "pr-comment-stream")
    t.eq(row.payload_builder_symbol, nil)
    t.eq(row.responsibility_signature.receiver_kind, "pr-child-workflow")
    t.eq(row.responsibility_signature.state_kind, "gate")
    t.eq(row.responsibility_signature.output_postcondition_family, "parent_resume_from_child_state_terminal")
    t.eq(row.to_states[1], "merged")
    t.eq(row.to_states[2], "ready")
    t.eq(row.to_states[3], "blocked")
    t.eq(row.dedup_shape, "child-state-terminal/<proposal>/<version>/<pr>")
  end,

  test_forward_flip_wires_implementing_success_to_awaiting_pr = function()
    for _, row in ipairs(core.restart_transition_table()) do
      if row.from_state ~= "awaiting-pr" then
        t.eq(has_value(row.to_states, "awaiting-pr"), row.from_state == "implementing", row.from_state)
      end
    end
    t.eq(has_value(core.state_successors("implementing"), "awaiting-pr"), true)
    t.eq(has_value(core.state_successors("implementing"), "pr-open"), false)
  end,

  test_awaiting_pr_timeout_without_delegation_fails_loud_without_receipt = function()
    local row = table_by_state()["awaiting-pr"]
    local state = {
      state = "awaiting-pr",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/awaiting-pr/3",
      proposal_id = "github-devloop/issue/owner/repo/42",
      marker_created_at = "2026-06-03T01:02:03Z",
    }
    local raised = {}
    local original_log_raise = devloop_logging.log_raise
    devloop_logging.log_raise = function(_, _, queue, payload)
      table.insert(raised, { queue = queue, payload = payload })
    end
    local ok, err = pcall(function()
      core.maybe_timeout_redrive_from_table("observe_issue", {
        repo = "owner/repo",
        number = 42,
        source_ref = entity_lib.issue_source_ref("owner/repo", 42),
      }, state, row, {
        proposal_id = state.proposal_id,
        source_ref = entity_lib.issue_source_ref("owner/repo", 42),
        current = { comments = {} },
        current_pr = { comments = {} },
        now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-12-01T01:02:03Z"),
      })
    end)
    devloop_logging.log_raise = original_log_raise
    t.eq(ok, false)
    t.is_true(tostring(err):find("github-devloop: timeout-redrive-stuck:", 1, true) ~= nil)
    t.eq(#raised, 0)
  end,
}
