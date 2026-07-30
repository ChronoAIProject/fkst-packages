local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local capacity = require("core.intake_capacity")
local base_ids = require("devloop.base_ids")
local claims = require("devloop.claims")
local marker_builders = require("devloop.markers.builders")
local operator_commands = require("devloop.operator_commands")
local testing = require("testkit_internal.testing")
local admission_department = require("departments.admission.main")

local REPO = "owner/repo"
local OWNER = "fkst-test-bot"

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, field in pairs(value) do
    result[copy(key)] = copy(field)
  end
  return result
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = OWNER,
    created_at = created_at or "2026-07-16T00:00:00Z",
  }
end

local function proposal_id(number)
  return base_ids.proposal_id(REPO, number)
end

local function decision_comment(number, decision)
  return trusted_comment(marker_builders.intake_decision_marker(
    proposal_id(number),
    decision,
    "intake/" .. proposal_id(number) .. "/v1",
    "standard"
  ))
end

local function state_comment(number, state, version, created_at)
  return trusted_comment(core.state_marker(
    proposal_id(number),
    state,
    version or (proposal_id(number) .. "/2026-07-16T00-00-00Z")
  ), created_at)
end

local function reintake_command(id, created_at)
  return {
    id = id,
    body = "fkst: reintake",
    author_login = OWNER,
    created_at = created_at or "2026-07-16T00:00:02Z",
  }
end

local function command_response(command, outcome, created_at)
  local fact = assert(operator_commands.operator_command_fact({ command }, "reintake"))
  return trusted_comment(
    operator_commands.operator_command_marker(fact, outcome, "reintake"),
    created_at or "2026-07-16T00:00:03Z"
  )
end

local function issue(number, fields)
  local selected = fields or {}
  return {
    number = number,
    title = selected.title or "Issue " .. tostring(number),
    body = selected.body or "",
    updated_at = selected.updated_at or "2026-07-16T00:00:00Z",
    state = selected.state or "OPEN",
    assignees = copy(selected.assignees or {}),
    labels = copy(selected.labels or {}),
    comments = copy(selected.comments or {}),
    author_login = selected.author_login or OWNER,
  }
end

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if tonumber(value) == tonumber(expected) then
      return true
    end
  end
  return false
end

local function active_issue(current)
  return capacity.issue_occupies_capacity(REPO, current)
end

