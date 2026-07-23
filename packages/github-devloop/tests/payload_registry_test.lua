local base_ids = require("devloop.base_ids")
local payload_registry = require("devloop.payload_registry")
local payloads_builders = require("devloop.payloads.builders")

local t = fkst.test

local function assert_rejected(token, message)
  local ok, failure = pcall(payload_registry.validate, token)
  t.eq(ok, false)
  t.is_true(tostring(failure):find(message, 1, true) ~= nil)
end

return {
  test_validate_accepts_only_registered_tokens = function()
    t.eq(payload_registry.validate("dedup:ready"), true)
    t.eq(payload_registry.validate("dedup:reviewing"), true)
    t.eq(payload_registry.validate("literal:github-devloop.ready.v1"), true)
    t.eq(payload_registry.validate("literal:github-devloop.reviewing.v1"), true)
    t.eq(payload_registry.validate("literal:github-devloop.review-meta.v1"), true)
    t.eq(payload_registry.validate("literal:github-devloop.merge-ready.v1"), true)
    t.eq(payload_registry.validate("literal:consensus.proposal.v1"), true)
    t.eq(payload_registry.validate("source_ref:normalized"), true)
    t.eq(payload_registry.validate("marker:state.version"), true)
    assert_rejected("unknown:ready", "unknown prefix unknown")
    assert_rejected("dedup:unregistered", "unknown dedup strategy unregistered")
    assert_rejected("literal:github-devloop.unregistered.v1", "unknown literal value github-devloop.unregistered.v1")
    assert_rejected("source_ref:unregistered", "unknown source_ref derivation unregistered")
    assert_rejected("marker:unregistered.value", "unknown marker family unregistered")
    assert_rejected("marker:state.unregistered", "unknown marker attr state.unregistered")
  end,

  test_resolve_returns_missing_evidence_without_partial_value = function()
    local value, failure = payload_registry.resolve("dedup:ready", {})
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")

    value, failure = payload_registry.resolve("dedup:reviewing", {
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = "ready/version",
    })
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")

    value, failure = payload_registry.resolve("source_ref:normalized", {})
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")

    value, failure = payload_registry.resolve("marker:state.version", {})
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")

    value, failure = payload_registry.resolve("marker:state.version", { state = {} })
    t.eq(value, nil)
    t.eq(failure, "missing-evidence")
  end,

  test_state_marker_version_builder_reads_are_byte_exact_with_previous_expression = function()
    local origin = {
      repo = "owner/repo",
      proposal_id = "github-devloop/issue/owner/repo/42",
    }
    local pr_number = 17
    local source_ref = { kind = "external", ref = "owner/repo#pr/17" }
    local versions = {
      "ready/version",
      "ready/version/fix/2",
      "ready/version/review-loop/3",
    }

    for _, previous in ipairs(versions) do
      local state = { version = previous }
      local resolved, failure = payload_registry.resolve("marker:state.version", {
        state = state,
      })
      t.eq(failure, nil)
      t.eq(resolved, previous)

      local payload = payloads_builders.build_current_head_reviewing_payload(origin, pr_number, {
        head_sha = "abcdef1",
        comments = {},
      }, state, source_ref)
      t.eq(payload.version, previous)
      t.eq(payload.dedup_key, base_ids.dedup_key({
        "reviewing",
        tostring(origin.proposal_id),
        tostring(previous),
        tostring(pr_number),
      }))
    end
  end,

  test_literal_schema_builders_are_byte_exact_with_previous_values = function()
    local source_ref = { kind = "external", ref = "owner/repo#issue/42" }
    local fixtures = {
      {
        token = "literal:github-devloop.ready.v1",
        previous = "github-devloop.ready.v1",
        build = function()
          return payloads_builders.build_devloop_ready_payload({
            _max_impl_retry_attempts = 3,
          }, {
            proposal_id = "github-devloop/issue/owner/repo/42",
            dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-07-23T01-02-03Z",
            source_ref = source_ref,
          })
        end,
      },
      {
        token = "literal:github-devloop.reviewing.v1",
        previous = "github-devloop.reviewing.v1",
        build = function()
          return payloads_builders.build_devloop_reviewing_payload({
            proposal_id = "github-devloop/issue/owner/repo/42",
            impl_version = "ready/version",
          }, 17, source_ref)
        end,
      },
      {
        token = "literal:github-devloop.review-meta.v1",
        previous = "github-devloop.review-meta.v1",
        build = function()
          return payloads_builders.build_devloop_review_meta_payload({
            proposal_id = "review/proposal/17",
            dedup_key = "review/dedup/17",
            source_ref = source_ref,
          }, "github-devloop/issue/owner/repo/42", "ready/version", 17, 2)
        end,
      },
      {
        token = "literal:github-devloop.merge-ready.v1",
        previous = "github-devloop.merge-ready.v1",
        build = function()
          return payloads_builders.build_devloop_merge_ready_payload(
            "github-devloop/issue/owner/repo/42",
            17,
            "ready/version",
            { review_dedup_key = "review/dedup/17" },
            source_ref
          )
        end,
      },
      {
        token = "literal:consensus.proposal.v1",
        previous = "consensus.proposal.v1",
        build = function()
          return payloads_builders.build_proposal({
            repo = "owner/repo",
            number = 42,
            title = "Literal schema parity",
            updated_at = "2026-07-23T01:02:03Z",
            source_ref = source_ref,
          })
        end,
      },
      {
        token = "literal:consensus.proposal.v1",
        previous = "consensus.proposal.v1",
        build = function()
          return payloads_builders.build_pr_review_proposal({
            _max_title_len = 200,
            _max_body_len = 2000,
            short_review_observation_boundary_clause = function()
              return "Review only the named issue requirements."
            end,
          }, "owner/repo", 42, 17, "ready/version", "abcdef1", {
            title = "Literal schema parity",
          }, {
            kind = "external",
            ref = "owner/repo#pr/17",
          }, {})
        end,
      },
    }

    for _, fixture in ipairs(fixtures) do
      local resolved, failure = payload_registry.resolve(fixture.token, nil)
      t.eq(failure, nil)
      t.eq(resolved, fixture.previous)
      t.eq(fixture.build().schema, fixture.previous)
    end
  end,

  test_normalized_source_ref_builders_are_byte_exact_with_previous_expression = function()
    local source_ref = { kind = "external", ref = "owner/repo#issue/42" }
    local previous = base_ids.normalize_source_ref(source_ref)
    local fixtures = {
      function()
        return payloads_builders.build_devloop_ready_payload({
          _max_impl_retry_attempts = 3,
        }, {
          proposal_id = "github-devloop/issue/owner/repo/42",
          dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-07-23T01-02-03Z",
          source_ref = source_ref,
        })
      end,
      function()
        return payloads_builders.build_devloop_reviewing_payload({
          proposal_id = "github-devloop/issue/owner/repo/42",
          impl_version = "ready/version",
        }, 17, source_ref)
      end,
      function()
        return payloads_builders.build_devloop_fixing_payload({
          proposal_id = "github-devloop/issue/owner/repo/42",
          impl_version = "ready/version",
        }, 17, {
          review_proposal_id = "review/proposal/17",
          review_dedup_key = "review/dedup/17",
          reviewed_head_sha = "abcdef1",
        }, source_ref)
      end,
      function()
        return payloads_builders.build_devloop_review_meta_payload({
          proposal_id = "review/proposal/17",
          dedup_key = "review/dedup/17",
        }, "github-devloop/issue/owner/repo/42", "ready/version", 17, 2, source_ref)
      end,
      function()
        return payloads_builders.build_devloop_merge_ready_payload(
          "github-devloop/issue/owner/repo/42",
          17,
          "ready/version",
          { review_dedup_key = "review/dedup/17" },
          source_ref
        )
      end,
      function()
        return payloads_builders.build_devloop_decompose_payload({
          proposal_id = "github-devloop/issue/owner/repo/42",
          pr_number = 17,
          issue_version = "ready/version",
          review_proposal_id = "review/proposal/17",
          review_dedup_key = "review/dedup/17",
          head_sha = "abcdef1",
          round = 2,
          source_ref = source_ref,
        })
      end,
      function()
        return payloads_builders.build_proposal({
          repo = "owner/repo",
          number = 42,
          title = "Source ref parity",
          updated_at = "2026-07-23T01:02:03Z",
          source_ref = source_ref,
        })
      end,
      function()
        return payloads_builders.build_pr_review_proposal({
          _max_title_len = 200,
          _max_body_len = 2000,
          short_review_observation_boundary_clause = function()
            return "Review only the named issue requirements."
          end,
        }, "owner/repo", 42, 17, "ready/version", "abcdef1", {
          title = "Source ref parity",
        }, source_ref, {})
      end,
    }

    local resolved, failure = payload_registry.resolve("source_ref:normalized", {
      source_ref = source_ref,
    })
    t.eq(failure, nil)
    t.eq(resolved.kind, previous.kind)
    t.eq(resolved.ref, previous.ref)

    for _, build in ipairs(fixtures) do
      local actual = build().source_ref
      t.eq(actual.kind, previous.kind)
      t.eq(actual.ref, previous.ref)
    end
  end,

  test_ready_builder_dedup_is_byte_exact_with_previous_expression = function()
    local source = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-07-23T01-02-03Z",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    }
    local payload = payloads_builders.build_devloop_ready_payload({
      _max_impl_retry_attempts = 3,
    }, source)
    local previous = base_ids.dedup_key({
      "ready",
      tostring(source.dedup_key),
    })
    t.eq(payload.dedup_key, previous)
  end,

  test_reviewing_builder_dedup_is_byte_exact_with_previous_expression = function()
    local origin = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      impl_version = "ready/version",
    }
    local pr_number = 17
    local payload = payloads_builders.build_devloop_reviewing_payload(
      origin,
      pr_number,
      { kind = "external", ref = "owner/repo#pr/17" }
    )
    local previous = base_ids.dedup_key({
      "reviewing",
      tostring(origin.proposal_id),
      tostring(origin.impl_version),
      tostring(pr_number),
    })
    t.eq(payload.dedup_key, previous)
  end,
}
