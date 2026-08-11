local fixtures = require("tests.materialize_reconcile_helpers")
local base_ids = fixtures.base_ids
local core = fixtures.core
local digest = fixtures.digest
local materialization = fixtures.materialization
local materialize_reconcile = fixtures.materialize_reconcile
local marker = fixtures.marker
local testing = fixtures.testing
local t = fixtures.t
local repo = fixtures.repo
local origin_issue = fixtures.origin_issue
local origin = fixtures.origin
local blueprint = fixtures.blueprint
local blueprint_marker = fixtures.blueprint_marker
local comment = fixtures.comment
local issue = fixtures.issue
local event = fixtures.event
local generated_spec = fixtures.generated_spec
local build_entry = fixtures.build_entry
local generated_comment = fixtures.generated_comment
local created_comment = fixtures.created_comment
local label_projection_comment = fixtures.label_projection_comment
local comments_with = fixtures.comments_with
local parent_created_comment = fixtures.parent_created_comment
local parent_intent_comment = fixtures.parent_intent_comment
local child_body = fixtures.child_body
local child_body_with_blueprint = fixtures.child_body_with_blueprint
local raise_capture = fixtures.raise_capture
local run_with = fixtures.run_with
local only_queue = fixtures.only_queue

local predecessor_commit = "1111111111111111111111111111111111111111"
local verified_tree = "2222222222222222222222222222222222222222"

local function feature_blueprint()
  return core.default_catalog.records()[1].blueprint
end