local function new_world(max_inflight)
  local world = {
    max_inflight = max_inflight,
    issues = {},
    grant = nil,
    next_sha = 1,
    writes = {},
    successful_cas = 0,
    before_next_cas = nil,
    fail_next_cas = false,
  }

  function world:add(current)
    self.issues[tonumber(current.number)] = copy(current)
  end

  function world:current(number)
    return copy(assert(self.issues[tonumber(number)], "missing issue " .. tostring(number)))
  end

  function world:active_claim_count()
    local count = 0
    for _, current in pairs(self.issues) do
      if claims.issue_claim_state(current.assignees, OWNER, current.labels) == "self"
        and active_issue(current) then
        count = count + 1
      end
    end
    return count
  end

  function world:claim(number)
    local current = assert(self.issues[tonumber(number)])
    current.assignees = { OWNER }
    table.insert(self.writes, { kind = "claim", issue_number = tonumber(number) })
    t.is_true(self:active_claim_count() <= self.max_inflight)
  end

  function world:ports(runtime_root)
    return {
      runtime_root = runtime_root,
      max_inflight = function()
        return self.max_inflight
      end,
      write_enabled = function()
        return true
      end,
      owner = function()
        return OWNER
      end,
      list_open_claim_numbers = function(repo, owner)
        t.eq(repo, REPO)
        t.eq(owner, OWNER)
        local numbers = {}
        for number, current in pairs(self.issues) do
          if tostring(current.state or ""):upper() == "OPEN"
            and claims.issue_claim_state(current.assignees, OWNER, current.labels) == "self" then
            table.insert(numbers, number)
          end
        end
        table.sort(numbers)
        return numbers
      end,
      read_issue = function(repo, number)
        t.eq(repo, REPO)
        return self:current(number)
      end,
      read_grant = function(repo, owner)
        t.eq(repo, REPO)
        t.eq(owner, OWNER)
        return copy(self.grant)
      end,
      compare_and_swap_grant = function(repo, owner, expected_sha, record)
        t.eq(repo, REPO)
        t.eq(owner, OWNER)
        if self.before_next_cas ~= nil then
          local hook = self.before_next_cas
          self.before_next_cas = nil
          hook()
        end
        if self.fail_next_cas then
          self.fail_next_cas = false
          table.insert(self.writes, {
            kind = "cas-failed",
            runtime_root = runtime_root,
            expected_sha = expected_sha,
          })
          return false, nil
        end
        local current_sha = self.grant and self.grant.sha or nil
        if current_sha ~= expected_sha then
          table.insert(self.writes, {
            kind = "cas-conflict",
            runtime_root = runtime_root,
            expected_sha = expected_sha,
          })
          return false, nil
        end
        local sha = string.format("%040x", self.next_sha)
        self.next_sha = self.next_sha + 1
        self.grant = copy(record)
        self.grant.sha = sha
        t.is_true(#(record.holders or {}) <= self.max_inflight)
        self.successful_cas = self.successful_cas + 1
        table.insert(self.writes, {
          kind = "cas",
          runtime_root = runtime_root,
          holders = copy(record.holders),
          reintake_reservations = copy(record.reintake_reservations),
          sha = sha,
        })
        return true, sha
      end,
      release_claim_if_self = function(repo, number, owner, reason)
        t.eq(repo, REPO)
        t.eq(owner, OWNER)
        local current = assert(self.issues[tonumber(number)])
        if claims.issue_claim_state(current.assignees, OWNER, current.labels) ~= "self" then
          return false
        end
        current.assignees = {}
        table.insert(self.writes, {
          kind = "release",
          issue_number = tonumber(number),
          reason = reason,
        })
        t.is_true(self:active_claim_count() <= self.max_inflight)
        return true
      end,
    }
  end

  function world:release_order()
    local order = {}
    for _, write in ipairs(self.writes) do
      if write.kind == "release" then
        table.insert(order, write.issue_number)
      end
    end
    return order
  end

  return world
end

local function authorize(controller, world, number)
  return controller.authorize(REPO, number, world:current(number), proposal_id(number))
end

local function owner_event(number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = REPO,
      number = number,
      updated_at = "2026-07-16T00:00:00Z",
      dedup_key = REPO .. "#issue#" .. tostring(number),
      source_ref = {
        kind = "external",
        ref = REPO .. "#issue/" .. tostring(number),
      },
    },
  }
end

local function owner_department(world, controller)
  return admission_department.make_department({
    capacity = controller,
    claims = {
      claim_admission_inputs = function()
        return {}
      end,
      claim_admission_precheck = function()
        return "needs-claim", "owner-side integration fixture"
      end,
      claim_issue_for_management = function(_core, _dept, repo, number)
        t.eq(repo, REPO)
        world:claim(number)
        return true
      end,
      with_current_claim_admission_epoch = function(_detail, fn)
        return true, fn()
      end,
    },
    read_current_issue = function(source_ref)
      local number = tonumber(tostring(source_ref.ref):match("#issue/(%d+)$"))
      return REPO, number, world:current(number), nil
    end,
  })
end

