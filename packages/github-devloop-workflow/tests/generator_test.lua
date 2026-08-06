local generator = require("core.generator")
local t = fkst.test

local static_slot = {
  id = "first",
  title = "Static step",
  content = {
    kind = "static",
    intent = "Implement the static step.",
  },
}

local generated_slot = {
  id = "second",
  title = "Generated step",
  content = {
    kind = "generated",
    generator = "Use the predecessor result to produce a follow-up issue.",
  },
}

local predecessor = {
  source_ref = {
    kind = "external",
    ref = "owner/repo#issue/42",
  },
}

local tests = {
  test_static_literal_emits_title_and_body_without_codex = function()
    local called = false
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        called = true
        return { exit_code = 0, stdout = "{}" }
      end,
    }, {}, static_slot, nil)
    t.eq(outcome.disposition, "ready")
    t.eq(outcome.spec.title, "Static step")
    t.eq(outcome.spec.body, "Implement the static step.")
    t.eq(called, false)
  end,

  test_static_validation_failures_cannot_proceed = function()
    local invalid_title = generator.run_slot_generator({}, {}, {
      title = "",
      content = { kind = "static", intent = "body" },
    }, nil)
    t.eq(invalid_title.disposition, "cannot_proceed")
    t.eq(invalid_title.reason_code, "invalid-title")

    local invalid_body = generator.run_slot_generator({}, {}, {
      title = "title",
      content = { kind = "static", intent = "" },
    }, nil)
    t.eq(invalid_body.disposition, "cannot_proceed")
    t.eq(invalid_body.reason_code, "invalid-body")
  end,

  test_generated_slot_uses_codex_and_source_ref_not_content_payload = function()
    local seen_prompt = nil
    local outcome = generator.run_slot_generator({
      content_fetch = function(ref)
        t.eq(ref.source_ref.ref, "owner/repo#issue/42")
        return "runtime-cache:workflow/predecessor"
      end,
      spawn_codex = function(prompt)
        seen_prompt = prompt
        return {
          exit_code = 0,
          stdout = '{"title":"Next bounded issue","body":"Implement the generated follow-up."}',
        }
      end,
    }, {
      origin_proposal_id = "github-devloop/issue/owner/repo/9",
      workflow_id = "workflow-one",
    }, generated_slot, predecessor)
    t.eq(outcome.disposition, "ready")
    t.eq(outcome.spec.title, "Next bounded issue")
    t.eq(outcome.spec.body, "Implement the generated follow-up.")
    t.is_true(seen_prompt:find("owner/repo#issue/42", 1, true) ~= nil)
    t.is_true(seen_prompt:find("runtime-cache:workflow/predecessor", 1, true) ~= nil)
    t.is_nil(seen_prompt:find("Implement the generated follow%-up%."))
  end,

  -- Regression (found by real dogfood): a pre-fetch failure must NOT block
  -- generation. The codex still has the predecessor source_ref (+ full access)
  -- and is instructed to fetch it directly, so content_fetch throwing (e.g. an
  -- unavailable devloop board/context-bundle in one-shot run) falls back to the
  -- source_ref instead of hard-erroring predecessor-content-fetch-failed.
  test_generated_slot_content_fetch_failure_falls_back_to_source_ref = function()
    local seen_prompt = nil
    local outcome = generator.run_slot_generator({
      content_fetch = function()
        error("board unavailable")
      end,
      spawn_codex = function(prompt)
        seen_prompt = prompt
        return { exit_code = 0, stdout = '{"title":"Next","body":"From source_ref."}' }
      end,
    }, {
      origin_proposal_id = "github-devloop/issue/owner/repo/9",
      workflow_id = "workflow-one",
    }, generated_slot, predecessor)
    t.eq(outcome.disposition, "ready")
    t.eq(outcome.spec.title, "Next")
    t.eq(outcome.spec.body, "From source_ref.")
    t.is_true(seen_prompt:find("owner/repo#issue/42", 1, true) ~= nil)
  end,

  test_generated_sync_runner_uses_unrestricted_codex_options = function()
    local seen_opts = nil
    local outcome = generator.run_slot_generator({
      spawn_codex_sync = function(spawn_opts)
        seen_opts = spawn_opts
        return { exit_code = 0, stdout = '{"title":"Next","body":"From source_ref."}' }
      end,
    }, {
      worktree = "/tmp/generator-worktree",
    }, generated_slot, predecessor)

    t.eq(outcome.disposition, "ready")
    t.eq(outcome.spec.title, "Next")
    t.eq(seen_opts.worktree, "/tmp/generator-worktree")
    t.is_true(type(seen_opts.prompt) == "string")
    t.is_nil(seen_opts.sandbox)
  end,

  test_generated_invalid_output_returns_reason_code = function()
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        return {
          exit_code = 0,
          stdout = '{"title":"","body":"body"}',
        }
      end,
    }, {}, generated_slot, predecessor)
    t.eq(outcome.disposition, "retry")
    t.eq(outcome.reason_code, "invalid-title")
  end,

  test_generated_oversized_body_is_retryable_product_failure = function()
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        return {
          exit_code = 0,
          stdout = '{"title":"title","body":"' .. string.rep("x", generator.MAX_GENERATED_BODY_BYTES + 1) .. '"}',
        }
      end,
    }, {}, generated_slot, predecessor)
    t.eq(outcome.disposition, "retry")
    t.eq(outcome.reason_code, "invalid-body")
  end,

  test_generated_nonzero_exit_is_retryable_invocation_failure = function()
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        return { exit_code = 1, stderr = "service unavailable" }
      end,
    }, {}, generated_slot, predecessor)
    t.eq(outcome.disposition, "retry")
    t.eq(outcome.reason_code, "generator-codex-failed")
  end,

  test_generated_throw_is_retryable_invocation_failure = function()
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        error("service unavailable")
      end,
    }, {}, generated_slot, predecessor)
    t.eq(outcome.disposition, "retry")
    t.eq(outcome.reason_code, "generator-codex-failed")
  end,

  test_generated_missing_predecessor_fails_closed = function()
    local outcome = generator.run_slot_generator({
      spawn_codex = function()
        return {
          exit_code = 0,
          stdout = '{"title":"x","body":"y"}',
        }
      end,
    }, {}, generated_slot, nil)
    t.eq(outcome.disposition, "cannot_proceed")
    t.eq(outcome.reason_code, "missing-predecessor-result")
  end,

  test_generated_missing_runner_fails_closed = function()
    local outcome = generator.run_slot_generator({}, {}, generated_slot, predecessor)
    t.eq(outcome.disposition, "cannot_proceed")
    t.eq(outcome.reason_code, "missing-generator-runner")
  end,

  test_invalid_slot_and_content_kind_cannot_proceed = function()
    local invalid_slot = generator.run_slot_generator({}, {}, nil, predecessor)
    t.eq(invalid_slot.disposition, "cannot_proceed")
    t.eq(invalid_slot.reason_code, "invalid-slot")

    local unsupported = generator.run_slot_generator({}, {}, {
      content = { kind = "unknown" },
    }, predecessor)
    t.eq(unsupported.disposition, "cannot_proceed")
    t.eq(unsupported.reason_code, "unsupported-content-kind")
  end,
}

return tests
