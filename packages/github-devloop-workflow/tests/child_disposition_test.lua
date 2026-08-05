local base_ids = require("devloop.base_ids")
local child_disposition = require("child_disposition")
local child_result = require("core.child_result")
local devloop_entity = require("devloop.entity")
local digest = require("core.digest")
local frontier = require("core.frontier")
local marker = require("core.marker")
local materialization = require("core.materialization")
local m_builders = require("devloop.markers.builders")
local saga = require("workflow.saga")
local testing = require("testkit_internal.testing")
local t = fkst.test

local repo = "owner/repo"
local origin_issue = 42
local child_issue = 108
local successor_issue = 109
local child_pr = 110
local origin = base_ids.proposal_id(repo, origin_issue)
local child_proposal = base_ids.proposal_id(repo, child_issue)
local child_version = "ready/workflow-child/2026-08-05T00-00-00Z"

local plan = {
  schema = "fkst.workflow.v1",
  id = "workflow-one",
  version = "1",
  summary = "One bounded step.",
  applies_when = "The origin requests the bounded step.",
  steps = {
    {
      id = "first",
      title = "First step",
      content = {
        kind = "static",
        intent = "Implement the first step.",
      },
    },
  },
}

local blueprint_digest = digest.blueprint_digest(plan)
local child_spec = { title = "First step", body = "Implement the first step." }
local created_entry = materialization.created_entry(
  origin,
  blueprint_digest,
  plan.steps[1],
  materialization.EMPTY_PREDECESSOR_REF_DIGEST,
  child_spec,
  child_issue
)

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-05T00:00:00Z",
  }
end

local function lineage_body(issue_number)
  local lineage, err = marker.build_lineage_header(origin, blueprint_digest, "first")
  t.is_nil(err)
  return lineage .. "\n\nWorkflow child #" .. tostring(issue_number) .. "."
end

local function origin_entity()
  local blueprint_marker, blueprint_err = marker.build_blueprint_marker(origin, plan.id, blueprint_digest)
  t.is_nil(blueprint_err)
  local materialization_marker, materialization_err = marker.build_materialization_marker(
    origin,
    created_entry.blueprint_digest,
    created_entry.slot,
    created_entry.predecessor_ref_digest,
    created_entry.gen_contract_digest,
    created_entry.gen_spec_digest,
    created_entry.child_dedup,
    created_entry.child_issue,
    created_entry.state
  )
  t.is_nil(materialization_err)
  return {
    number = origin_issue,
    state = "OPEN",
    body = "Workflow origin.",
    author_login = "human",
    comments = {
      trusted_comment(blueprint_marker),
      trusted_comment(materialization_marker),
    },
  }
end

local function child_entity(number)
  return {
    number = number,
    state = "OPEN",
    body = lineage_body(number),
    author_login = "fkst-test-bot",
    assignees = { "fkst-test-bot" },
    labels = {},
    comments = {},
  }
end

local function request_payload(disposition, fields)
  local extra = fields or {}
  return {
    schema = "github-devloop-workflow.child-disposition.v1",
    repo = repo,
    origin_issue_number = origin_issue,
    child_issue_number = child_issue,
    blueprint_digest = blueprint_digest,
    slot = "first",
    disposition = disposition,
    successor_source_ref = extra.successor_source_ref,
    reason_code = extra.reason_code,
    dedup_key = "workflow-child-disposition-test/" .. disposition,
    source_ref = base_ids.issue_source_ref(repo, child_issue),
  }
end

local function fake_deps(entities, prs)
  local closes = {}
  local receipts = {}
  local receipt_fact = nil
  local deps = {
    closes = closes,
    receipts = receipts,
    with_lock = function(_key, fn)
      return fn()
    end,
    read_issue = function(source_ref)
      local _repo, number = require("devloop.base").parse_issue_source_ref(source_ref)
      local entity = entities[tonumber(number)]
      if entity == nil then
        error("missing fake issue " .. tostring(number))
      end
      return entity
    end,
    read_pr = function(read_repo, pr_number)
      t.eq(read_repo, repo)
      local current = (prs or {})[tonumber(pr_number)]
      if current == nil then
        error("missing fake PR " .. tostring(pr_number))
      end
      return current
    end,
    write_enabled = function()
      return true
    end,
    read_receipt = function()
      return receipt_fact
    end,
    compare_and_swap_receipt = function(request, body, timeout)
      receipts[#receipts + 1] = {
        request = request,
        body = body,
        timeout = timeout,
      }
      if receipt_fact ~= nil then
        return false, nil, "receipt already exists"
      end
      receipt_fact = marker.parse_child_disposition_marker(
        body,
        request.origin,
        request.blueprint_digest,
        request.slot,
        tostring(request.child_issue_number)
      )
      t.is_true(type(receipt_fact) == "table")
      receipt_fact.commit_sha = string.rep("a", 40)
      return true, receipt_fact.commit_sha, nil
    end,
    issue_close = function(close_repo, issue_number, disposition, timeout)
      closes[#closes + 1] = {
        repo = close_repo,
        issue_number = issue_number,
        disposition = disposition,
        timeout = timeout,
      }
      entities[tonumber(issue_number)].state = "CLOSED"
      return { exit_code = 0, stdout = "closed" }
    end,
    invalidate_entity_after_write = function() end,
  }
  return deps
