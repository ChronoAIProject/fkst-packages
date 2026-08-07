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

local function first_generated_entry(spec)
  return materialization.write_generated_entry(
    origin,
    digest.blueprint_digest(blueprint()),
    blueprint().steps[1],
    materialization.EMPTY_PREDECESSOR_REF_DIGEST,
    spec
  )
end

return {
  test_blueprint_digest_mismatch_replay_repairs_missing_terminal_label_projection = function()
    local changed_blueprint = blueprint()
    changed_blueprint.version = "2026-07-26"
    local current_labels = { "fkst-dev:enabled", "fkst-dev:thinking" }

    local first = run_with({
      blueprint = changed_blueprint,
      current = issue({ comment(blueprint_marker()) }, { labels = current_labels }),
    })
    local terminal_comments = only_queue(first, "github-proxy.github_issue_comment_request")
    t.eq(#terminal_comments, 1)
    t.eq(#only_queue(first, "github-proxy.github_issue_label_request"), 0)
    t.is_true(terminal_comments[1].payload.body:find('state="error"', 1, true) ~= nil)
    t.is_true(terminal_comments[1].payload.body:find('reason_code="blueprint-digest-mismatch"', 1, true) ~= nil)

    local projection = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
      }, { labels = current_labels }),
    })
    local projection_comments = only_queue(projection, "github-proxy.github_issue_comment_request")
    t.eq(#projection_comments, 1)
    t.eq(#only_queue(projection, "github-proxy.github_issue_label_request"), 0)
    local projection_fact = marker.parse_label_projection_marker(projection_comments[1].payload.body, origin)
    t.eq(projection_fact.state, "blocked")
    t.eq(projection_fact.generation, 1)

    local replay = run_with({
      current = issue({
        comment(blueprint_marker()),
        comment(terminal_comments[1].payload.body),
        comment(projection_comments[1].payload.body),
      }, { labels = current_labels }),
    })
    local label_requests = only_queue(replay, "github-proxy.github_issue_label_request")
    t.eq(#only_queue(replay, "github-proxy.github_issue_comment_request"), 0)
    t.eq(#label_requests, 1)
    t.eq(label_requests[1].payload.add_labels[1], "fkst-dev:blocked")
    t.eq(label_requests[1].payload.marker_guard.expected.state, "blocked")
    t.eq(label_requests[1].payload.marker_guard.expected.generation, "1")
  end,

  test_static_frontier_raises_issue_create_directly_without_origin_spec = function()
    local raised = run_with()
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.parent, origin_issue)
    t.eq(raised[1].payload.parent_comment_target.repo, repo)
    t.eq(raised[1].payload.parent_comment_target.issue_number, origin_issue)
    t.is_true(raised[1].payload.body:find("fkst:github-devloop-workflow:lineage:v1", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find("Implement the first static step.", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find("fkst:github-devloop-workflow:materialization:v1", 1, true) == nil)
  end,

  test_unsatisfied_origin_dependency_holds_before_child_materialization = function()
    local gate_calls = 0
    local generator_calls = 0
    local raised = run_with({
      dependency_gate = function(gate_repo, gate_issue_number)
        gate_calls = gate_calls + 1
        t.eq(gate_repo, repo)
        t.eq(gate_issue_number, origin_issue)
        return {
          kind = "waiting",
          reason = "waiting-on-dependency",
          unmet = { 41 },
        }
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return { exit_code = 0, stdout = '{"title":"Unexpected","body":"Unexpected."}' }
      end,
    })

    t.eq(gate_calls, 1)
    t.eq(generator_calls, 0)
    t.eq(#raised, 0)
  end,

  test_unresolvable_origin_dependency_fails_closed_before_child_materialization = function()
    local raised = run_with({
      dependency_gate = function()
        return {
          kind = "unavailable",
          reason = "blockedby-truncated",
          unmet = { origin_issue },
        }
      end,
    })

    t.eq(#raised, 0)
  end,

  test_origin_dependency_release_materializes_child_on_next_poll = function()
    local gate = {
      kind = "waiting",
      reason = "waiting-on-dependency",
      unmet = { 41 },
    }
    local function dependency_gate()
      return gate
    end

    local held = run_with({ dependency_gate = dependency_gate })
    t.eq(#held, 0)

    gate = {
      kind = "satisfied",
      reason = "satisfied",
      unmet = {},
    }
    local released = run_with({ dependency_gate = dependency_gate })
    local creates = only_queue(released, "github-proxy.github_issue_create_request")
    t.eq(#released, 1)
    t.eq(#creates, 1)
    t.eq(creates[1].payload.parent, origin_issue)
  end,

  -- Regression (found by real dogfood): a GENERATED first slot has no prior
  -- child; its predecessor result is the ORIGIN idea itself, so it must read the
  -- origin via content_fetch and generate — NOT error with missing-predecessor-result.
  test_generated_first_slot_reads_origin_not_missing_predecessor = function()
    local gen_bp = {
      schema = "fkst.workflow.v1",
      id = "workflow-one",
      version = "1",
      summary = "Generated first slot.",
      applies_when = "The origin idea.",
      steps = {
        { id = "first", title = "Analyze", content = { kind = "generated", generator = "Analyze the origin idea." } },
      },
    }
    local gen_marker = marker.build_blueprint_marker(origin, "workflow-one", digest.blueprint_digest(gen_bp))
    local fetched_ref = nil
    local raised = run_with({
      blueprint = gen_bp,
      current = issue({ comment(gen_marker) }),
      content_fetch = function(predecessor_ref, _ctx)
        fetched_ref = predecessor_ref and (predecessor_ref.source_ref or predecessor_ref) or nil
        return "runtime-cache:origin-content"
      end,
      spawn_codex = function()
        return { exit_code = 0, stdout = '{"title":"Architecture analysis","body":"Components and data flow."}' }
      end,
    })
    -- materializes (raises child create), not a terminal missing-predecessor error
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.parent_comment_target.repo, repo)
    t.eq(raised[1].payload.parent_comment_target.issue_number, origin_issue)
    t.eq(raised[1].payload.title, "Architecture analysis")
    t.is_true(raised[1].payload.body:find("Components and data flow.", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find("missing-predecessor", 1, true) == nil)
    -- content_fetch was called with the ORIGIN's source_ref (predecessor is the origin, not nil)
    t.is_true(fetched_ref ~= nil)
    t.is_true(tostring(fetched_ref.ref or fetched_ref):find("#issue/" .. tostring(origin_issue), 1, true) ~= nil)
  end,

  test_generated_fact_raises_one_issue_create_request_with_lineage = function()
    local spec = generated_spec("first")
    local entry = build_entry("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec)
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        generated_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec),
      }),
    })
    local creates = only_queue(raised, "github-proxy.github_issue_create_request")
    local comments = only_queue(raised, "github-proxy.github_issue_comment_request")
    t.eq(#raised, 1)
    t.eq(#creates, 1)
    t.eq(#comments, 0)
    t.eq(creates[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(creates[1].payload.dedup_key, entry.child_dedup)
    t.eq(creates[1].payload.parent, origin_issue)
    t.eq(creates[1].payload.parent_comment_target.repo, repo)
    t.eq(creates[1].payload.parent_comment_target.issue_number, origin_issue)
    t.is_true(creates[1].payload.body:find("fkst:github-devloop-workflow:lineage:v1", 1, true) ~= nil)
    t.is_true(creates[1].payload.body:find("Implement the first static step.", 1, true) ~= nil)
  end,

  test_parent_issue_created_marker_writes_created_materialization = function()
    local spec = generated_spec("first")
    local entry = build_entry("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec)
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        generated_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, spec),
        parent_created_comment(entry, 108),
      }),
    })
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_comment_request")
    t.is_nil(raised[1].payload.replace_marker)
    t.is_true(raised[1].payload.body:find("fkst:github-devloop-workflow:blueprint:v1", 1, true) == nil)
    t.is_true(raised[1].payload.body:find('state="created"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('child_issue="108"', 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find(spec.title, 1, true) == nil)
    t.is_true(raised[1].payload.body:find(spec.body, 1, true) == nil)
  end,

  test_predecessor_merged_materializes_next_generated_slot = function()
    local first_spec = generated_spec("first")
    local first_pred = materialization.EMPTY_PREDECESSOR_REF_DIGEST
    local pred_ref = { kind = "external", ref = repo .. "#issue/108" }
    local predecessor_ref_digest = materialize_reconcile._private.predecessor_ref_digest({ source_ref = pred_ref })
    local seen_fetch = nil
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", first_pred, first_spec, 108),
      }),
      child_statuses = { ["108"] = "result_ready" },
      content_fetch = function(ref)
        seen_fetch = ref.source_ref.ref
        return "runtime-cache:workflow/predecessor"
      end,
      spawn_codex = function(prompt)
        t.is_true(prompt:find("runtime-cache:workflow/predecessor", 1, true) ~= nil)
        return {
          exit_code = 0,
          stdout = '{"title":"Generated child issue","body":"Generated follow-up body."}',
        }
      end,
    })
    t.eq(seen_fetch, repo .. "#issue/108")
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(raised[1].payload.parent_comment_target.repo, repo)
    t.eq(raised[1].payload.parent_comment_target.issue_number, origin_issue)
    t.is_true(raised[1].payload.body:find("Generated follow-up body.", 1, true) ~= nil)
    t.is_true(raised[1].payload.body:find('predecessor_ref_digest="' .. predecessor_ref_digest .. '"', 1, true) == nil)
  end,

  test_recovered_blocked_origin_advances_projection_generation_before_repairing_labels = function()
    local first_spec = generated_spec("first")
    local first_pred = materialization.EMPTY_PREDECESSOR_REF_DIGEST
    local blocked_terminal, terminal_err = marker.build_terminal_marker(origin, "blocked", "child-fatal-first")
    t.is_nil(terminal_err)
    local base_comments = {
      comment(blueprint_marker()),
      created_comment("first", first_pred, first_spec, 108),
      comment(blocked_terminal),
      label_projection_comment("blocked", 1),
    }

    local recovered = run_with({
      current = issue(base_comments, { labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }),
      child_statuses = { ["108"] = "running" },
    })
    local recovered_comments = only_queue(recovered, "github-proxy.github_issue_comment_request")
    t.eq(#recovered_comments, 1)
    t.eq(#only_queue(recovered, "github-proxy.github_issue_label_request"), 0)
    local active_projection = marker.parse_label_projection_marker(recovered_comments[1].payload.body, origin)
    t.eq(active_projection.state, "thinking")
    t.eq(active_projection.generation, 2)

    local active_visible_comments = comments_with(base_comments, comment(recovered_comments[1].payload.body))
    local active = run_with({
      current = issue(active_visible_comments, { labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }),
      child_statuses = { ["108"] = "running" },
    })
    local active_labels = only_queue(active, "github-proxy.github_issue_label_request")
    t.eq(#active_labels, 1)
    t.eq(active_labels[1].payload.add_labels[1], "fkst-dev:thinking")
    t.eq(active_labels[1].payload.marker_guard.expected.generation, "2")

    local reblocked = run_with({
      current = issue(active_visible_comments, { labels = { "fkst-dev:enabled", "fkst-dev:blocked" } }),
      child_statuses = { ["108"] = "fatal" },
    })
    local reblocked_comments = only_queue(reblocked, "github-proxy.github_issue_comment_request")
    t.eq(#reblocked_comments, 1)
    t.eq(#only_queue(reblocked, "github-proxy.github_issue_label_request"), 0)
    local blocked_projection = marker.parse_label_projection_marker(reblocked_comments[1].payload.body, origin)
    t.eq(blocked_projection.state, "blocked")
    t.eq(blocked_projection.generation, 3)

    local repaired = run_with({
      current = issue(
        comments_with(active_visible_comments, comment(reblocked_comments[1].payload.body)),
        { labels = { "fkst-dev:enabled", "fkst-dev:thinking" } }
      ),
      child_statuses = { ["108"] = "fatal" },
    })
    local blocked_labels = only_queue(repaired, "github-proxy.github_issue_label_request")
    t.eq(#blocked_labels, 1)
    t.eq(blocked_labels[1].payload.add_labels[1], "fkst-dev:blocked")
    t.eq(blocked_labels[1].payload.marker_guard.expected.generation, "3")
    t.is_true(active_labels[1].payload.dedup_key ~= blocked_labels[1].payload.dedup_key)
  end,

  test_wait_when_predecessor_running_raises_nothing = function()
    local first_spec = generated_spec("first")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, first_spec, 108),
      }),
      child_statuses = { ["108"] = "running" },
    })
    t.eq(#raised, 0)
  end,

  test_existing_child_search_records_created_without_second_create = function()
    local existing_spec = generated_spec("first")
    local generated_entry = first_generated_entry(existing_spec)
    local generator_calls = 0
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
      }),
      search_created_issue = function(_repo, child_dedup)
        t.eq(child_dedup, generated_entry.child_dedup)
        return {
          number = 108,
          title = existing_spec.title,
          body = child_body_with_blueprint("first", existing_spec, child_dedup, blueprint()),
          author_login = "fkst-test-bot",
        }
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return {
          exit_code = 0,
          stdout = '{"title":"Divergent generated issue","body":"Divergent regenerated body."}',
        }
      end,
    })
    local creates = only_queue(raised, "github-proxy.github_issue_create_request")
    local comments = only_queue(raised, "github-proxy.github_issue_comment_request")
    t.eq(generator_calls, 0)
    t.eq(#creates, 0)
    t.eq(#comments, 1)
    t.is_nil(comments[1].payload.replace_marker)
    t.is_true(comments[1].payload.body:find('state="created"', 1, true) ~= nil)
    t.is_true(comments[1].payload.body:find('child_issue="108"', 1, true) ~= nil)
    t.is_true(comments[1].payload.body:find(existing_spec.title, 1, true) == nil)
    t.is_true(comments[1].payload.body:find(existing_spec.body, 1, true) == nil)
  end,

  test_parent_issue_created_marker_before_generator_records_created_without_codex_or_second_create = function()
    local existing_spec = generated_spec("first")
    local planned_entry = first_generated_entry(existing_spec)
    local generator_calls = 0
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        parent_created_comment(planned_entry, 108),
      }),
      read_created_issue = function(_repo, issue_number)
        t.eq(issue_number, "108")
        return {
          number = 108,
          title = existing_spec.title,
          body = child_body("first", existing_spec, planned_entry.child_dedup),
          author_login = "fkst-test-bot",
        }
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return {
          exit_code = 0,
          stdout = '{"title":"Divergent generated issue","body":"Divergent regenerated body."}',
        }
      end,
    })
    local creates = only_queue(raised, "github-proxy.github_issue_create_request")
    local comments = only_queue(raised, "github-proxy.github_issue_comment_request")
    t.eq(generator_calls, 0)
    t.eq(#creates, 0)
    t.eq(#comments, 1)
    t.is_nil(comments[1].payload.replace_marker)
    t.is_true(comments[1].payload.body:find('state="created"', 1, true) ~= nil)
    t.is_true(comments[1].payload.body:find('child_issue="108"', 1, true) ~= nil)
    t.is_true(comments[1].payload.body:find(existing_spec.title, 1, true) == nil)
    t.is_true(comments[1].payload.body:find(existing_spec.body, 1, true) == nil)
  end,

  test_parent_issue_created_marker_unreadable_waits_without_codex_or_second_create = function()
    local existing_spec = generated_spec("first")
    local planned_entry = first_generated_entry(existing_spec)
    local generator_calls = 0
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        parent_created_comment(planned_entry, 108),
      }),
      read_created_issue = function()
        return nil
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return {
          exit_code = 0,
          stdout = '{"title":"Divergent generated issue","body":"Divergent regenerated body."}',
        }
      end,
    })
    t.eq(generator_calls, 0)
    t.eq(#only_queue(raised, "github-proxy.github_issue_create_request"), 0)
    t.eq(#only_queue(raised, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_parent_issue_create_intent_waits_without_codex_or_second_create = function()
    local existing_spec = generated_spec("first")
    local planned_entry = first_generated_entry(existing_spec)
    local generator_calls = 0
    local search_calls = 0
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        parent_intent_comment(planned_entry),
      }),
      search_created_issue = function(_repo, child_dedup)
        search_calls = search_calls + 1
        t.eq(child_dedup, planned_entry.child_dedup)
        return nil
      end,
      spawn_codex = function()
        generator_calls = generator_calls + 1
        return {
          exit_code = 0,
          stdout = '{"title":"Divergent generated issue","body":"Divergent regenerated body."}',
        }
      end,
    })
    t.eq(search_calls, 1)
    t.eq(generator_calls, 0)
    t.eq(#only_queue(raised, "github-proxy.github_issue_create_request"), 0)
    t.eq(#only_queue(raised, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_second_run_with_created_ledger_is_noop = function()
    local stored_spec = generated_spec("first")
    local raised = run_with({
      current = issue({
        comment(blueprint_marker()),
        created_comment("first", materialization.EMPTY_PREDECESSOR_REF_DIGEST, stored_spec, 108),
      }),
    })
    t.eq(#only_queue(raised, "github-proxy.github_issue_create_request"), 0)
    t.eq(#only_queue(raised, "github-proxy.github_issue_comment_request"), 0)
  end,

}
