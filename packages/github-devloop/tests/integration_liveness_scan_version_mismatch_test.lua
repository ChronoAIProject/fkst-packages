-- Liveness-scan behaviour at the implement version-mismatch BUDGET BOUNDARY.
--
-- Split out of integration_liveness_scan_test.lua, which sits at 968 lines on dev --
-- past the 900-line soft threshold, so any further append breaks the 1000-line hard
-- limit (G1) and blocks unrelated PRs. These two cases share one responsibility --
-- what the implementing re-drive does as the version-mismatch budget is spent -- so
-- they form their own bounded file rather than growing the general scan suite.

local h, devloop_base = require("tests.devloop_helpers"), require("devloop.base")
local t = h.t
local core = h.core
local opts = h.opts
local ready = h.ready
local find_raise = h.find_raise
local json_string = h.json_string

local repo = "owner/repo"
local ISSUE_REDRIVE_QUEUE = "devloop_observe_issue"

local function numbered_list_json(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      tonumber(item.number),
      json_string(item.state or "open"),
      json_string(item.updated_at or "")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function mock_repo()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list(items)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = numbered_list_json(items),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_empty_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function run_liveness_scan(name, run_opts)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    ts = "2026-06-03T01:32:03Z",
  }, run_opts or opts(name or "liveness-scan"))
end

return {
  -- Regression (the-omega-institute/trureturing#383): an implementing entity whose
  -- codex-run-absent liveness re-drive is GUARANTEED to fail implement's version check
  -- must STOP re-driving once the implement-version-mismatch delivery budget is
  -- exhausted. The re-drive takes impl_retry_attempt from the latest implement-attempt
  -- fact (attempt=2, the MAX_IMPLEMENT_ATTEMPTS ceiling), so implement derives
  -- implementation_attempt_version(V, 2) = reimplement(V, 2) which never matches the
  -- authoritative base implementing marker V; every delivery is a terminal
  -- fail-closed(version-mismatch-budget). Before the fix the sweep re-raised devloop_ready
  -- every ~5 min forever, burning an implement slot per sweep and starving newly-admitted
  -- implementable issues. The anti-spin mirrors the blocked/decompose-exhausted guard,
  -- scoped to the exact authoritative state.version.
  test_liveness_scan_implementing_stops_redrive_when_version_mismatch_budget_exhausted = function()
    local event = ready()
    local run_opts = opts("liveness-scan-implementing-version-mismatch-exhausted")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local expected = core.implementation_attempt_version(event.dedup_key, 2)
    -- The re-drive would hand implement a version that differs from the authoritative one.
    t.is_true(expected ~= event.dedup_key)
    local stuck = {
      h.state_comment_request(event.proposal_id, "implementing", event.dedup_key).body,
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), exec_ref),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, tostring(now() - 60), exec_ref),
      core.implement_version_mismatch_marker(event.proposal_id, expected, event.dedup_key, 1),
      core.implement_version_mismatch_marker(event.proposal_id, expected, event.dedup_key, 2),
    }
    -- Two mismatch markers == budget spent: the next implement delivery is terminal.
    t.eq(core.implement_version_mismatch_attempt_count(stuck, event.proposal_id, expected, event.dedup_key), 2)
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    h.mock_issue_implement({ "fkst-dev:enabled", "fkst-dev:implementing" }, stuck)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-implementing-version-mismatch-exhausted", run_opts)
    t.eq(scanned.exit_code, 0)
    -- No re-drive at all: no devloop_ready, no observe reinject, no new timeout-attempt.
    t.eq(find_raise(scanned.raises, "devloop_ready"), nil)
    t.eq(find_raise(scanned.raises, ISSUE_REDRIVE_QUEUE), nil)
    t.eq(find_raise(scanned.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
    end), nil)
  end,

  -- Conservative narrowing: while the mismatch budget still has room (only one mismatch
  -- marker, so the next re-drive still advances the mismatch attempt rather than hitting
  -- the terminal fail-closed), the sweep must STILL re-drive. This keeps the fix a
  -- surgical anti-spin at the exhaustion boundary, not a blanket disable of implementing
  -- re-drive.
  test_liveness_scan_implementing_redrives_when_version_mismatch_budget_not_exhausted = function()
    local event = ready()
    local run_opts = opts("liveness-scan-implementing-version-mismatch-not-exhausted")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local expected = core.implementation_attempt_version(event.dedup_key, 2)
    t.is_true(expected ~= event.dedup_key)
    local stuck = {
      h.state_comment_request(event.proposal_id, "implementing", event.dedup_key).body,
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), exec_ref),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 2, tostring(now() - 60), exec_ref),
      core.implement_version_mismatch_marker(event.proposal_id, expected, event.dedup_key, 1),
    }
    t.eq(core.implement_version_mismatch_attempt_count(stuck, event.proposal_id, expected, event.dedup_key), 1)
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    h.mock_issue_implement({ "fkst-dev:enabled", "fkst-dev:implementing" }, stuck)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-implementing-version-mismatch-not-exhausted", run_opts)
    t.eq(scanned.exit_code, 0)
    t.is_true(find_raise(scanned.raises, "devloop_ready") ~= nil)
  end,
}