local function feature_history(extra_comments)
  local plan = feature_blueprint()
  local plan_digest = digest.blueprint_digest(plan)
  local selected, blueprint_err = marker.build_blueprint_marker(origin, plan.id, plan_digest)
  t.is_nil(blueprint_err)
  local comments = { comment(selected) }
  local predecessor = nil
  for index, child_issue in ipairs({ 108, 109 }) do
    local slot = plan.steps[index]
    local predecessor_digest = materialize_reconcile._private.predecessor_ref_digest(predecessor)
    local spec = { title = slot.title, body = "Generated " .. slot.id .. " child." }
    local entry = materialization.write_generated_entry(origin, plan_digest, slot, predecessor_digest, spec)
    local built, err = marker.build_materialization_marker(
      origin,
      entry.blueprint_digest,
      entry.slot,
      entry.predecessor_ref_digest,
      entry.gen_contract_digest,
      entry.gen_spec_digest,
      entry.child_dedup,
      tostring(child_issue),
      "created"
    )
    t.is_nil(err)
    comments[#comments + 1] = comment(built)
    predecessor = {
      proposal_id = base_ids.proposal_id(repo, child_issue),
      source_ref = { kind = "external", ref = repo .. "#issue/" .. tostring(child_issue) },
    }
  end
  for _, extra in ipairs(extra_comments or {}) do
    comments[#comments + 1] = extra
  end
  return plan, comments
end

local function already_satisfied_ports(overrides)
  local selected = overrides or {}
  return {
    child_statuses = {
      ["108"] = "result_ready",
      ["109"] = "fatal",
    },
    child_current_implementation_refusal = function(child_ref)
      if tostring(child_ref.issue_number) == "109" then
        return { reason = "already-satisfied", implementation_version = "ready/production-slice", attempt = 1 }
      end
      return nil
    end,
    child_merged_pr = function(child_ref)
      if tostring(child_ref.issue_number) == "108" then
        return { state = "MERGED", merge_commit_sha = predecessor_commit }
      end
      return nil
    end,
    current_checkout = selected.current_checkout or function()
      return { head_sha = "3333333333333333333333333333333333333333", tree = verified_tree, clean = true }
    end,
    is_ancestor = selected.is_ancestor or function()
      return true
    end,
    run_local_iteration = selected.run_local_iteration or function()
      return {
        exit_code = 0,
        stdout = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n",
        stderr = "",
      }
    end,
  }
end

local function merge_tables(left, right)
  local merged = {}
  for key, value in pairs(left or {}) do merged[key] = value end
  for key, value in pairs(right or {}) do merged[key] = value end
  return merged
end

local function capture_logs(fn)
  local captured = {}
  local old_log = log
  log = {
    info = function(message) captured[#captured + 1] = tostring(message) end,
    warn = function(message) captured[#captured + 1] = tostring(message) end,
    error = function(message) captured[#captured + 1] = tostring(message) end,
  }
  local ok, result = pcall(fn)
  log = old_log
  if not ok then
    error(result, 0)
  end
  return result, captured
end

return {
  test_child_fatal_writes_blocked_terminal = function()
    local first_spec = generated_spec("first")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
      }),
      child_statuses = { ["108"] = "fatal" },
    })
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find("terminal:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="created"', 1, true) == nil)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="child-fatal-first"', 1, true) ~= nil)
  end,

  test_stale_child_fatal_terminal_rederives_merged_children_and_completes = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local blocked_terminal, terminal_err = marker.build_terminal_marker(origin, "blocked", "child-fatal-second")
    t.is_nil(terminal_err)
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
        comment(blocked_terminal),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
    })

    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
  end,

  test_non_first_no_changes_child_writes_blocked_terminal_with_why = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = {
          status = "fatal",
          detail = { impl_failed_reason = "no-changes" },
        },
      },
    })
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find("terminal:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="child-fatal-second-no-changes"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) == nil)
  end,

  test_all_slots_ready_writes_done_terminal = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
    })
    t.eq(#raised, 1)
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="all-slots-result-ready"', 1, true) ~= nil)
  end,

  test_verified_already_satisfied_production_slice_completes_on_the_next_poll = function()
    local plan, initial_comments = feature_history()
    local first = run_with(merge_tables(already_satisfied_ports(), {
      blueprint = plan,
      current = issue(initial_comments),
    }))

    local verification_comments = only_queue(first, "github-proxy.github_issue_comment_request")
    t.eq(#verification_comments, 1)
    t.is_true(verification_comments[1].payload.body:find("verified-satisfaction:v1", 1, true) ~= nil)
    t.is_true(verification_comments[1].payload.body:find("terminal:v1", 1, true) == nil)

    local _, verified_comments = feature_history({ comment(verification_comments[1].payload.body) })
    local second = run_with(merge_tables(already_satisfied_ports(), {
      blueprint = plan,
      current = issue(verified_comments),
    }))

    local terminal_comments = only_queue(second, "github-proxy.github_issue_comment_request")
    t.eq(#terminal_comments, 1)
    t.is_true(terminal_comments[1].payload.body:find('state="done"', 1, true) ~= nil)
    t.is_true(terminal_comments[1].payload.body:find(
      'reason_code="all-slots-result-ready-delivered-by-' .. predecessor_commit .. '"',
      1,
      true
    ) ~= nil)
  end,

  test_raw_already_satisfied_remains_fatal_when_verification_does_not_pass = function()
    local plan, comments = feature_history()
    local ports = already_satisfied_ports({
      run_local_iteration = function()
        return {
          exit_code = 1,
          stdout = "FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC\n",
          stderr = "",
        }
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find("verified-satisfaction:v1", 1, true) == nil)
  end,

  test_already_satisfied_without_predecessor_ancestry_remains_fatal = function()
    local plan, comments = feature_history()
    local ports = already_satisfied_ports({
      is_ancestor = function()
        return false
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find("verified-satisfaction:v1", 1, true) == nil)
  end,

  test_checkout_observer_error_does_not_publish_blocked_terminal = function()
    local plan, comments = feature_history()
    local ports = already_satisfied_ports({
      current_checkout = function()
        return nil
      end,
    })
    local raised, logs = capture_logs(function()
      return run_with(merge_tables(ports, {
        blueprint = plan,
        current = issue(comments),
      }))
    end)

    local text = table.concat(logs, "\n")
    t.eq(#raised, 0)
    t.is_true(text:find("tag=ORIGIN_FAILURE", 1, true) ~= nil)
    t.is_true(text:find("error_class=verified-satisfaction-checkout-result-invalid", 1, true) ~= nil)
    t.is_true(text:find("skip-stale", 1, true) == nil)
  end,

  test_verified_fact_is_discarded_when_checkout_tree_changes_before_publication = function()
    local plan, comments = feature_history()
    local reads = 0
    local ports = already_satisfied_ports({
      current_checkout = function()
        reads = reads + 1
        return {
          head_sha = "3333333333333333333333333333333333333333",
          tree = reads < 3 and verified_tree or "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          clean = true,
        }
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(reads, 3)
    t.eq(#raised, 0)
  end,

  test_stale_tree_fact_does_not_project_the_child_to_result_ready = function()
    local plan = feature_blueprint()
    local stale = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = predecessor_commit,
      tree = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(stale) })
    local ports = already_satisfied_ports({
      run_local_iteration = function()
        return {
          exit_code = 1,
          stdout = "FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC\n",
          stderr = "",
        }
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) == nil)
  end,

  test_stale_predecessor_fact_does_not_project_the_child_to_result_ready = function()
    local plan = feature_blueprint()
    local stale = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      tree = verified_tree,
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(stale) })
    local ports = already_satisfied_ports({
      run_local_iteration = function()
        return {
          exit_code = 1,
          stdout = "FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC\n",
          stderr = "",
        }
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('state="done"', 1, true) == nil)
  end,

  test_verified_fact_is_discarded_when_checkout_changes_before_done_publication = function()
    local plan = feature_blueprint()
    local verified = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = predecessor_commit,
      tree = verified_tree,
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(verified) })
    local reads = 0
    local ports = already_satisfied_ports({
      current_checkout = function()
        reads = reads + 1
        return {
          head_sha = "3333333333333333333333333333333333333333",
          tree = reads == 1 and verified_tree or "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          clean = true,
        }
      end,
    })
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(reads, 2)
    t.eq(#raised, 0)
  end,

  test_checkout_observer_error_during_done_validation_is_not_stale = function()
    local plan = feature_blueprint()
    local verified = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = predecessor_commit,
      tree = verified_tree,
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(verified) })
    local reads = 0
    local ports = already_satisfied_ports({
      current_checkout = function()
        reads = reads + 1
        if reads == 1 then
          return {
            head_sha = "3333333333333333333333333333333333333333",
            tree = verified_tree,
            clean = true,
          }
        end
        return nil
      end,
    })
    local raised, logs = capture_logs(function()
      return run_with(merge_tables(ports, {
        blueprint = plan,
        current = issue(comments),
      }))
    end)

    local text = table.concat(logs, "\n")
    t.eq(reads, 2)
    t.eq(#raised, 0)
    t.is_true(text:find("tag=ORIGIN_FAILURE", 1, true) ~= nil)
    t.is_true(text:find("error_class=verified-satisfaction-checkout-result-invalid", 1, true) ~= nil)
    t.is_true(text:find("skip-stale", 1, true) == nil)
  end,

  test_verified_fact_is_discarded_when_predecessor_changes_before_done_publication = function()
    local plan = feature_blueprint()
    local verified = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = predecessor_commit,
      tree = verified_tree,
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(verified) })
    local reads = 0
    local ports = already_satisfied_ports()
    ports.child_merged_pr = function(child_ref)
      if tostring(child_ref.issue_number) ~= "108" then
        return nil
      end
      reads = reads + 1
      return {
        state = "MERGED",
        merge_commit_sha = reads == 1
          and predecessor_commit
          or "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      }
    end
    local raised = run_with(merge_tables(ports, {
      blueprint = plan,
      current = issue(comments),
    }))

    t.eq(reads, 2)
    t.eq(#raised, 0)
  end,

  test_verified_fact_ancestry_error_records_origin_failure = function()
    local plan = feature_blueprint()
    local verified = assert(marker.build_verified_satisfaction_marker({
      origin = origin,
      workflow = plan.id,
      blueprint_digest = digest.blueprint_digest(plan),
      slot = "production-slice",
      child_issue = "109",
      predecessor_commit = predecessor_commit,
      tree = verified_tree,
      verification = "PASS",
    }))
    local _, comments = feature_history({ comment(verified) })
    local ports = already_satisfied_ports({
      is_ancestor = function()
        error("github-devloop-workflow: verified-satisfaction-ancestry-command-failed: git ancestry check exited 128")
      end,
    })
    local raised, logs = capture_logs(function()
      return run_with(merge_tables(ports, {
        blueprint = plan,
        current = issue(comments),
      }))
    end)

    local text = table.concat(logs, "\n")
    t.eq(#raised, 0)
    t.is_true(text:find("tag=ORIGIN_FAILURE", 1, true) ~= nil)
    t.is_true(text:find("error_class=verified-satisfaction-ancestry-command-failed", 1, true) ~= nil)
  end,

  test_impossible_ledger_writes_error_terminal = function()
    local spec = generated_spec("second")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("second", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec, 109),
      }),
    })
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="error"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('reason_code="impossible-ledger"', 1, true) ~= nil)
  end,

  test_done_terminal_releases_and_closes_only_after_marker_and_label_are_visible = function()
    local first_spec = generated_spec("first")
    local second_spec = generated_spec("second")
    local first_ref = { kind = "external", ref = repo .. "#issue/108" }
    local released = nil
    local closed = nil
    local first = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
        created_comment("second", materialize_reconcile._private.predecessor_ref_digest({ source_ref = first_ref }), second_spec, 109),
      }),
      child_statuses = {
        ["108"] = "result_ready",
        ["109"] = "result_ready",
      },
      release_done_claim = function(_core, release_repo, release_issue, release_origin)
        released = {
          repo = release_repo,
          issue = release_issue,
          origin = release_origin,
        }
        return true
      end,
      close_done_origin = function()
        closed = true
        return true
      end,
    })
    local terminal_comments = only_queue(first, "github-proxy.github_issue_comment_request")
    t.eq(#terminal_comments, 1)
    t.eq(released, nil)
    t.eq(closed, nil)

    local projection = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
      }),
      release_done_claim = function()
        released = true
        return true
      end,
      close_done_origin = function()
        closed = true
        return true
      end,
    })
    t.eq(#only_queue(projection, "github-proxy.github_issue_label_request"), 1)
    t.eq(released, nil)
    t.eq(closed, nil)

    local completed = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
      }, { labels = { "fkst-dev:merged" } }),
      release_done_claim = function(_core, release_repo, release_issue, release_origin)
        released = {
          repo = release_repo,
          issue = release_issue,
          origin = release_origin,
        }
        return true
      end,
      close_done_origin = function(_core, close_repo, close_issue, close_origin)
        closed = {
          repo = close_repo,
          issue = close_issue,
          origin = close_origin,
        }
        return true
      end,
    })
    t.eq(#completed, 0)
    t.eq(released.repo, repo)
    t.eq(released.issue, origin_issue)
    t.eq(released.origin, origin)
    t.eq(closed.repo, repo)
    t.eq(closed.issue, origin_issue)
    t.eq(closed.origin, origin)
  end,
}