end

local function child_pr_comments(merged)
  local comments = {
    m_builders.pr_delegation_marker(
      child_proposal,
      "github-devloop/pr/" .. repo .. "/" .. tostring(child_pr),
      child_pr,
      child_version,
      "g1"
    ),
  }
  if merged then
    comments[#comments + 1] = m_builders.merged_marker(
      require("core"),
      child_proposal,
      child_pr,
      child_version,
      "0123456789abcdef0123456789abcdef01234567"
    )
  end
  return { trusted_comment(table.concat(comments, "\n")) }
end

local request_spec = {
  consumes = { "workflow_child_disposition_request" },
  produces = {},
  stall_window = "30s",
}

local function run_request(deps, payload)
  local dept = saga.department(request_spec, child_disposition.request_handlers({ deps = deps }))
  return testing.run_fake(dept, {
    queue = "github-devloop-workflow.workflow_child_disposition_request",
    payload = payload,
  })
end

local function run_request_failure(deps, payload)
  local dept = saga.department(request_spec, child_disposition.request_handlers({ deps = deps }))
  return testing.run_fake_expecting_failure(dept, {
    queue = "github-devloop-workflow.workflow_child_disposition_request",
    payload = payload,
  })
end

local function disposition_fact(deps)
  return child_disposition.current_fact(deps, {
    repo = repo,
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = "first",
    child_issue = tostring(child_issue),
  })
end

local function install_receipt_cas(deps)
  local committed = nil
  local writes = 0
  deps.read_receipt = function()
    return committed
  end
  deps.compare_and_swap_receipt = function(request, body)
    writes = writes + 1
    if committed ~= nil then
      return false, nil, "receipt already exists"
    end
    committed = marker.parse_child_disposition_marker(
      body,
      request.origin,
      request.blueprint_digest,
      request.slot,
      tostring(request.child_issue_number)
    )
    t.is_true(type(committed) == "table")
    committed.commit_sha = string.rep("a", 40)
    return true, committed.commit_sha, nil
  end
  deps.write_receipt = function()
    error("unconditional receipt write used", 0)
  end
  return {
    fact = function() return committed end,
    writes = function() return writes end,
  }
end

