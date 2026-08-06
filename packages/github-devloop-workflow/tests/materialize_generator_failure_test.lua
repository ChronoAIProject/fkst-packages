local fixtures = require("tests.materialize_reconcile_helpers")

local comment = fixtures.comment
local digest = fixtures.digest
local issue = fixtures.issue
local marker = fixtures.marker
local only_queue = fixtures.only_queue
local origin = fixtures.origin
local run_with = fixtures.run_with
local t = fixtures.t

local function issue_with_blueprint(bp)
  local built, err = marker.build_blueprint_marker(origin, bp.id, digest.blueprint_digest(bp))
  t.is_nil(err)
  return issue({ comment(built) })
end

local function generated_first_blueprint()
  local bp = fixtures.blueprint()
  bp.steps = { bp.steps[2] }
  bp.steps[1].id = "first"
  return bp
end

local function generated_first_config(spawn_codex)
  local bp = generated_first_blueprint()
  return {
    blueprint = bp,
    current = issue_with_blueprint(bp),
    spawn_codex = spawn_codex,
  }
end

local function assert_no_terminal_or_child(raised)
  t.eq(#only_queue(raised, "github-proxy.github_issue_comment_request"), 0)
  t.eq(#only_queue(raised, "github-proxy.github_issue_create_request"), 0)
end

local tests = {
  test_codex_invocation_failure_retries_same_slot_on_next_tick = function()
    local attempts = 0
    local config = generated_first_config(function()
      attempts = attempts + 1
      if attempts == 1 then
        return { exit_code = 1, stderr = "transient service failure" }
      end
      return {
        exit_code = 0,
        stdout = '{"title":"Recovered child","body":"Materialize after retry."}',
      }
    end)

    local first_tick = run_with(config)
    t.eq(attempts, 1)
    assert_no_terminal_or_child(first_tick)

    local second_tick = run_with(config)
    t.eq(attempts, 2)
    t.eq(#only_queue(second_tick, "github-proxy.github_issue_comment_request"), 0)
    local creates = only_queue(second_tick, "github-proxy.github_issue_create_request")
    t.eq(#creates, 1)
    t.eq(creates[1].payload.title, "Recovered child")
  end,

  test_unparseable_generated_product_writes_no_terminal_or_child = function()
    local raised = run_with(generated_first_config(function()
      return { exit_code = 0, stdout = "not a generated issue spec" }
    end))

    assert_no_terminal_or_child(raised)
  end,

  test_invalid_generated_product_writes_no_terminal_or_child = function()
    local raised = run_with(generated_first_config(function()
      return { exit_code = 0, stdout = '{"title":"","body":"body"}' }
    end))

    assert_no_terminal_or_child(raised)
  end,

  test_missing_generator_runner_keeps_existing_error_terminal = function()
    local bp = generated_first_blueprint()

    local raised = run_with({
      blueprint = bp,
      current = issue_with_blueprint(bp),
      spawn_codex_sync = "unavailable",
    })
    local terminal_comments = only_queue(raised, "github-proxy.github_issue_comment_request")

    t.eq(#terminal_comments, 1)
    t.is_true(terminal_comments[1].payload.body:find('state="error"', 1, true) ~= nil)
    t.is_true(terminal_comments[1].payload.body:find('reason_code="missing-generator-runner"', 1, true) ~= nil)
    t.is_true(terminal_comments[1].payload.body:find('monotonic="true"', 1, true) ~= nil)
  end,
}

return tests
