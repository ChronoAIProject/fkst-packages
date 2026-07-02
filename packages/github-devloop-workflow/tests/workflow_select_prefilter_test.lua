local core = require("core")
local payloads_builders = require("devloop.payloads.builders")
local workflow_select = require("core.workflow_select")
local t = fkst.test

local function candidate()
  return payloads_builders.build_devloop_intake_candidate_payload(core, "owner/repo", 42, "2026-06-03T01:02:03Z")
end

local function ctx_with_comments(comments)
  local payload = candidate()
  return {
    candidate = payload,
    current = {
      comments = comments or {},
    },
    workflow_catalog_root = "/tmp/fkst-workflow-prefilter-empty",
  }
end

local function with_catalog_loader(loader, fn)
  local previous = workflow_select.load_catalog_for_ctx
  workflow_select.load_catalog_for_ctx = loader
  local ok, err = pcall(fn)
  workflow_select.load_catalog_for_ctx = previous
  if not ok then
    error(err, 0)
  end
end

local function blueprint(id, selector)
  return {
    id = id,
    summary = id .. " summary",
    applies_when = id .. " applies",
    selector = selector,
  }
end

return {
  test_existing_blueprint_is_the_only_handled_prefilter_path = function()
    local payload = candidate()
    local marker, err = core.marker.build_blueprint_marker(payload.proposal_id, "workflow-one", "digest-123")
    t.is_nil(err)
    t.is_true(core.marker.parse_blueprint_marker(marker, payload.proposal_id) ~= nil)

    t.eq(workflow_select.workflow_prefilter(ctx_with_comments({
      {
        body = marker,
        author_login = "fkst-test-bot",
      },
    })), true)

    t.eq(workflow_select.workflow_prefilter(ctx_with_comments({
      {
        body = marker,
        author_login = "someone-else",
      },
    })), false)

    t.eq(workflow_select.workflow_prefilter(ctx_with_comments({})), false)
  end,

  test_lineage_header_in_body_falls_through_before_catalog = function()
    local payload = candidate()
    local lineage, err = core.marker.build_lineage_header(payload.proposal_id, "d-1234567890", "slot-one")
    t.is_nil(err)

    with_catalog_loader(function()
      error("catalog should not load for workflow descendants")
    end, function()
      t.eq(workflow_select.workflow_prefilter({
        candidate = payload,
        current = {
          body = lineage .. "\n\nChild issue body.",
          comments = {},
        },
      }), false)
    end)
  end,

  test_lineage_header_in_trusted_comment_falls_through_before_catalog = function()
    local payload = candidate()
    local lineage, err = core.marker.build_lineage_header(payload.proposal_id, "d-1234567890", "slot-one")
    t.is_nil(err)

    with_catalog_loader(function()
      error("catalog should not load for workflow descendants")
    end, function()
      t.eq(workflow_select.workflow_prefilter({
        candidate = payload,
        current = {
          body = "ordinary body",
          comments = {
            {
              body = lineage,
              author_login = "fkst-test-bot",
            },
          },
        },
      }), false)
    end)
  end,

  test_absent_or_untrusted_lineage_does_not_short_circuit_prefilter = function()
    local payload = candidate()
    local lineage, err = core.marker.build_lineage_header(payload.proposal_id, "d-1234567890", "slot-one")
    t.is_nil(err)
    local catalog_reads = 0

    with_catalog_loader(function()
      catalog_reads = catalog_reads + 1
      return {
        valid = {},
        errors = {},
        duplicates = {},
      }, "/tmp"
    end, function()
      t.eq(workflow_select.workflow_prefilter({
        candidate = payload,
        current = {
          comments = {},
        },
      }), false)
      t.eq(workflow_select.workflow_prefilter({
        candidate = payload,
        current = {
          comments = {
            {
              body = lineage,
              author_login = "someone-else",
            },
          },
        },
      }), false)
    end)
    t.eq(catalog_reads, 2)
  end,

  test_origin_without_lineage_remains_selector_eligible = function()
    with_catalog_loader(function()
      return {
        valid = {
          matched = {
            path = "/tmp/workflow.json",
            blueprint = blueprint("matched", { labels_any = { "workflow" } }),
          },
        },
        errors = {},
        duplicates = {},
      }, "/tmp"
    end, function()
      local eligible = workflow_select.prefilter_eligible_blueprints({
        labels = { "workflow" },
      }, workflow_select.load_catalog_for_ctx({}))
      t.eq(#eligible, 1)
      t.eq(eligible[1].id, "matched")
    end)
  end,

  test_selector_prefilter_matches_labels_title_and_selectorless_blueprints = function()
    local catalog = {
      valid = {
        label = { blueprint = blueprint("label", { labels_any = { "workflow" } }) },
        title = { blueprint = blueprint("title", { title_contains_any = { "orchestrate" } }) },
        none = { blueprint = blueprint("none", nil) },
        empty = { blueprint = blueprint("empty", {}) },
        miss = { blueprint = blueprint("miss", { labels_any = { "other" }, title_contains_any = { "unrelated" } }) },
      },
    }

    local eligible = workflow_select.prefilter_eligible_blueprints({
      labels = { "workflow" },
      title = "Please orchestrate the release",
    }, catalog)
    local ids = {}
    for _, record in ipairs(eligible) do
      ids[#ids + 1] = record.id
    end

    t.eq(table.concat(ids, ","), "empty,label,none,title")
  end,

  test_catalog_root_resolution_accepts_injected_temp_root = function()
    local root = "/tmp/fkst-workflow-catalog-root-injected"
    t.eq(workflow_select.resolve_catalog_root({ workflow_catalog_root = root .. "/" }), root)
    t.eq(workflow_select.resolve_catalog_root({ catalog_root = root }), root)
  end,

  test_catalog_root_resolution_expands_home_when_env_root_is_absent = function()
    local calls = {}
    local root = workflow_select.resolve_catalog_root({
      exec = function(command)
        calls[#calls + 1] = command
        if command == 'printf %s "$FKST_WORKFLOW_CATALOG_ROOT"' then
          return { stdout = "", stderr = "", exit_code = 0 }
        end
        if command == 'printf %s "$HOME"' then
          return { stdout = "/tmp/fkst-workflow-home\n", stderr = "", exit_code = 0 }
        end
        return { stdout = "", stderr = "unexpected", exit_code = 1 }
      end,
    })

    t.eq(root, "/tmp/fkst-workflow-home/.fkst/workflow")
    t.eq(calls[1], 'printf %s "$FKST_WORKFLOW_CATALOG_ROOT"')
    t.eq(calls[2], 'printf %s "$HOME"')
  end,
}