return {
  test_two_eligible_events_share_one_intake_slot = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(41))
    world:add(issue(42))
    local controller = capacity.new(world:ports("/runtime/a"))

    local first = authorize(controller, world, 41)
    if first then world:claim(41) end
    local second = authorize(controller, world, 42)
    if second then world:claim(42) end

    t.eq(first, true)
    t.eq(second, false)
    t.eq(world:active_claim_count(), 1)
    t.eq(#world.grant.holders, 1)
    t.eq(world.grant.holders[1], 41)
  end,

  test_two_runtime_roots_linearize_on_the_same_remote_grant = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(51))
    world:add(issue(52))
    local runtime_a = capacity.new(world:ports("/runtime/a"))
    local runtime_b = capacity.new(world:ports("/runtime/b"))
    local result_b = nil

    world.before_next_cas = function()
      result_b = authorize(runtime_b, world, 52)
      if result_b then world:claim(52) end
    end
    local result_a = authorize(runtime_a, world, 51)
    if result_a then world:claim(51) end

    t.eq(result_a, false)
    t.eq(result_b, true)
    t.eq(world.successful_cas, 1)
    t.eq(world:active_claim_count(), 1)
    t.eq(world.grant.holders[1], 52)
  end,

  test_restart_reuses_grant_after_claim_before_candidate_delivery = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(61))
    local before_restart = capacity.new(world:ports("/runtime/before-restart"))

    local granted = authorize(before_restart, world, 61)
    t.eq(granted, true)
    world:claim(61)
    local successful_cas_before_restart = world.successful_cas

    local after_restart = capacity.new(world:ports("/runtime/after-restart"))
    local replay_granted = authorize(after_restart, world, 61)

    t.eq(replay_granted, true)
    t.eq(world.successful_cas, successful_cas_before_restart)
    t.eq(world.grant.holders[1], 61)
    t.eq(world:active_claim_count(), 1)
  end,

  test_overclaimed_repository_keeps_deterministic_active_winner_and_releases_excess = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(1, {
      assignees = { OWNER },
      comments = { decision_comment(1, "enable"), state_comment(1, "thinking") },
    }))
    world:add(issue(2, {
      assignees = { OWNER },
      comments = { decision_comment(2, "decline") },
    }))
    world:add(issue(3, {
      assignees = { OWNER },
      comments = { decision_comment(3, "enable"), state_comment(3, "thinking") },
    }))
    world:add(issue(4))
    local controller = capacity.new(world:ports("/runtime/reconcile"))

    local candidate_granted = authorize(controller, world, 4)

    t.eq(candidate_granted, false)
    t.eq(world.grant.holders[1], 1)
    t.eq(world:active_claim_count(), 1)
    t.eq(claims.issue_claim_state(world.issues[1].assignees, OWNER), "self")
    t.eq(claims.issue_claim_state(world.issues[2].assignees, OWNER), "unassigned")
    t.eq(claims.issue_claim_state(world.issues[3].assignees, OWNER), "unassigned")
    t.eq(world:release_order()[1], 3)
    t.eq(world:release_order()[2], 2)
  end,

  test_blocked_winner_releases_capacity_for_next_issue = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(71))
    world:add(issue(72))
    local first_runtime = capacity.new(world:ports("/runtime/first"))

    t.eq(authorize(first_runtime, world, 71), true)
    world:claim(71)
    world.issues[71].comments = {
      decision_comment(71, "enable"),
      state_comment(71, "blocked", nil, "2026-07-16T00:00:01Z"),
    }

    local next_runtime = capacity.new(world:ports("/runtime/next"))
    local next_granted = authorize(next_runtime, world, 72)
    if next_granted then world:claim(72) end

    t.eq(next_granted, true)
    t.eq(world.grant.holders[1], 72)
    t.eq(claims.issue_claim_state(world.issues[71].assignees, OWNER), "unassigned")
    t.eq(claims.issue_claim_state(world.issues[72].assignees, OWNER), "self")
    t.eq(world:active_claim_count(), 1)
  end,

  test_reintake_reservation_survives_applied_response_until_bound_successor = function()
    h.mock_bot_env()
    local world = new_world(1)
    local command = reintake_command("IC_reintake_capacity_75")
    world:add(issue(75, {
      comments = {
        decision_comment(75, "enable"),
        state_comment(75, "blocked", nil, "2026-07-16T00:00:01Z"),
        command,
      },
    }))
    local controller = capacity.new(world:ports("/runtime/reintake"))

    t.eq(authorize(controller, world, 75), false)
    t.eq(controller.authorize_reintake(REPO, 75, world:current(75), proposal_id(75)), true)
    world:claim(75)

    local reservation = assert(world.grant.reintake_reservations[1])
    t.eq(reservation.issue_number, 75)
    t.is_true(reservation.command_key:find("operator%-command", 1, false) ~= nil)
    t.eq(reservation.effect_updated_at, "2026-07-16T00:00:02Z")
    t.is_true(type(reservation.successor_version) == "string" and reservation.successor_version ~= "")

    local successful_cas_after_grant = world.successful_cas
    table.insert(world.issues[75].comments, command_response(command, "applied"))
    t.eq(controller.reconcile(REPO, proposal_id(75)), true)
    t.eq(controller.reconcile(REPO, proposal_id(75)), true)
    t.eq(world.successful_cas, successful_cas_after_grant)
    t.eq(world.grant.holders[1], 75)
    t.eq(world.grant.reintake_reservations[1].command_key, reservation.command_key)

    table.insert(world.issues[75].comments, state_comment(
      75,
      "thinking",
      reservation.successor_version,
      "2026-07-16T00:00:04Z"
    ))
    t.eq(controller.reconcile(REPO, proposal_id(75)), true)
    t.eq(world.grant.holders[1], 75)
    t.eq(#world.grant.reintake_reservations, 0)

    table.insert(world.issues[75].comments, state_comment(
      75,
      "blocked",
      proposal_id(75) .. "/2026-07-16T00-00-05Z/intake/3",
      "2026-07-16T00:00:05Z"
    ))
    t.eq(controller.reconcile(REPO, proposal_id(75)), true)
    t.eq(#world.grant.holders, 0)
    t.eq(claims.issue_claim_state(world.issues[75].assignees, OWNER), "unassigned")
  end,

  test_reintake_refusal_releases_matching_reservation = function()
    h.mock_bot_env()
    local world = new_world(1)
    local command = reintake_command("IC_reintake_refused_76")
    world:add(issue(76, {
      comments = {
        decision_comment(76, "enable"),
        state_comment(76, "blocked", nil, "2026-07-16T00:00:01Z"),
        command,
      },
    }))
    local controller = capacity.new(world:ports("/runtime/reintake-refused"))

    t.eq(controller.authorize_reintake(REPO, 76, world:current(76), proposal_id(76)), true)
    world:claim(76)
    table.insert(world.issues[76].comments, command_response(command, "applied", "2026-07-16T00:00:03Z"))
    table.insert(world.issues[76].comments, command_response(command, "refused", "2026-07-16T00:00:04Z"))

    t.eq(controller.reconcile(REPO, proposal_id(76)), true)
    t.eq(#world.grant.holders, 0)
    t.eq(#world.grant.reintake_reservations, 0)
    t.eq(claims.issue_claim_state(world.issues[76].assignees, OWNER), "unassigned")
  end,

  test_reintake_cas_loss_does_not_accept_holder_without_matching_reservation = function()
    h.mock_bot_env()
    local command = reintake_command("IC_reintake_contended_77")
    local world = new_world(1)
    world:add(issue(77, {
      assignees = { OWNER },
      comments = {
        decision_comment(77, "enable"),
        state_comment(77, "blocked", nil, "2026-07-16T00:00:01Z"),
        command,
      },
    }))
    world.grant = {
      schema = capacity.schema,
      repo = REPO,
      owner = OWNER,
      capacity = 1,
      holders = { 77 },
      reintake_reservations = {},
      sha = string.format("%040x", 10),
    }
    world.before_next_cas = function()
      world.grant.sha = string.format("%040x", 11)
    end
    local controller = capacity.new(world:ports("/runtime/reintake-contended"))
    local department = owner_department(world, controller)

    local result = testing.run_fake(department, owner_event(77))

    t.eq(#result.raises, 0)
    t.eq(world.grant.holders[1], 77)
    t.eq(#world.grant.reintake_reservations, 0)
  end,

  test_real_admission_converts_blocked_holder_to_reintake_reservation_without_claim_gap = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(100))
    local controller = capacity.new(world:ports("/runtime/owner-handoff"))
    local department = owner_department(world, controller)

    testing.run_fake(department, owner_event(100))
    world.issues[100].labels = { "fkst-dev:enabled", "fkst-dev:blocked" }
    world.issues[100].comments = {
      decision_comment(100, "enable"),
      state_comment(100, "blocked", nil, "2026-07-16T00:00:01Z"),
      reintake_command("IC_owner_handoff_100"),
    }

    local reintake = testing.run_fake(department, owner_event(100))

    t.eq(reintake.raises[1].queue, "devloop_intake_candidate")
    t.eq(world.grant.holders[1], 100)
    t.eq(world.grant.reintake_reservations[1].issue_number, 100)
    t.eq(#world:release_order(), 0)
    t.eq(claims.issue_claim_state(world.issues[100].assignees, OWNER), "self")
  end,

  test_real_admission_owner_replays_blocked_release_and_reintake_handoff_schedules = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(101))
    world:add(issue(102))
    world:add(issue(103))
    local controller = capacity.new(world:ports("/runtime/owner-integration"))
    local department = owner_department(world, controller)

    local first = testing.run_fake(department, owner_event(101))
    t.eq(first.raises[1].queue, "devloop_intake_candidate")
    t.eq(world.grant.holders[1], 101)

    world.issues[101].labels = { "fkst-dev:enabled", "fkst-dev:blocked" }
    world.issues[101].comments = {
      decision_comment(101, "enable"),
      state_comment(101, "blocked", nil, "2026-07-16T00:00:01Z"),
    }
    local second = testing.run_fake(department, owner_event(102))
    t.eq(second.raises[1].queue, "devloop_intake_candidate")
    t.eq(world.grant.holders[1], 102)
    t.eq(claims.issue_claim_state(world.issues[101].assignees, OWNER), "unassigned")

    world.issues[102].labels = { "fkst-dev:enabled", "fkst-dev:blocked" }
    world.issues[102].comments = {
      decision_comment(102, "enable"),
      state_comment(102, "blocked", nil, "2026-07-16T00:00:01Z"),
    }
    local command = reintake_command("IC_owner_reintake_101")
    table.insert(world.issues[101].comments, command)
    local reintake = testing.run_fake(department, owner_event(101))
    t.eq(reintake.raises[1].queue, "devloop_intake_candidate")
    t.eq(world.grant.holders[1], 101)
    local reservation = assert(world.grant.reintake_reservations[1])
    t.eq(reservation.successor_version, reintake.raises[1].payload.effect_id)

    table.insert(world.issues[101].comments, command_response(command, "applied"))
    table.insert(world.issues[101].comments, reintake_command(
      "IC_owner_reintake_101_next",
      "2026-07-16T00:00:04Z"
    ))
    t.eq(controller.reconcile(REPO, proposal_id(101)), true)
    t.eq(controller.reconcile(REPO, proposal_id(101)), true)
    t.eq(world.grant.holders[1], 101)
    t.eq(world.grant.reintake_reservations[1].command_key, reservation.command_key)

    table.insert(world.issues[101].comments, state_comment(
      101,
      "thinking",
      reservation.successor_version,
      "2026-07-16T00:00:05Z"
    ))
    t.eq(controller.reconcile(REPO, proposal_id(101)), true)
    t.eq(world.grant.holders[1], 101)
    t.eq(#world.grant.reintake_reservations, 0)

    table.insert(world.issues[101].comments, state_comment(
      101,
      "blocked",
      proposal_id(101) .. "/2026-07-16T00-00-06Z/intake/3",
      "2026-07-16T00:00:06Z"
    ))
    local third = testing.run_fake(department, owner_event(103))
    t.eq(third.raises[1].queue, "devloop_intake_candidate")
    t.eq(world.grant.holders[1], 103)
    t.eq(#world.grant.holders, 1)
    t.eq(claims.issue_claim_state(world.issues[101].assignees, OWNER), "unassigned")
  end,

  test_declined_state_marker_releases_capacity_for_next_issue = function()
    h.mock_bot_env()
    local world = new_world(1)
    world:add(issue(73, {
      assignees = { OWNER },
      comments = {
        decision_comment(73, "enable"),
        state_comment(73, "declined"),
      },
    }))
    world:add(issue(74))
    local controller = capacity.new(world:ports("/runtime/declined"))

    local next_granted = authorize(controller, world, 74)
    if next_granted then world:claim(74) end

    t.eq(next_granted, true)
    t.eq(world.grant.holders[1], 74)
    t.eq(claims.issue_claim_state(world.issues[73].assignees, OWNER), "unassigned")
    t.eq(claims.issue_claim_state(world.issues[74].assignees, OWNER), "self")
    t.eq(world:active_claim_count(), 1)
  end,

  test_capacity_grant_ref_is_scoped_by_repository_and_actor = function()
    local first = capacity.grant_ref("owner/repo", OWNER)
    local second = capacity.grant_ref("owner/other", OWNER)

    t.is_true(first ~= second)
    t.is_true(first:find(OWNER, 1, true) ~= nil)
    t.is_true(second:find(OWNER, 1, true) ~= nil)
  end,

  test_failed_push_without_a_new_remote_generation_fails_loud = function()
    h.mock_bot_env()
    local world = new_world(2)
    world:add(issue(81))
    world:add(issue(82))
    local controller = capacity.new(world:ports("/runtime/push-failure"))

    t.eq(authorize(controller, world, 81), true)
    world:claim(81)
    world.fail_next_cas = true
    local ok, err = pcall(function()
      authorize(controller, world, 82)
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("capacity-grant-push-failed", 1, true) ~= nil)
  end,

  test_production_adapter_round_trips_create_and_leased_update = function()
    local tree_sha = string.rep("a", 40)
    local first_sha = string.rep("b", 40)
    local second_sha = string.rep("c", 40)
    local remote_sha = nil
    local next_commit_sha = first_sha
    local files = {}
    local messages = {}
    local writes = {}
    local adapter = capacity.production_adapter({
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
        git_rev_parse_ref_tree = function()
          return { stdout = tree_sha .. "\n", stderr = "", exit_code = 0 }
        end,
        git_commit_tree = function(actual_tree, parent_sha, message_file)
          t.eq(actual_tree, tree_sha)
          messages[next_commit_sha] = assert(files[message_file])
          table.insert(writes, {
            kind = "commit",
            parent_sha = parent_sha,
            sha = next_commit_sha,
          })
          return { stdout = next_commit_sha .. "\n", stderr = "", exit_code = 0 }
        end,
        git_push_ref_update = function(_remote, sha, ref, lease)
          table.insert(writes, {
            kind = "push",
            ref = ref,
            lease = lease,
            sha = sha,
          })
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
    local first = {
      schema = capacity.schema,
      repo = REPO,
      owner = OWNER,
      capacity = 1,
      holders = { 91 },
      reintake_reservations = {
        {
          issue_number = 91,
          command_key = "operator-command/IC_adapter_reintake",
          effect_updated_at = "2026-07-16T00:00:02Z",
          successor_version = proposal_id(91) .. "/intake/2",
        },
      },
    }

    local created, created_sha = adapter.compare_and_swap_grant(REPO, OWNER, nil, first)
    t.eq(created, true)
    t.eq(created_sha, first_sha)
    t.eq(writes[1].parent_sha, nil)
    t.eq(writes[2].lease, false)
    t.eq(writes[2].ref, capacity.grant_ref(REPO, OWNER))

    local decoded = adapter.read_grant(REPO, OWNER)
    t.eq(decoded.repo, REPO)
    t.eq(decoded.owner, OWNER)
    t.eq(decoded.capacity, 1)
    t.eq(decoded.holders[1], 91)
    t.eq(decoded.reintake_reservations[1].command_key, "operator-command/IC_adapter_reintake")
    t.eq(decoded.reintake_reservations[1].successor_version, proposal_id(91) .. "/intake/2")
    t.eq(decoded.sha, first_sha)

    next_commit_sha = second_sha
    local updated = copy(first)
    updated.holders = { 92 }
    updated.reintake_reservations = {}
    local changed, changed_sha = adapter.compare_and_swap_grant(REPO, OWNER, first_sha, updated)
    t.eq(changed, true)
    t.eq(changed_sha, second_sha)
    t.eq(writes[3].parent_sha, first_sha)
    t.eq(writes[4].lease, first_sha)
    t.eq(writes[4].ref, capacity.grant_ref(REPO, OWNER))
  end,

}
