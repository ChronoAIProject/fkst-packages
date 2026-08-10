local h = require("tests.devloop_helpers")
local claim_carriers = require("devloop.claim_carriers")
local t = h.t
local core = h.core
local opts = h.opts
local issue = h.issue
local run_observe = h.run_observe
local mock_issue_state = h.mock_issue_state
local mock_unclaimed_issue_state = h.mock_unclaimed_issue_state
local mock_bot_env = h.mock_bot_env
local count_calls = h.count_calls
local find_raise = h.find_raise

local function mock_claim_env()
  mock_bot_env()
  for _ = 1, 6 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 6 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
  end
end

local active_label = claim_carriers.derived_label("fkst-test-bot")

local function encode_labels_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', h.json_string(label)))
  end
  return '{"labels":[' .. table.concat(rendered, ",") .. "]}\n"
end

local function mock_add_self()
  t.mock_command("gh issue edit 42 --repo owner/repo --add-label '" .. active_label .. "'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end


local function mock_claim_view(labels)
  t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", 42), {
    stdout = encode_labels_json(labels):gsub("}\n$", ',"author":{"login":"fkst-test-bot"}}\n'),
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_managed_unassigned_issue_is_reclaimed_before_replay = function()
    mock_claim_env()
    mock_unclaimed_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", nil, {})
    mock_add_self()
    mock_claim_view({ active_label })

    local result = run_observe(issue(), opts("observe-managed-unassigned-reclaim", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request").payload.effect_version, "2026-06-02T00-00-00Z")
    t.eq(count_calls("--add-label " .. active_label), 1)
    t.eq(count_calls("--remove-label " .. active_label), 0)
  end,

  test_stalled_self_claimed_issue_is_held_without_label_writes = function()
    mock_claim_env()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking", active_label }, "OPEN", nil, {})

    local result = run_observe(issue(), opts("observe-stalled-self-claim-held", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request").payload.effect_version, "2026-06-02T00-00-00Z")
    t.eq(count_calls("--remove-label " .. active_label), 0)
    t.eq(count_calls("--add-label " .. active_label), 0)
  end,
}
