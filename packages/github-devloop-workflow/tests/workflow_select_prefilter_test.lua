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
}
