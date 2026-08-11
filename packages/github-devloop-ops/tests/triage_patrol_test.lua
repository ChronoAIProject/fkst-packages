local t = fkst.test
local base_ids = require("devloop.base_ids")
local core = require("core")
local github_issue_create = require("contract.github_issue_create")
local transition_version = require("contract.transition_version")
local content_filter = require("forge.github.content_filter")
local devloop_state = require("devloop.state")
local github_fake = require("forge.github_fake")
local testing = require("testkit_internal.testing")
local state_comment = require("testkit_internal.projected_state_fixture").bind_state_comment(devloop_state)

local repo = "o/" .. string.rep("r", base_ids.max_repo_key_len - 2)
local host_login = string.rep("h", base_ids.max_key_len)
local peer_login = "peer-bot"

local function proposal_id(issue_number)
  return "github-devloop/issue/" .. repo .. "/" .. tostring(issue_number)
end

local function comment(issue_number, state, version, author_login)
  return {
    body = state_comment(proposal_id(issue_number), state, version),
    author = { login = author_login },
    created_at = "2026-08-10T10:00:00Z",
  }
end

local function issue_fixture(number, author_login, labels, comments)
  return {
    repo = repo,
    number = number,
    title = "Issue " .. tostring(number),
    state = "OPEN",
    labels = labels,
    comments = comments,
    author = { login = author_login },
  }
end

local function has_label(issue, expected)
  for _, label in ipairs(issue.labels or {}) do
    local name = type(label) == "table" and label.name or label
    if tostring(name) == tostring(expected) then
      return true
    end
  end
  return false
end

