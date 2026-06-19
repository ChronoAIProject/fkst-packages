local core = require("core")
local t = fkst.test

local finding_json = '[{"file":"packages/idle-detector/core.lua","line":1,"rule":"SRP","why":"Mixed responsibilities.","suggested_fix":"Extract the extra responsibility."}]'

return {
  test_parse_findings_accepts_strict_array = function()
    local parsed = core.parse_findings_json(finding_json)
    t.eq(#parsed, 1)
    t.eq(parsed[1].file, "packages/idle-detector/core.lua")
    t.eq(parsed[1].line, 1)
    t.eq(parsed[1].rule, "SRP")
  end,

  test_parse_findings_rejects_non_json_and_extra_shape = function()
    t.raises(function() core.parse_findings_json("not json") end)
    t.raises(function() core.parse_findings_json('{"file":"x"}') end)
    t.raises(function() core.parse_findings_json('"scalar"') end)
    t.raises(function() core.parse_findings_json("42") end)
    t.raises(function() core.parse_findings_json('[{"file":"x","line":"bad","rule":"SRP","why":"w","suggested_fix":"f"}]') end)
  end,

  test_parse_findings_accepts_legitimate_empty_array = function()
    local parsed = core.parse_findings_json("[]")
    t.eq(#parsed, 0)
  end,

  test_validate_finding_checks_file_and_line = function()
    local finding = core.parse_findings_json(finding_json)[1]
    t.eq(core.validate_finding(finding), true)
    finding.line = 999999
    t.eq(core.validate_finding(finding), false)
  end,

  test_dedup_key_is_stable_and_bounded = function()
    local key = core.dedup_key("owner/repo", {
      file = "packages/idle-detector/core.lua",
      line = 1,
      rule = "SRP",
    })
    t.eq(key, core.dedup_key("owner/repo", {
      file = "packages/idle-detector/core.lua",
      line = 1,
      rule = "SRP",
    }))
    t.is_true(key:find("archaudit/owner/repo/packages/idle-detector/core.lua/1/SRP/", 1, true) == 1)
  end,

  test_issue_request_shape_matches_github_proxy_contract = function()
    local finding = core.parse_findings_json(finding_json)[1]
    local payload = core.build_issue_create_request("owner/repo", finding, true)
    t.eq(payload.schema, "github-proxy.issue-create.v1")
    t.eq(payload.repo, "owner/repo")
    t.eq(payload.title, "Archaudit: packages/idle-detector/core.lua:1 SRP")
    t.eq(payload.labels[1], "archaudit")
    t.eq(payload.source_ref.kind, "repo-site")
    t.eq(payload.source_ref.ref, "owner/repo#packages/idle-detector/core.lua:1#archaudit-create-intent")
    t.is_true(payload.body:find("archaudit-dedup: " .. payload.dedup_key, 1, true) ~= nil)
  end,

  test_issue_request_rejects_overlong_source_ref_from_long_file_path = function()
    local long_file = "packages/" .. string.rep("longsegment/", 15) .. "core.lua"
    t.raises(function()
      core.build_issue_create_request("owner/repo", {
        file = long_file,
        line = 1,
        rule = "SRP",
        why = "Concrete issue.",
        suggested_fix = "Small fix.",
      }, true)
    end)
  end,

  test_issue_request_rejects_long_or_malformed_repo = function()
    local finding = core.parse_findings_json(finding_json)[1]
    t.raises(function() core.build_issue_create_request("owner/" .. string.rep("r", 201), finding, true) end)
    t.raises(function() core.build_issue_create_request("owner repo", finding, true) end)
  end,

  test_issue_request_omits_missing_label = function()
    local finding = core.parse_findings_json(finding_json)[1]
    local payload = core.build_issue_create_request("owner/repo", finding, false)
    t.eq(#payload.labels, 0)
  end,

  test_freshness_and_expiry_verdicts_are_pure_and_deterministic = function()
    local detected = core.iso_timestamp_epoch_seconds("2026-06-19T01:00:00Z")
    local expires = core.iso_timestamp_epoch_seconds("2026-06-19T01:10:00Z")
    local expires_past_while_detected_fresh = core.iso_timestamp_epoch_seconds("2026-06-19T01:02:00Z")
    t.eq(core.idle_hint_freshness(detected, nil, detected + 60, 600), "fresh")
    t.eq(core.idle_hint_freshness(detected, expires, detected + 60, 600), "fresh")
    t.eq(core.idle_hint_freshness(detected, nil, detected + 600, 600), "fresh")
    t.eq(core.idle_hint_freshness(detected, expires, detected + 601, 600), "stale")
    t.eq(core.idle_hint_freshness(detected, expires, expires, 600), "expired")
    t.eq(core.idle_hint_freshness(detected, expires_past_while_detected_fresh, detected + 180, 600), "expired")
    t.eq(core.idle_hint_freshness(detected, detected - 1, detected, 600), "expired")
    t.raises(function() core.idle_hint_freshness(nil, expires, detected, 600) end)
    t.raises(function() core.idle_hint_freshness(detected, nil, nil, 600) end)
  end,

  test_observe_predicate_fails_closed_on_missing_each_busy_dimension_group = function()
    for _, row in ipairs({
      { queue = "proposal", leased = 0, retry = 0, dlq = 0 },
      { queue = "proposal", ready = 0, retry = 0, dlq = 0 },
      { queue = "proposal", ready = 0, leased = 0, dlq = 0 },
      { queue = "proposal", ready = 0, leased = 0, retry = 0 },
    }) do
      t.raises(function()
        core.is_idle_observe({ schema = "fkst.observe.v1", queues = { row }, anomalies = {}, dlq = {} })
      end)
    end
  end,

  test_observe_predicate_fails_closed_on_non_dense_observe_lists = function()
    for _, list_name in ipairs({ "queues", "anomalies", "dlq" }) do
      local keyed = {
        schema = "fkst.observe.v1",
        queues = { { queue = "proposal", ready = 0, leased = 0, retry = 0, dlq = 0 } },
        anomalies = {},
        dlq = {},
      }
      keyed[list_name] = { keyed = {} }
      t.raises(function() core.is_idle_observe(keyed) end)

      local sparse = {
        schema = "fkst.observe.v1",
        queues = { { queue = "proposal", ready = 0, leased = 0, retry = 0, dlq = 0 } },
        anomalies = {},
        dlq = {},
      }
      sparse[list_name] = {}
      sparse[list_name][1] = {}
      sparse[list_name][3] = {}
      t.raises(function() core.is_idle_observe(sparse) end)
    end
  end,

  test_observe_predicate_fails_closed_on_ambiguous_and_unknown_metric_groups = function()
    t.raises(function()
      core.is_idle_observe({
        schema = "fkst.observe.v1",
        queues = { { queue = "proposal", ready = 0, pending = 0, leased = 0, retry = 0, dlq = 0 } },
        anomalies = {},
        dlq = {},
      })
    end)
    t.raises(function()
      core.is_idle_observe({
        schema = "fkst.observe.v1",
        queues = { { queue = "proposal", unexpected = 0 } },
        anomalies = {},
        dlq = {},
      })
    end)
  end,

  test_skip_fact_fields_are_pure_and_structured = function()
    for _, why in ipairs({
      "stale system_idle hint",
      "expired system_idle hint",
      "observe-unreadable: observe failed",
      "current observe busy ready=1",
      "current observe dlq>0",
    }) do
      local fact = core.skip_fact("audit", {
        queue = "idle-detector.system_idle",
        payload = {
          source_ref = { kind = "host-observe", ref = "idle_tick/2026-06-19T01:00:00Z" },
        },
      }, why, true)
      t.is_true(fact:find("tag=SKIP", 1, true) ~= nil)
      t.is_true(fact:find("error_class=terminal-skip", 1, true) ~= nil)
      t.is_true(fact:find("source_ref=host-observe:idle_tick/2026-06-19T01:00:00Z", 1, true) ~= nil)
      t.is_true(fact:find("terminal=true", 1, true) ~= nil)
      t.is_true(fact:find("WHY=" .. why, 1, true) ~= nil)
    end
  end,

  test_failure_fact_fields_are_pure_distinct_and_structured = function()
    local fingerprints = {}
    for _, case in ipairs({
      { class = "missing-repo", why = "missing FKST_GITHUB_REPO" },
      { class = "malformed-repo", why = "malformed FKST_GITHUB_REPO" },
      { class = "codex-timeout", why = "codex timeout" },
      { class = "codex-nonzero", why = "codex nonzero exit" },
      { class = "malformed-json", why = "codex output is malformed JSON" },
      { class = "non-array-json", why = "codex output is not a JSON array" },
      { class = "validation-failure", why = "invalid file or line" },
      { class = "observe-malformed", why = "observe malformed or unknown shape" },
    }) do
      local fact = core.failure_fact("audit", "FAILURE", case.class, {
        queue = "idle-detector.system_idle",
        payload = {
          source_ref = { kind = "host-observe", ref = "idle_tick/2026-06-19T01:00:00Z" },
        },
      }, case.why, true)
      t.is_true(fact:find("tag=FAILURE", 1, true) ~= nil)
      t.is_true(fact:find("error_class=" .. case.class, 1, true) ~= nil)
      t.is_true(fact:find("source_ref=host-observe:idle_tick/2026-06-19T01:00:00Z", 1, true) ~= nil)
      t.is_true(fact:find("terminal=true", 1, true) ~= nil)
      t.is_true(fact:find("WHY=" .. case.why, 1, true) ~= nil)
      local fingerprint = fact:match("fingerprint=([^%s]+)")
      t.is_true(fingerprint ~= nil and fingerprints[fingerprint] == nil)
      fingerprints[fingerprint] = true
    end
  end,
}