local tests = {
  test_satisfied_operation_records_fact_closes_child_and_completes_parent = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    local result = run_request(deps, request_payload("satisfied"))
    t.eq(#result.raises, 0)
    t.eq(#deps.receipts, 1)
    local pending_fact = marker.parse_child_disposition_marker(
      deps.receipts[1].body,
      origin,
      blueprint_digest,
      "first",
      tostring(child_issue)
    )
    t.eq(pending_fact.disposition, "satisfied")

    t.eq(#deps.closes, 1)
    t.eq(deps.closes[1].disposition.kind, "completed")
    t.eq(entities[child_issue].state, "CLOSED")

    local fact = disposition_fact(deps)
    local status = child_result.child_result_status({
      has_merged_marker = function() return false end,
      github_closed_with_merged_pr = function() return false end,
      current_obligation_disposition = function() return fact end,
    }, {
      proposal_id = base_ids.proposal_id(repo, child_issue),
      source_ref = base_ids.issue_source_ref(repo, child_issue),
    })
    local decision = frontier.compute_frontier(plan, {
      first = {
        state = "created",
        child_ref = { issue_number = child_issue },
      },
    }, function()
      return status
    end)
    t.eq(decision.action, "terminal")
    t.eq(decision.state, "done")
  end,

  test_transferred_operation_requires_same_lineage_successor_and_closes_as_duplicate = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
      [successor_issue] = child_entity(successor_issue),
    }
    local deps = fake_deps(entities)
    local result = run_request(deps, request_payload("transferred", {
      successor_source_ref = base_ids.issue_source_ref(repo, successor_issue),
    }))
    t.eq(#result.raises, 0)
    t.eq(#deps.receipts, 1)
    t.eq(#deps.closes, 1)
    t.eq(deps.closes[1].disposition.kind, "duplicate")
    t.eq(deps.closes[1].disposition.duplicate_of, successor_issue)
    local fact = disposition_fact(deps)
    t.eq(fact.successor_source_ref.ref, repo .. "#issue/" .. tostring(successor_issue))
  end,

  test_undeliverable_operation_records_why_and_preserves_blocked_terminal = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    local result = run_request(deps, request_payload("undeliverable", {
      reason_code = "premise-refuted",
    }))
    t.eq(#result.raises, 0)
    t.eq(#deps.receipts, 1)
    t.eq(deps.closes[1].disposition.kind, "not_planned")
    local fact = disposition_fact(deps)
    local decision = frontier.compute_frontier(plan, {
      first = {
        state = "created",
        child_ref = { issue_number = child_issue },
      },
    }, function()
      return "fatal", { fatal_reason = fact.reason_code }
    end)
    t.eq(decision.state, "blocked")
    t.eq(decision.reason_code, "child-fatal-first-premise-refuted")
  end,

  test_request_rejects_child_or_successor_outside_the_created_slot_lineage = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
      [successor_issue] = child_entity(successor_issue),
    }
    entities[successor_issue].body = marker.build_lineage_header(origin, blueprint_digest, "other-slot")
    local deps = fake_deps(entities)
    local failed = run_request_failure(deps, request_payload("transferred", {
      successor_source_ref = base_ids.issue_source_ref(repo, successor_issue),
    }))
    t.is_true(tostring(failed.failure.error):find("successor-lineage-mismatch", 1, true) ~= nil)
    t.eq(#deps.closes, 0)
  end,

  test_request_rejects_a_child_claimed_by_another_actor = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    entities[child_issue].assignees = { "human" }
    local deps = fake_deps(entities)
    local failed = run_request_failure(deps, request_payload("satisfied"))
    t.is_true(tostring(failed.failure.error):find("child-claim-not-self", 1, true) ~= nil)
    t.eq(#deps.closes, 0)
  end,

  test_competing_dispositions_preserve_first_persisted_receipt = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    run_request(deps, request_payload("satisfied"))
    local failed = run_request_failure(deps, request_payload("undeliverable", {
      reason_code = "premise-refuted",
    }))

    t.is_true(tostring(failed.failure.error):find("conflicting-child-disposition", 1, true) ~= nil)
    t.eq(#deps.receipts, 1)
    t.eq(#deps.closes, 1)
    t.eq(disposition_fact(deps).disposition, "satisfied")
  end,

  test_process_loss_after_receipt_cas_replays_without_a_second_write = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    local receipt_cas = install_receipt_cas(deps)
    local close = deps.issue_close
    local close_attempts = 0
    deps.issue_close = function(...)
      close_attempts = close_attempts + 1
      if close_attempts == 1 then
        error("simulated-process-loss-after-receipt-cas", 0)
      end
      return close(...)
    end

    local first = run_request_failure(deps, request_payload("satisfied"))
    t.is_true(tostring(first.failure.error):find("simulated-process-loss-after-receipt-cas", 1, true) ~= nil)
    t.eq(receipt_cas.writes(), 1)
    t.eq(receipt_cas.fact().disposition, "satisfied")
    t.eq(#deps.closes, 0)

    run_request(deps, request_payload("satisfied"))
    t.eq(receipt_cas.writes(), 1)
    t.eq(close_attempts, 2)
    t.eq(#deps.closes, 1)
    t.eq(entities[child_issue].state, "CLOSED")
  end,

  test_conflicting_replay_cannot_replace_the_committed_slot_receipt = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    local receipt_cas = install_receipt_cas(deps)
    local close_attempts = 0
    deps.issue_close = function()
      close_attempts = close_attempts + 1
      error("simulated-process-loss-after-receipt-cas", 0)
    end

    local first = run_request_failure(deps, request_payload("satisfied"))
    t.is_true(tostring(first.failure.error):find("simulated-process-loss-after-receipt-cas", 1, true) ~= nil)
    t.eq(receipt_cas.writes(), 1)

    local conflicting = run_request_failure(deps, request_payload("undeliverable", {
      reason_code = "premise-refuted",
    }))
    t.is_true(tostring(conflicting.failure.error):find("conflicting-child-disposition", 1, true) ~= nil)
    t.eq(receipt_cas.writes(), 1)
    t.eq(receipt_cas.fact().disposition, "satisfied")
    t.eq(close_attempts, 1)
  end,

  test_production_receipt_adapter_uses_one_create_only_slot_ref = function()
    t.is_true(type(child_disposition.production_receipt_adapter) == "function")
    local tree_sha = string.rep("1", 40)
    local first_sha = string.rep("2", 40)
    local second_sha = string.rep("3", 40)
    local remote_sha = nil
    local next_sha = first_sha
    local files = {}
    local messages = {}
    local pushes = {}
    local adapter = child_disposition.production_receipt_adapter({
      commands = {
        git_ls_remote_ref = function(_remote, ref)
          return {
            stdout = remote_sha and (remote_sha .. "\t" .. ref .. "\n") or "",
            stderr = "",
            exit_code = 0,
          }
        end,
        git_fetch_ref = function()
          return { stdout = "", stderr = "", exit_code = 0 }
        end,
        git_cat_file_pretty = function(sha)
          return {
            stdout = "tree " .. tree_sha .. "\n\n" .. assert(messages[sha]),
            stderr = "",
            exit_code = 0,
          }
        end,
        git_commit_object_message = require("devloop.commands").git_commit_object_message,
        git_rev_parse_ref_tree = function()
          return { stdout = tree_sha .. "\n", stderr = "", exit_code = 0 }
        end,
        git_commit_tree = function(actual_tree, parent_sha, message_file)
          t.eq(actual_tree, tree_sha)
          t.is_nil(parent_sha)
          messages[next_sha] = assert(files[message_file])
          return { stdout = next_sha .. "\n", stderr = "", exit_code = 0 }
        end,
        git_push_ref_update = function(_remote, sha, ref, lease)
          pushes[#pushes + 1] = { sha = sha, ref = ref, lease = lease }
          if remote_sha ~= nil then
            return { stdout = "", stderr = "non-fast-forward", exit_code = 1 }
          end
          remote_sha = sha
          return { stdout = "", stderr = "", exit_code = 0 }
        end,
      },
      file = {
        write = function(path, body)
          files[path] = body
        end,
      },
    })
    local expected = {
      repo = repo,
      origin = origin,
      blueprint_digest = blueprint_digest,
      slot = "first",
      child_issue = tostring(child_issue),
    }
    local satisfied_marker = assert(marker.build_child_disposition_marker({
      origin = origin,
      blueprint_digest = blueprint_digest,
      slot = "first",
      child_issue = tostring(child_issue),
      disposition = "satisfied",
    }))
    local created, created_sha = adapter.compare_and_swap(expected, satisfied_marker)
    t.eq(created, true)
    t.eq(created_sha, first_sha)
    t.eq(pushes[1].lease, false)

    next_sha = second_sha
    local conflicting_marker = assert(marker.build_child_disposition_marker({
      origin = origin,
      blueprint_digest = blueprint_digest,
      slot = "first",
      child_issue = tostring(child_issue),
      disposition = "undeliverable",
      reason_code = "premise-refuted",
    }))
    local changed = adapter.compare_and_swap(expected, conflicting_marker)
    t.eq(changed, false)
    t.eq(pushes[2].ref, pushes[1].ref)
    t.eq(pushes[2].lease, false)

    local committed = adapter.read(expected)
    t.eq(committed.disposition, "satisfied")
    t.eq(committed.commit_sha, first_sha)
    t.eq(remote_sha, first_sha)
  end,

  test_request_rejects_transfer_after_trusted_child_merge = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
      [successor_issue] = child_entity(successor_issue),
    }
    entities[child_issue].comments = child_pr_comments(true)
    local deps = fake_deps(entities)
    local failed = run_request_failure(deps, request_payload("transferred", {
      successor_source_ref = base_ids.issue_source_ref(repo, successor_issue),
    }))

    t.is_true(tostring(failed.failure.error):find("child-already-merged", 1, true) ~= nil)
    t.eq(#deps.receipts, 0)
    t.eq(#deps.closes, 0)
    local status = child_result.child_result_status({
      has_merged_marker = function() return true end,
      current_obligation_disposition = function()
        return disposition_fact(deps)
      end,
    }, {
      proposal_id = child_proposal,
      source_ref = base_ids.issue_source_ref(repo, child_issue),
    })
    local decision = frontier.compute_frontier(plan, {
      first = {
        state = "created",
        child_ref = { issue_number = child_issue },
      },
    }, function()
      return status
    end)
    t.eq(decision.action, "terminal")
    t.eq(decision.state, "done")
  end,

  test_request_rejects_undeliverable_after_native_pr_merge = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    entities[child_issue].comments = child_pr_comments(false)
    local failed = run_request_failure(fake_deps(entities, {
      [child_pr] = {
        number = child_pr,
        state = "MERGED",
        merged_at = "2026-08-05T00:05:00Z",
        comments = {},
      },
    }), request_payload("undeliverable", {
      reason_code = "premise-refuted",
    }))

    t.is_true(tostring(failed.failure.error):find("child-already-merged", 1, true) ~= nil)
  end,

  test_operation_persists_receipt_and_closes_inside_merge_lane_before_late_merge = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
      [successor_issue] = child_entity(successor_issue),
    }
    entities[child_issue].comments = child_pr_comments(false)
    local prs = {
      [child_pr] = {
        number = child_pr,
        state = "OPEN",
        comments = {},
      },
    }
    local deps = fake_deps(entities, prs)
    local held = {}
    local merge_lock = devloop_entity.merge_lane_lock_key(repo)
    deps.with_lock = function(key, fn)
      t.is_nil(held[key])
      held[key] = true
      local ok, result = pcall(fn)
      held[key] = nil
      if not ok then
        error(result)
      end
      return result
    end
    local compare_and_swap_receipt = deps.compare_and_swap_receipt
    deps.compare_and_swap_receipt = function(request, body, timeout)
      t.eq(held[merge_lock], true)
      return compare_and_swap_receipt(request, body, timeout)
    end
    local close = deps.issue_close
    deps.issue_close = function(...)
      t.eq(held[merge_lock], true)
      return close(...)
    end

    local result = run_request(deps, request_payload("transferred", {
      successor_source_ref = base_ids.issue_source_ref(repo, successor_issue),
    }))
    t.eq(#result.raises, 0)
    t.eq(#deps.closes, 1)
    t.eq(disposition_fact(deps).disposition, "transferred")

    prs[child_pr].state = "MERGED"
    prs[child_pr].merged_at = "2026-08-05T00:05:00Z"
    local status = child_result.child_result_status({
      has_merged_marker = function() return true end,
      current_obligation_disposition = function()
        local fact = disposition_fact(deps)
        fact.successor_ref = base_ids.issue_source_ref(repo, successor_issue)
        return fact
      end,
      transferred_child_status = function()
        return "running", { disposition = "transferred" }
      end,
    }, {
      proposal_id = child_proposal,
      source_ref = base_ids.issue_source_ref(repo, child_issue),
    })
    local decision = frontier.compute_frontier(plan, {
      first = {
        state = "created",
        child_ref = { issue_number = child_issue },
      },
    }, function()
      return status
    end)
    t.eq(decision.action, "wait")
    t.eq(decision.why, "children-not-yet-ready")
  end,

  test_completed_operation_replay_is_idempotent_after_origin_closes = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    local deps = fake_deps(entities)
    run_request(deps, request_payload("satisfied"))
    t.eq(#deps.closes, 1)
    t.eq(#deps.receipts, 1)

    entities[origin_issue].state = "CLOSED"
    run_request(deps, request_payload("satisfied"))

    t.eq(#deps.closes, 1)
    t.eq(#deps.receipts, 1)
  end,

  test_completed_transfer_replay_is_idempotent_after_linked_pr_merges = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
      [successor_issue] = child_entity(successor_issue),
    }
    entities[child_issue].comments = child_pr_comments(false)
    local prs = {
      [child_pr] = {
        number = child_pr,
        state = "OPEN",
        comments = {},
      },
    }
    local deps = fake_deps(entities, prs)
    local payload = request_payload("transferred", {
      successor_source_ref = base_ids.issue_source_ref(repo, successor_issue),
    })
    run_request(deps, payload)
    t.eq(#deps.closes, 1)
    t.eq(#deps.receipts, 1)

    prs[child_pr].state = "MERGED"
    prs[child_pr].merged_at = "2026-08-05T00:05:00Z"
    run_request(deps, payload)

    t.eq(#deps.closes, 1)
    t.eq(#deps.receipts, 1)
  end,

  test_raw_closed_child_cannot_be_retrofitted_by_the_operation = function()
    local entities = {
      [origin_issue] = origin_entity(),
      [child_issue] = child_entity(child_issue),
    }
    entities[child_issue].state = "CLOSED"
    local deps = fake_deps(entities)
    local failed = run_request_failure(deps, request_payload("satisfied"))
    t.is_true(tostring(failed.failure.error):find("raw-closed-child", 1, true) ~= nil)
    t.eq(#deps.closes, 0)
  end,
}

return tests
