local devloop_base = require("devloop.base")
local context_bundle_identity = require("contract.context_bundle_identity")
local strings = require("contract.strings")
local h = require("tests.devloop_core_helpers")
local fixtures = require("tests.production_fixture_helpers")
require("tests.context_bundle_probe_helpers")
local core = h.core
local context_bundle = require("devloop.context_bundle")
local t = h.t
local max_bundle_file_len = 10 * 1024 * 1024

local function nonce()
  return tostring({}):gsub("[^%w._-]", "_")
end

local function runtime_root(name)
  return "/tmp/fkst-packages-test/github-devloop-context-bundle/" .. tostring(now()) .. "/" .. nonce() .. "/" .. name
end

local function run_probe(mode, root, extra_payload)
  local env = {
    FKST_RUNTIME_ROOT = root,
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
  }
  if mode == "content_redaction_whitelist_env" then
    env.FKST_DEVLOOP_MANAGED_BOT_LOGINS = "Managed-Bot[bot],space-bot"
    env.FKST_GITHUB_AUTHORIZED_LOGINS = "Trusted-User"
  end
  local payload = {
    env = env,
    mode = mode,
    root = root,
  }
  for key, value in pairs(extra_payload or {}) do
    payload[key] = value
  end
  local result = t.run_department("departments/test_context_bundle_probe/main.lua", {
    queue = "context_bundle_probe",
    payload = payload,
  }, {
    env = env,
  })
  t.eq(result.exit_code, 0)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "context_bundle_probe_result" or raised.queue == "github-devloop.context_bundle_probe_result" then
      return raised.payload
    end
  end
  error("missing context bundle probe result")
end

local function assert_valid_utf8(value)
  local ok, len = pcall(utf8.len, tostring(value or ""))
  t.is_true(ok and len ~= nil)
end