local function install_candidate_list(github, model)
  model.issue_list_calls = {}
  github.issue_list_observe = function(list_repo, label, page, include_headers, timeout)
    t.eq(list_repo, repo)
    t.eq(timeout, core.observability_limits().call_timeout)
    local selected_page = tonumber(page)
    t.is_true(selected_page ~= nil and selected_page >= 1 and selected_page % 1 == 0)
    table.insert(model.issue_list_calls, {
      label = label,
      page = selected_page,
      include_headers = include_headers == true,
    })
    local rows = {}
    for _, issue in pairs(model.issues or {}) do
      if has_label(issue, label) then
        table.insert(rows, issue)
      end
    end
    table.sort(rows, function(left, right)
      return tonumber(left.number) < tonumber(right.number)
    end)
    local page_size = 100
    local first_index = ((selected_page - 1) * page_size) + 1
    local last_index = math.min(#rows, first_index + page_size - 1)
    local encoded = {}
    for index = first_index, last_index do
      local issue = rows[index]
      table.insert(encoded, '{"number":' .. tostring(issue.number) .. ',"state":"open"}')
    end
    local body = "[" .. table.concat(encoded, ",") .. "]"
    local headers = ""
    local total_pages = math.max(1, math.ceil(#rows / page_size))
    if include_headers and total_pages > 1 then
      headers = 'link: <https://api.github.test/repos/' .. repo
        .. '/issues?state=open&page=' .. tostring(total_pages) .. '>; rel="last"\n'
    end
    return {
      stdout = include_headers and ("HTTP/2 200\n" .. headers .. "\n" .. body) or body,
      stderr = "",
      exit_code = 0,
    }
  end
end

local function make_department(issues)
  local policy = content_filter.author_policy_from_logins({ host_login, peer_login })
  local model = github_fake.model({
    issues = issues or {},
    author_policy = policy,
  })
  local github = github_fake.new(model)
  github._trusted_author_policy = function()
    return policy
  end
  local read_issue = github.read_issue
  github.read_issue = function(source_ref, opts)
    t.eq(opts and opts.force_fresh, true)
    t.eq(opts and opts.cache_write, false)
    return read_issue(source_ref, opts)
  end
  install_candidate_list(github, model)

  local ok, installed = pcall(require, "departments.triage_patrol.main")
  t.is_true(ok, "triage patrol department must exist: " .. tostring(installed))
  return installed.make_department({ github = github }), model
end

local function mock_env(reads)
  for _ = 1, reads or 32 do
    t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = host_login,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function tick()
  return {
    queue = "devloop_triage_patrol_tick",
    payload = {
      raiser = "github-devloop-ops.triage_patrol_poll",
    },
  }
end

local function run_read_only(department, event)
  local old_spawn_codex = spawn_codex
  local old_spawn_codex_sync = spawn_codex_sync
  local old_cache_set = cache_set
  local old_file_write = file.write
  local old_log_warn = log.warn
  local codex_calls = 0
  local runtime_writes = 0
  local warnings = {}
  spawn_codex = function()
    codex_calls = codex_calls + 1
    error("triage patrol must not spawn codex")
  end
  spawn_codex_sync = function()
    codex_calls = codex_calls + 1
    error("triage patrol must not spawn codex")
  end
  cache_set = function()
    runtime_writes = runtime_writes + 1
    error("triage patrol must not write durable cache state")
  end
  file.write = function()
    runtime_writes = runtime_writes + 1
    error("triage patrol must not write runtime files")
  end
  log.warn = function(message)
    table.insert(warnings, tostring(message))
  end

  local ok, result = pcall(testing.run_fake, department, event or tick())
  spawn_codex = old_spawn_codex
  spawn_codex_sync = old_spawn_codex_sync
  cache_set = old_cache_set
  file.write = old_file_write
  log.warn = old_log_warn
  if not ok then
    error(result, 0)
  end
  t.eq(codex_calls, 0)
  t.eq(runtime_writes, 0)
  return result, warnings
end

local function only_receipt(result)
  t.eq(#result.raises, 1)
  t.eq(result.raises[1].queue, "github-proxy.github_issue_create_request")
  t.eq(result.raises[1].payload.schema, "github-proxy.issue-create.v1")
  return result.raises[1].payload
end

local function receipt_at(department, clock)
  local old_now = now
  now = function()
    return clock
  end
  local ok, result = pcall(run_read_only, department)
  now = old_now
  if not ok then
    error(result, 0)
  end
  return only_receipt(result)
end

return {
  test_raiser_uses_the_existing_maintenance_cadence = function()
    local raiser = require("raisers.triage_patrol_poll")
    t.eq(raiser.type, "cron")
    t.eq(raiser.interval, "30m")
    t.eq(raiser.produces, "devloop_triage_patrol_tick")
  end,

  test_current_state_fact_returns_canonical_winning_marker_author = function()
    local current_state_fact = devloop_state.current_state_fact
    t.is_true(type(current_state_fact) == "function", "devloop.state must expose current_state_fact")
    local issue_number = 21
    local self_version = proposal_id(issue_number) .. "/intake/2026-08-10T01-00-00Z"
    local peer_version = proposal_id(issue_number) .. "/intake/2026-08-10T02-00-00Z"
    local comments = {
      comment(issue_number, "declined", self_version, "App/" .. host_login),
      comment(issue_number, "dependency_wait", peer_version, "Peer-Bot[bot]"),
    }

    local peer_wins = current_state_fact(comments, proposal_id(issue_number), {
      [host_login] = true,
      [peer_login] = true,
    })
    t.eq(peer_wins.state, "dependency_wait")
    t.eq(peer_wins.version, peer_version)
    t.eq(peer_wins.author_login, peer_login)

    local self_only = current_state_fact(comments, proposal_id(issue_number), {
      [host_login] = true,
    })
    t.eq(self_only.state, "declined")
    t.eq(self_only.version, self_version)
    t.eq(self_only.author_login, host_login)
  end,

  test_current_state_keeps_the_existing_author_free_projection = function()
    local issue_number = 22
    local version = proposal_id(issue_number) .. "/intake/2026-08-10T01-00-00Z"
    local current = devloop_state.current_state({
      comment(issue_number, "declined", version, host_login),
    }, proposal_id(issue_number))

    t.eq(current.state, "declined")
    t.eq(current.version, version)
    t.eq(current.author_login, nil)
  end,

  test_patrol_emits_one_stable_host_owned_abstain_receipt_without_writes = function()
    local v11 = proposal_id(11) .. "/intake/2026-08-10T01-00-00Z"
    local v12_self = proposal_id(12) .. "/intake/2026-08-10T02-00-00Z"
    local v12_peer = proposal_id(12) .. "/intake/2026-08-10T03-00-00Z"
    local v13 = proposal_id(13) .. "/intake/2026-08-10T04-00-00Z"
    local v14 = proposal_id(14) .. "/intake/2026-08-10T05-00-00Z"
    local issues = {
      [repo .. "#issue/11"] = issue_fixture(11, "another-account", { "fkst-dev:blocked" }, {
        comment(11, "declined", v11, "App/" .. host_login),
        comment(11, "blocked", proposal_id(11) .. "/intake/2026-08-11T01-00-00Z", "untrusted-attacker"),
      }),
      [repo .. "#issue/12"] = issue_fixture(12, host_login, { "fkst-dev:declined" }, {
        comment(12, "declined", v12_self, host_login),
        comment(12, "declined", v12_peer, peer_login),
      }),
      [repo .. "#issue/13"] = issue_fixture(13, "another-account", { "fkst-dev:ready" }, {
        comment(13, "dependency_wait", v13, host_login .. "[bot]"),
      }),
      [repo .. "#issue/14"] = issue_fixture(14, "another-account", { "fkst-dev:blocked" }, {
        comment(14, "blocked", v14, host_login),
      }),
    }
    mock_env(64)
    local department, model = make_department(issues)

    local first = only_receipt(run_read_only(department))
    local second = only_receipt(run_read_only(department))

    t.eq(first.repo, repo)
    t.eq(first.dedup_key, second.dedup_key)
    t.eq(first.body, second.body)
    t.eq(first.source_ref.kind, "repo-site")
    t.eq(first.source_ref.ref, second.source_ref.ref)
    t.is_true(first.body:find("p=" .. proposal_id(11), 1, true) ~= nil)
    t.is_true(first.body:find("i=11", 1, true) ~= nil)
    t.is_true(first.body:find("s=declined", 1, true) ~= nil)
    t.is_true(first.body:find("marker_version=" .. v11, 1, true) ~= nil)
    t.is_true(first.body:find("p=" .. proposal_id(13), 1, true) ~= nil)
    t.is_true(first.body:find("i=13", 1, true) ~= nil)
    t.is_true(first.body:find("s=dependency_wait", 1, true) ~= nil)
    t.is_true(first.body:find("marker_version=" .. v13, 1, true) ~= nil)
    t.is_true(first.body:find("a=" .. host_login, 1, true) ~= nil)
    t.eq(select(2, first.body:gsub("verdict=abstain", "")), 3)
    t.eq(first.body:find(proposal_id(12), 1, true), nil)
    t.eq(first.body:find(peer_login, 1, true), nil)
    t.is_true(first.body:find("p=" .. proposal_id(14)
      .. " i=14 s=blocked marker_version=" .. v14
      .. " a=" .. host_login .. " why= verdict=abstain", 1, true) ~= nil)
    t.is_true(first.body:find("fkst:github-devloop-ops:triage-patrol-receipt:v1", 1, true) ~= nil)
    t.is_true(first.body:find("⟦AI:FKST⟧", 1, true) ~= nil)

    local changed_version = proposal_id(11) .. "/intake/2026-08-12T01-00-00Z"
    table.insert(model.issues[repo .. "#issue/11"].comments,
      comment(11, "declined", changed_version, host_login))
    local changed = only_receipt(run_read_only(department))
    t.is_true(changed.dedup_key ~= first.dedup_key)
    t.is_true(changed.source_ref.ref ~= first.source_ref.ref)
    t.is_true(changed.body:find("marker_version=" .. changed_version, 1, true) ~= nil)
    t.eq(#model.writes, 0)
  end,

  test_patrol_derives_child_pr_blocked_from_the_host_owned_marker_suffix = function()
    local derived_version = transition_version.next_blocked(
      proposal_id(31) .. "/intake/2026-08-10T01-00-00Z",
      "child-pr-blocked"
    )
    local other_version = transition_version.next_blocked(
      proposal_id(32) .. "/intake/2026-08-10T02-00-00Z",
      "child-pr-blocked-other"
    )
    local nonfinal_version = transition_version.next_timeout(derived_version, "awaiting-pr")
    local issues = {
      [repo .. "#issue/31"] = issue_fixture(31, "another-account", { "fkst-dev:blocked" }, {
        comment(31, "blocked", derived_version, "App/" .. host_login),
      }),
      [repo .. "#issue/32"] = issue_fixture(32, "another-account", { "fkst-dev:blocked" }, {
        comment(32, "blocked", other_version, host_login),
      }),
      [repo .. "#issue/33"] = issue_fixture(33, "another-account", { "fkst-dev:blocked" }, {
        comment(33, "thinking", proposal_id(33) .. "/intake/2026-08-10T03-00-00Z", host_login),
      }),
      [repo .. "#issue/34"] = issue_fixture(34, host_login, { "fkst-dev:blocked" }, {
        comment(34, "blocked", transition_version.next_blocked(
          proposal_id(34) .. "/intake/2026-08-10T04-00-00Z",
          "child-pr-blocked"
        ), peer_login),
      }),
      [repo .. "#issue/35"] = issue_fixture(35, "another-account", { "fkst-dev:blocked" }, {
        comment(35, "blocked", nonfinal_version, host_login),
      }),
    }
    mock_env(64)
    local department, model = make_department(issues)

    local first = receipt_at(department, 1000)
    local later = receipt_at(department, 2000)

    t.eq(first.title, "Triage patrol audit receipt")
    t.eq(first.dedup_key, later.dedup_key)
    t.eq(first.body, later.body)
    t.is_true(first.body:find("p=" .. proposal_id(31)
      .. " i=31 s=blocked marker_version=" .. derived_version
      .. " a=" .. host_login .. " why=child-pr-blocked verdict=derived", 1, true) ~= nil)
    t.is_true(first.body:find("p=" .. proposal_id(32)
      .. " i=32 s=blocked marker_version=" .. other_version
      .. " a=" .. host_login .. " why=child-pr-blocked-other verdict=abstain", 1, true) ~= nil)
    t.is_true(first.body:find("p=" .. proposal_id(35)
      .. " i=35 s=blocked marker_version=" .. nonfinal_version
      .. " a=" .. host_login .. " why= verdict=abstain", 1, true) ~= nil)
    t.eq(first.body:find(proposal_id(33), 1, true), nil)
    t.eq(first.body:find(proposal_id(34), 1, true), nil)
    t.eq(#model.writes, 0)
  end,

  test_zero_candidate_pass_still_emits_one_deduplicated_empty_receipt = function()
    mock_env(32)
    local department, model = make_department({})

    local first = only_receipt(run_read_only(department))
    local second = only_receipt(run_read_only(department))

    t.eq(first.dedup_key, second.dedup_key)
    t.eq(first.body, second.body)
    t.is_true(first.body:find('entries="0"', 1, true) ~= nil)
    t.eq(first.body:find("verdict=abstain", 1, true), nil)
    t.eq(#model.writes, 0)
  end,

  test_labeled_candidate_without_an_authorized_marker_is_omitted = function()
    local issues = {
      [repo .. "#issue/15"] = issue_fixture(15, "another-account", { "fkst-dev:declined" }, {
        comment(15, "declined", proposal_id(15) .. "/intake/2026-08-10T01-00-00Z", "untrusted-attacker"),
      }),
    }
    mock_env(32)
    local department, model = make_department(issues)

    local receipt = only_receipt(run_read_only(department))

    t.is_true(receipt.body:find('entries="0"', 1, true) ~= nil)
    t.eq(receipt.body:find(proposal_id(15), 1, true), nil)
    t.eq(#model.writes, 0)
  end,

  test_receipt_window_fits_maximum_fields_without_truncation_and_reports_deferral = function()
    local issues = {}
    local versions = {}
    for issue_number = 101, 100 + core.observability_limits().entity_cap do
      local prefix = proposal_id(issue_number) .. "/intake/"
      local version = prefix .. string.rep("v", base_ids.max_dedup_len - #prefix)
      t.eq(#version, base_ids.max_dedup_len)
      versions[issue_number] = version
      issues[repo .. "#issue/" .. tostring(issue_number)] = issue_fixture(
        issue_number,
        "another-account",
        { devloop_state.state_label("dependency_wait") },
        { comment(issue_number, "dependency_wait", version, host_login) }
      )
    end
    mock_env(64)
    local department = make_department(issues)

    local result, warnings = run_read_only(department)
    local receipt = only_receipt(result)
    local entry_count = select(2, receipt.body:gsub("verdict=abstain", ""))
    local exact_versions = 0
    for _, version in pairs(versions) do
      if receipt.body:find(version, 1, true) ~= nil then
        exact_versions = exact_versions + 1
      end
    end

    t.is_true(#receipt.body <= github_issue_create.limits().body)
    t.is_true(entry_count > 0)
    t.is_true(entry_count < core.observability_limits().entity_cap)
    t.eq(exact_versions, entry_count)
    t.is_true(receipt.body:find("a=" .. host_login, 1, true) ~= nil)
    t.eq(#warnings, 1)
    t.is_true(warnings[1]:find("tag=OBSERVE_DEFERRED", 1, true) ~= nil)
    t.is_true(warnings[1]:find("reason=receipt-body-cap", 1, true) ~= nil)
    t.is_true(warnings[1]:find("receipt_cap=" .. tostring(entry_count), 1, true) ~= nil)
    t.is_true(warnings[1]:find(
      "deferred_issues=" .. tostring(core.observability_limits().entity_cap - entry_count),
      1,
      true
    ) ~= nil)
  end,

  test_candidate_bound_rotates_with_the_tick_identity = function()
    local issues = {}
    for issue_number = 201, 201 + core.observability_limits().entity_cap do
      local version = proposal_id(issue_number) .. "/intake/v1"
      issues[repo .. "#issue/" .. tostring(issue_number)] = issue_fixture(
        issue_number,
        "another-account",
        { "fkst-dev:declined" },
        { comment(issue_number, "declined", version, host_login) }
      )
    end
    mock_env(64)
    local department = make_department(issues)
    local first_tick = tick()
    first_tick.ts = "100"
    local second_tick = tick()
    second_tick.ts = "101"

    local first = only_receipt(run_read_only(department, first_tick))
    local second = only_receipt(run_read_only(department, second_tick))

    t.is_true(first.dedup_key ~= second.dedup_key)
    t.is_true(first.body ~= second.body)
    local deferred_candidate_covered = false
    for issue_number = 201, 201 + core.observability_limits().entity_cap do
      local field = "i=" .. tostring(issue_number) .. " "
      if first.body:find(field, 1, true) == nil and second.body:find(field, 1, true) ~= nil then
        deferred_candidate_covered = true
      end
    end
    t.is_true(deferred_candidate_covered)
  end,

  test_patrol_reaches_an_eligible_row_after_the_first_hundred_candidates = function()
    local issues = {}
    for issue_number = 1, 100 do
      issues[repo .. "#issue/" .. tostring(issue_number)] = issue_fixture(
        issue_number,
        "another-account",
        { "fkst-dev:declined" },
        { comment(issue_number, "blocked", proposal_id(issue_number) .. "/intake/v1", host_login) }
      )
    end
    local tail_number = 101
    local tail_version = proposal_id(tail_number) .. "/intake/v1"
    issues[repo .. "#issue/" .. tostring(tail_number)] = issue_fixture(
      tail_number,
      "another-account",
      { "fkst-dev:declined" },
      { comment(tail_number, "declined", tail_version, host_login) }
    )
    mock_env(64)
    local department, model = make_department(issues)
    local event = tick()
    event.ts = "100"

    local receipt = only_receipt(run_read_only(department, event))

    t.is_true(receipt.body:find("i=" .. tostring(tail_number) .. " ", 1, true) ~= nil)
    t.is_true(receipt.body:find("marker_version=" .. tail_version, 1, true) ~= nil)
    local listed_tail_page = false
    for _, call in ipairs(model.issue_list_calls) do
      if call.label == "fkst-dev:declined" and call.page == 2 then
        listed_tail_page = true
      end
    end
    t.eq(listed_tail_page, true)
  end,

  test_department_spec_is_read_only_except_for_the_receipt_seam = function()
    mock_env(16)
    local department = make_department({})
    t.eq(department.spec.stall_window, "10m")
    t.eq(#department.spec.consumes, 1)
    t.eq(department.spec.consumes[1], "devloop_triage_patrol_tick")
    t.eq(#department.spec.produces, 1)
    t.eq(department.spec.produces[1], "github-proxy.github_issue_create_request")
    for _, queue in ipairs(department.spec.consumes) do
      t.eq(queue:find("github-devloop.", 1, true), nil)
      t.eq(queue:find("github-devloop-pr.", 1, true), nil)
    end
  end,
}
