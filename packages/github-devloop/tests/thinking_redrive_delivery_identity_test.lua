local consensus_core = require("consensus.core")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local timeout_attempts = require("devloop.convergence.attempts")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local runtime_root = "/tmp/fkst-packages-test/github-devloop-thinking-redrive-delivery/runtime"
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"

local function state_comment(version)
  return {
    body = core.state_marker(proposal_id, "thinking", version),
    created_at = "2026-06-03T00:00:00Z",
  }
end

local function run_redrive(event, version, prior_attempt_body, name)
  local comments = { state_comment(version) }
  if prior_attempt_body ~= nil then
    table.insert(comments, {
      body = prior_attempt_body,
      created_at = "2026-06-03T00:10:00Z",
    })
  end
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:enabled", "fkst-dev:thinking" },
    comments,
    {
      repo = repo,
      number = issue_number,
      state = "OPEN",
      assignees = { "fkst-test-bot" },
      times = 1,
    }
  )
  return h.run_observe(event, h.opts(name, {
    now = "2026-06-03T02:00:00Z",
    env = { FKST_RUNTIME_ROOT = runtime_root },
  }))
end

local function mock_consensus_approvals(count)
  for _ = 1, count do
    for _ = 1, #consensus_core.angles({}) do
      t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("mkdir -p", {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("codex exec", {
        stdout = verdict_label .. " approve\n" .. reply_label .. " thinking redrive delivered.\n",
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

local function mock_consensus_result_reads(logical_version)
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:thinking" },
    { state_comment(logical_version) },
    {
      repo = repo,
      number = issue_number,
      title = "Implement decision recorder",
      updated_at = "2026-06-03T01:02:03Z",
      state = "OPEN",
      times = 2,
    }
  )
  for _ = 1, 2 do
    t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function deliver_to_consensus_result(request, name)
  local result = h.run_department("departments/consensus_result/main.lua", {
    queue = "devloop_consensus_request",
    payload = request.payload,
  }, h.opts(name, {
    env = { FKST_RUNTIME_ROOT = runtime_root },
  }))
  if result.exit_code ~= 0 then
    local details = {}
    for key, value in pairs(result) do
      if type(value) ~= "table" then
        table.insert(details, tostring(key) .. "=" .. tostring(value))
      end
    end
    error("thinking redrive receiver failed: " .. table.concat(details, ", "))
  end
  t.is_true(h.find_raise(result.raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find('state="ready"', 1, true) ~= nil
  end) ~= nil)
end

return {
  test_repeated_thinking_redrives_use_fresh_delivery_identity_and_reach_consensus = function()
    local event = h.issue()
    local logical_version = payloads_builders.build_proposal(event).dedup_key

    local first = run_redrive(event, logical_version, nil, "thinking-redrive-delivery-first")
    t.eq(first.exit_code, 0)
    local first_request = h.find_raise(first.raises, "devloop_consensus_request")
    local first_attempt = h.find_raise(first.raises, "github-proxy.github_issue_comment_request")
    t.is_true(first_request ~= nil)
    t.is_true(first_attempt ~= nil)

    local prior_attempt_body = timeout_attempts.timeout_attempt_v2_marker(
      proposal_id,
      "thinking",
      "thinking.active",
      first_request.payload.redrive_delivery.generation_key,
      1,
      event.source_ref
    )
    local second = run_redrive(
      event,
      logical_version,
      prior_attempt_body,
      "thinking-redrive-delivery-second"
    )
    t.eq(second.exit_code, 0)
    local second_request = h.find_raise(second.raises, "devloop_consensus_request")
    local second_attempt = h.find_raise(second.raises, "github-proxy.github_issue_comment_request")
    t.is_true(second_request ~= nil)
    t.is_true(second_attempt ~= nil)

    t.eq(first_request.payload.effect_version, logical_version)
    t.eq(second_request.payload.effect_version, logical_version)
    t.eq(
      second_request.payload.redrive_delivery.generation_key,
      first_request.payload.redrive_delivery.generation_key
    )
    t.eq(first_request.payload.redrive_delivery.attempt, 1)
    t.eq(second_request.payload.redrive_delivery.attempt, 2)
    t.eq(first_request.payload.dedup_key == logical_version, false)
    t.eq(second_request.payload.dedup_key == first_request.payload.dedup_key, false)
    t.eq(first_attempt.payload.body:find('round="1"', 1, true) ~= nil, true)
    t.eq(second_attempt.payload.body:find('round="2"', 1, true) ~= nil, true)

    mock_consensus_approvals(2)
    mock_consensus_result_reads(logical_version)
    deliver_to_consensus_result(first_request, "thinking-redrive-delivery-result-first")
    deliver_to_consensus_result(second_request, "thinking-redrive-delivery-result-second")
  end,
}