local function assert_consensus_safe_context_key(key)
  t.is_true(#key <= 180)
  t.is_true(#key <= 200)
  t.is_true(strings.is_path_safe_key(key, 200))
  t.is_true(key:sub(1, 1) ~= "/")
  t.is_nil(key:find("\\", 1, true))
  t.is_nil(key:find("%s"))
end

return {
  test_context_bundle_cache_keys_bound_realistic_pr_review_proposal_id = function()
    local proposal_id = "github-devloop/pr-review/ChronoAIProject/fkst-packages/2376452037/223/ready-consensus-github-devloop-issue-ChronoAIProject-fkst-packages-221-2026-06-10T20-13-08Z-2548858339"
    local version = proposal_id .. "/review/loop/17/review-meta/2026-06-10T21-14-55Z-9988776655"
    local bundle_key = context_bundle.context_bundle_key(proposal_id, version)
    local manifest_key = context_bundle.context_bundle_manifest_key(proposal_id, version)

    assert_consensus_safe_context_key(bundle_key)
    assert_consensus_safe_context_key(manifest_key)
  end,

  test_context_bundle_cache_keys_keep_long_proposal_ids_distinct = function()
    local proposal_a = "github-devloop/pr-review/ChronoAIProject/fkst-packages/2376452037/223/ready-consensus-github-devloop-issue-ChronoAIProject-fkst-packages-221-2026-06-10T20-13-08Z-2548858339"
    local proposal_b = "github-devloop/pr-review/ChronoAIProject/fkst-packages/2376452037/223/ready-consensus-github-devloop-issue-ChronoAIProject-fkst-packages-221-2026-06-10T20-13-08Z-0000000000"
    local version = "review-loop-2026-06-10T21-14-55Z"

    t.is_true(context_bundle.context_bundle_key(proposal_a, version) ~= context_bundle.context_bundle_key(proposal_b, version))
    t.is_true(context_bundle.context_bundle_manifest_key(proposal_a, version) ~= context_bundle.context_bundle_manifest_key(proposal_b, version))
  end,

  test_context_bundle_cache_keys_keep_short_id_behavior = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "v1"

    t.eq(context_bundle.context_bundle_key(proposal_id, version), "github-devloop/context-bundle-v2/github-devloop/issue/owner/repo/42/v1")
    t.eq(context_bundle.context_bundle_manifest_key(proposal_id, version), "github-devloop/context-bundle-manifest-v2/github-devloop/issue/owner/repo/42/v1")
  end,

  test_context_bundle_identity_directory_segment_boundaries_are_canonical = function()
    local prefix = context_bundle_identity.manifest_cache_prefix
    for _, length in ipairs({ 119, 120, 121 }) do
      local proposal_id = string.rep("p", length)
      local identity = context_bundle_identity.from_values(proposal_id, "v1", prefix)
      local parsed = context_bundle_identity.from_key(identity.key, prefix)

      t.eq(parsed.proposal_directory_segment, identity.proposal_directory_segment)
      t.is_true(#identity.proposal_directory_segment <= 120)
      if length <= 120 then
        t.eq(identity.proposal_directory_segment, proposal_id)
      else
        t.eq(#identity.proposal_directory_segment, 120)
        t.is_true(identity.proposal_directory_segment:find("-" .. strings.decimal_checksum(proposal_id), 1, true) ~= nil)
      end
    end
  end,

  test_context_bundle_identity_whole_key_budget_boundaries_are_canonical = function()
    local prefix = context_bundle_identity.manifest_cache_prefix
    local version = "2026-08-07T12-34-56Z-loop-17"
    local proposal_limit = context_bundle_identity.max_cache_key_len - #prefix - 1 - #version
    for _, length in ipairs({ proposal_limit - 1, proposal_limit, proposal_limit + 1 }) do
      local proposal_id = string.rep("q", length)
      local identity = context_bundle_identity.from_values(proposal_id, version, prefix)
      local parsed = context_bundle_identity.from_key(identity.key, prefix)

      t.eq(#identity.key <= context_bundle_identity.max_cache_key_len, true)
      t.eq(parsed.proposal_directory_segment, identity.proposal_directory_segment)
      if length <= proposal_limit then
        t.eq(identity.proposal_key_segment, proposal_id)
      else
        t.eq(#identity.proposal_key_segment, proposal_limit)
        t.is_true(identity.proposal_key_segment:find("-" .. strings.decimal_checksum(proposal_id), 1, true) ~= nil)
      end
    end
  end,

  test_context_bundle_identity_version_segment_boundaries_are_canonical = function()
    local prefix = context_bundle_identity.manifest_cache_prefix
    for _, length in ipairs({ 59, 60, 61 }) do
      local version = string.rep("v", length)
      local identity = context_bundle_identity.from_values("github-devloop/issue/owner/repo/42", version, prefix)
      local parsed = context_bundle_identity.from_key(identity.key, prefix)

      t.eq(parsed.version_directory_segment, identity.version_directory_segment)
      if length <= context_bundle_identity.max_version_segment_len then
        t.eq(identity.version_key_segment, version)
      else
        t.eq(#identity.version_key_segment, context_bundle_identity.max_version_segment_len)
        t.is_true(identity.version_key_segment:find("-" .. strings.decimal_checksum(version), 1, true) ~= nil)
      end
    end
  end,

  test_production_length_bundle_ref_rebuilds_from_current_root_with_empty_cache = function()
    local proposal_prefix = "github-devloop/issue/owner/repo/2026-08-07T12-34-56Z/loop/17/"
    local proposal_id = proposal_prefix .. string.rep("x", 118 - #proposal_prefix)
    local version = "2026-08-07T12-34-56Z-loop-17"
    local root = runtime_root("production-length-rebuild")
    local manifest_key = context_bundle.context_bundle_manifest_key(proposal_id, version)
    local relative_key = manifest_key:match("^github%-devloop/context%-bundle%-manifest%-v2/(.+)$")
    local key_proposal_segment = relative_key and relative_key:match("^(.*)/[^/]+$")

    t.eq(#proposal_id, 118)
    t.is_true(type(key_proposal_segment) == "string")
    t.is_true(#key_proposal_segment < #strings.sanitize_key(proposal_id, false))

    local materialized = run_probe("production_length_materialize", root, {
      proposal_id = proposal_id,
      version = version,
    })
    t.eq(materialized.ref, context_bundle.context_bundle_manifest_ref(manifest_key))
    t.eq(materialized.notice_exists, true)
    t.eq(materialized.issue_exists, true)
    t.eq(materialized.board_exists, true)

    local resolved = run_probe("production_length_resolve", root, {
      ref = materialized.ref,
    })
    if not resolved.ok then
      t.is_true(resolved.error:find("error_class=stale_generation_context", 1, true) ~= nil)
    end
    t.eq(resolved.ok, true)
    t.is_true(resolved.manifest:find(materialized.dir, 1, true) ~= nil)
    t.eq(resolved.cache_writes, 1)
  end,

  test_production_length_version_bundle_ref_rebuilds_with_empty_cache = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version_prefix = "2026-08-07T12-34-56Z/loop/19/"
    local version = version_prefix .. string.rep("s", 61 - #version_prefix)
    local root = runtime_root("production-length-version-rebuild")
    local manifest_key = context_bundle.context_bundle_manifest_key(proposal_id, version)
    local key_version_segment = manifest_key:match("([^/]+)$")

    t.eq(#version, 61)
    t.is_true(type(key_version_segment) == "string")
    t.is_true(#key_version_segment < #strings.sanitize_key(version, false))

    local materialized = run_probe("production_length_materialize", root, {
      proposal_id = proposal_id,
      version = version,
    })
    local resolved = run_probe("production_length_resolve", root, {
      ref = materialized.ref,
    })

    t.eq(resolved.ok, true)
    t.is_true(resolved.manifest:find(materialized.dir, 1, true) ~= nil)
  end,

  test_production_length_redrive_rebuilds_only_from_rotated_current_root = function()
    local proposal_prefix = "github-devloop/issue/owner/repo/2026-08-07T12-34-56Z/loop/18/"
    local proposal_id = proposal_prefix .. string.rep("r", 118 - #proposal_prefix)
    local version = "2026-08-07T12-34-56Z-loop-18"
    local rotation_root = runtime_root("production-length-root-rotation")
    local old_root = rotation_root .. "/root-a"
    local fresh_root = rotation_root .. "/root-b"
    local identity = {
      proposal_id = proposal_id,
      version = version,
    }

    local old = run_probe("production_length_materialize", old_root, identity)
    local fresh = run_probe("production_length_materialize", fresh_root, identity)
    t.eq(old.ref, fresh.ref)
    t.is_true(old.dir:find(old_root, 1, true) == 1)
    t.is_true(fresh.dir:find(fresh_root, 1, true) == 1)

    local resolved = run_probe("production_length_resolve", fresh_root, {
      ref = fresh.ref,
      forbidden_root = old_root,
    })
    t.eq(resolved.ok, true)
    t.eq(resolved.forbidden_reads, 0)
    t.eq(resolved.listed_root, fresh_root .. "/context")
    t.is_true(resolved.manifest:find(fresh.dir, 1, true) ~= nil)
    t.is_nil(resolved.manifest:find(old.dir, 1, true))
  end,

  test_context_bundle_files_round_trip_from_different_cwd = function()
    local result = run_probe("round_trip", runtime_root("round-trip"))

    t.eq(#result.paths, 6)
    t.is_true(result.manifest:find("UNTRUSTED-NOTICE.txt", 1, true) ~= nil)
    t.is_true(result.manifest:find("bytes):", 1, true) ~= nil)
    t.is_true(result.manifest:find("Files may be large; read them in segments as needed.", 1, true) ~= nil)
    t.is_true(result.notice_content:find("BEGIN UNTRUSTED BUNDLE DATA", 1, true) == 1)
    t.is_true(result.issue_content:find("{", 1, true) == 1)
    t.is_nil(result.issue_content:find(core._untrusted_issue_data_begin, 1, true))
  end,

  test_context_bundle_redacts_external_comment_and_preserves_bot_comment = function()
    local result = run_probe("content_redaction", runtime_root("content-redaction"))

    t.eq(result.ok, true)
    t.eq(result.issue_title, "Bundle issue")
    t.eq(result.issue_body, "Full issue body")
    t.is_true(result.external_comment_body:find("[fkst:blocked-github-content:v1", 1, true) == 1)
    t.is_nil(result.external_comment_body:find("evil", 1, true))
    t.eq(result.bot_comment_body, result.bot_expected)
    t.is_true(result.issue_content:find("github-devloop:state:v1", 1, true) ~= nil)
  end,

  test_context_bundle_redacts_pr_comment_and_preserves_bot_comment = function()
    local result = run_probe("pr_content_redaction", runtime_root("pr-content-redaction"))

    t.eq(result.ok, true)
    t.eq(result.pr_title, "PR title")
    t.eq(result.pr_body, "PR body")
    t.is_true(result.external_comment_body:find("[fkst:blocked-github-content:v1", 1, true) == 1)
    t.is_nil(result.external_comment_body:find("evil", 1, true))
    t.eq(result.bot_comment_body, result.bot_expected)
    t.is_true(result.pr_content:find("github-devloop:review-result:v1", 1, true) ~= nil)
  end,

  test_context_bundle_whitelist_env_expands_authorized_comment_sources = function()
    local result = run_probe("content_redaction_whitelist_env", runtime_root("content-redaction-whitelist-env"))

    t.eq(result.ok, true)
    t.eq(result.managed_comment_body, "managed bot comment")
    t.eq(result.authorized_comment_body, "authorized operator comment")
    t.is_true(result.external_comment_body:find("[fkst:blocked-github-content:v1", 1, true) == 1)
    t.is_nil(result.external_comment_body:find("external payload", 1, true))
  end,

  test_context_bundle_unreadable_optional_whitelist_env_degrades_to_bot_only = function()
    local result = run_probe("content_redaction_optional_env_unreadable", runtime_root("content-redaction-optional-env-unreadable"))

    t.eq(result.ok, true)
    t.eq(result.bot_comment_body, "bot comment")
    t.is_true(result.optional_comment_body:find("[fkst:blocked-github-content:v1", 1, true) == 1)
    t.is_nil(result.optional_comment_body:find("optional comment", 1, true))
  end,

  test_context_bundle_content_filter_requires_bot_login = function()
    local result = run_probe("content_redaction_requires_bot", runtime_root("content-redaction-requires-bot"))

    t.eq(result.ok, false)
    t.is_true(result.error:find("FKST_GITHUB_BOT_LOGIN is required for context bundle content provenance", 1, true) ~= nil)
  end,

  test_context_bundle_cache_hit_with_deleted_file_rebuilds = function()
    local result = run_probe("deleted_file", runtime_root("deleted-file"))

    t.is_true(result.second_dir ~= result.first_dir)
    t.is_true(result.second_dir:find(result.first_dir .. ".publish-", 1, true) == 1)
    t.is_true(result.issue_content:find("Second issue", 1, true) ~= nil)
    t.eq(result.issue_fetch_count, 2)
  end,

  test_context_bundle_reuses_preexisting_final_dir_after_validation = function()
    local result = run_probe("preexisting", runtime_root("preexisting-final"))

    t.eq(result.dir, result.expected_dir)
    t.is_true(result.issue_content:find("preexisting issue", 1, true) ~= nil)
    t.is_true(result.manifest:find("UNTRUSTED-NOTICE.txt", 1, true) ~= nil)
    t.eq(result.issue_fetch_count, 0)
  end,

  test_context_bundle_second_publish_reuses_valid_final_dir = function()
    local result = run_probe("publish_reuse", runtime_root("publish-reuse"))

    t.eq(result.second_dir, result.first_dir)
    t.eq(result.fetches_after_first, 1)
    t.eq(result.fetches_after_second, 1)
    t.eq(result.notice_unchanged, true)
    t.eq(result.issue_unchanged, true)
    t.eq(result.board_unchanged, true)
  end,

  test_context_bundle_second_publish_uses_unique_dir_when_final_invalid = function()
    local result = run_probe("publish_unique_on_invalid", runtime_root("publish-unique-invalid"))

    t.is_true(result.dir ~= result.original_dir)
    t.is_true(result.dir:find(result.original_dir .. ".publish-", 1, true) == 1)
    t.eq(result.issue_fetch_count, 2)
    t.eq(result.original_notice_absent, true)
    t.eq(result.original_issue_unchanged, true)
    t.eq(result.original_board_unchanged, true)
    t.is_true(result.rebuilt_issue:find("Rebuilt issue", 1, true) ~= nil)
    t.eq(result.has_notice, true)
    t.is_true(result.manifest:find("UNTRUSTED-NOTICE.txt", 1, true) ~= nil)
  end,

  test_context_bundle_file_cap_truncates_on_utf8_boundary = function()
    local result = run_probe("utf8_truncation", runtime_root("utf8-truncation"))

    t.is_true(result.issue_bytes <= max_bundle_file_len)
    t.is_true(result.issue_bytes > max_bundle_file_len - 16)
    assert_valid_utf8(result.issue_content)
  end,

  test_stale_generation_manifest_file_loss_is_terminal_class = function()
    local result = run_probe("stale_manifest_files", runtime_root("stale-manifest-files"))

    t.eq(result.ok, false)
    t.eq(result.stale, true)
    t.eq(result.class, "stale_generation_context")
    t.is_true(result.error:find("context bundle manifest files are unreadable", 1, true) ~= nil)
  end,

  test_context_fetch_ref_preserves_unknown_risk_classification = function()
    local result = run_probe("unknown_risk_structured", runtime_root("unknown-risk-structured"))

    t.is_true(tostring(result.ref or ""):find("runtime-cache:", 1, true) == 1)
    t.eq(result.high_risk, true)
    t.eq(result.risk_known, false)
    t.eq(result.risk_high, true)
    t.eq(result.risk_reason, "diff-name-only-failed")
    t.eq(result.high_risk_path_count, 0)
    t.eq(result.diff_name_fetch_count, 1)
  end,

  test_stale_generation_classifier_accepts_consensus_manifest_errors = function()
    t.eq(context_bundle.is_stale_generation_context_error("consensus: runtime context cache miss"), true)
    t.eq(context_bundle.is_stale_generation_context_error("consensus: runtime context manifest file is unreadable"), true)
  end,

  test_stale_generation_replayer_rebuilds_manifest_after_runtime_swap = function()
    local result = run_probe("stale_manifest_rebuild", runtime_root("stale-manifest-rebuild"))

    t.eq(result.stale_ok, false)
    t.eq(result.stale, true)
    t.eq(result.same_ref, true)
    t.eq(result.fresh_fetch_count, 1)
    t.is_true(result.fresh_manifest:find("/fresh/context/", 1, true) ~= nil)
    t.is_true(result.fresh_manifest:find("Fresh issue", 1, true) == nil)
  end,

  test_context_bundle_manifest_key_accepts_full_pr_review_proposal_id = function()
    local repo = fixtures.long_repo()
    local version = fixtures.full_review_issue_version(repo)
    local proposal_id = devloop_base.pr_review_proposal_id(repo, 187, version, fixtures.review_head_sha())
    local manifest_key = context_bundle.context_bundle_manifest_key(proposal_id, version)
    local bundle_key = context_bundle.context_bundle_key(proposal_id, version)

    t.is_true(#fixtures.unbounded_full_review_proposal_id() > core._max_key_len)
    t.is_true(#proposal_id <= core._max_key_len)
    t.is_true(context_bundle.context_bundle_key("github-devloop/issue/owner/repo/42", "owner/repo#issue#42@2026-06-03T01:02:03Z"):find("#", 1, true) == nil)
    t.is_true(#manifest_key <= core._max_key_len)
    t.is_true(#bundle_key <= core._max_key_len)
    t.eq(strings.is_path_safe_key(manifest_key, core._max_key_len), true)
    t.eq(strings.is_path_safe_key(bundle_key, core._max_key_len), true)
    t.is_true(manifest_key:find("^github%-devloop/context%-bundle%-manifest%-v2/") ~= nil)
    t.is_true(bundle_key:find("^github%-devloop/context%-bundle%-v2/") ~= nil)
  end,
}
