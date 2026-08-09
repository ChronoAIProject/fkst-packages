local devloop_base = require("devloop.base")
local claim_carriers = require("devloop.claim_carriers")
local entity_lib = require("devloop.entity")
local entity_highwater = require("devloop.entity_highwater")
local base_ids = require("devloop.base_ids")
local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local proposal_id = base_ids.proposal_id(repo, issue_number)
local blocked_version = "blocked/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function observe_spec()
  return require("departments.observe_issue.main").spec
end

local function source_ref()
  return entity_lib.issue_source_ref(repo, issue_number)
end

local highwater_key = entity_highwater.key("github-devloop/observe_issue", source_ref())

local function with_isolated_observation_highwater(run)
  local prior = cache_get(highwater_key)
  cache_set(highwater_key, "")
  local results = table.pack(pcall(run))
  cache_set(highwater_key, prior or "")
  if not results[1] then
    error(results[2], 0)
  end
  return table.unpack(results, 2, results.n)
end

local function initial_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Entry routing issue",
      updated_at = "2026-06-03T01:02:03Z",
      dedup_key = "owner/repo#issue/42@2026-06-03T01:02:03Z",
      source_ref = source_ref(),
    },
    source_ref = {
      kind = "external",
      reference = "owner/repo#issue/42",
    },
  }
end

local function mock_runtime_and_context(claim_mode)
  for _ = 1, 8 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_MODE"), {
      stdout = claim_mode or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_claim_label_collision()
  local spec = claim_carriers.active_label_spec(false, "fkst-test-bot")
  t.mock_command("gh api repos/owner/repo/labels/" .. spec.name, {
    stdout = '{"name":"' .. spec.name
      .. '","description":"fkst-dev-label-mode-ownership-claim owner=peer-bot"}\n',
    stderr = "",
    exit_code = 0,
  })
  return spec.name
end

local function mock_blocked_issue_with_stale_label()
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:enabled", "fkst-dev:thinking" },
    {
      core.state_marker(proposal_id, "blocked", blocked_version),
    },
    {
      repo = repo,
      number = issue_number,
      title = "Entry routing issue",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      times = 4,
    }
  )
  t.mock_command(core.gh_issue_list_decompose_children_cmd(repo, proposal_id), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_run_graph_observe_issue_fails_closed_on_claim_label_owner_collision = function()
    return with_isolated_observation_highwater(function()
      mock_runtime_and_context("label")
      local claim_label = mock_claim_label_collision()
      entity_read_mocks.mock_issue_read_with_defaults(
        t,
        { "fkst-dev:enabled", "fkst-dev:blocked", claim_label },
        { core.state_marker(proposal_id, "blocked", blocked_version) },
        {
          repo = repo,
          number = issue_number,
          title = "Entry routing issue",
          updated_at = "2026-06-03T01:02:03Z",
          state = "OPEN",
          assignees = {},
          author_login = "human",
          times = 4,
        }
      )

      local trace = graph.run(initial_event(), { max_steps = 2 })
      local delivery = graph.require_delivery(trace, {
        queue = "github-proxy.github_entity_changed",
        consumer = "github-devloop.observe_issue",
      })
      t.is_true(delivery.exit_code ~= 0, tostring(delivery.error))
      t.is_true(
        tostring(delivery.error):find("claim-label-owner-collision", 1, true) ~= nil,
        tostring(delivery.error)
      )
    end)
  end,

  test_run_graph_entity_changed_delivers_to_observe_issue_and_raises_forward_action = function()
    return with_isolated_observation_highwater(function()
      mock_runtime_and_context()
      mock_blocked_issue_with_stale_label()

      local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 4 }))
      graph.assert_covers(trace, {
        "github-proxy.github_entity_changed -> github-devloop.observe_issue",
        "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
      })

      local route = graph.require_router_regression(trace, {
        spec = observe_spec(),
        entry_queue = "github-proxy.github_entity_changed",
        consumer = "github-devloop.observe_issue",
        raised_queue = "github-proxy.github_issue_label_request",
        downstream_consumer = "github-proxy.github_issue_label",
        raised_predicate = function(raised)
          local payload = raised.payload or {}
          return payload.schema == "github-proxy.label.v1"
            and payload.repo == repo
            and tonumber(payload.issue_number) == issue_number
            and payload.add_labels ~= nil
            and payload.add_labels[1] == "fkst-dev:blocked"
            and graph.payload_contains(raised, proposal_id)
        end,
      })

      local label_request = route.raised
      t.eq(label_request.payload.source_ref.ref, "owner/repo#issue/42")
    end)
  end,
}
