local marker = require("core.marker")
local t = fkst.test

local origin = "github-devloop/issue/owner/repo/42"
local workflow_id = "workflow-one"
local digest = "d-1234567890"

local function build_or_error(origin_proposal_id, workflow, plan_digest)
  local built, err = marker.build_blueprint_marker(origin_proposal_id, workflow, plan_digest)
  if built == nil then
    error(err and err.code or "failed to build marker")
  end
  return built
end

local function build_rejects(origin_proposal_id, workflow, plan_digest, expected)
  local built, err = marker.build_blueprint_marker(origin_proposal_id, workflow, plan_digest)
  t.is_nil(built)
  t.is_true(type(err) == "table")
  if expected ~= nil then
    t.eq(err.path, expected.path)
    t.eq(err.code, expected.code)
  end
end

local tests = {
  test_build_parse_round_trip = function()
    local built = build_or_error(origin, workflow_id, digest)
    t.eq(
      built,
      '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="github-devloop/issue/owner/repo/42" workflow="workflow-one" digest="d-1234567890" -->'
    )

    local parsed = marker.parse_blueprint_marker("body\n" .. built .. "\n", origin)
    t.eq(parsed.origin, origin)
    t.eq(parsed.workflow, workflow_id)
    t.eq(parsed.digest, digest)
  end,

  test_rejects_malformed_origin_field = function()
    build_rejects("bad origin", workflow_id, digest, {
      path = "origin_proposal_id",
      code = "invalid_key",
    })
  end,

  test_rejects_malformed_workflow_field = function()
    build_rejects(origin, "bad workflow", digest, {
      path = "workflow_id",
      code = "invalid_key",
    })
  end,

  test_rejects_malformed_digest_field = function()
    build_rejects(origin, workflow_id, 'bad"digest', {
      path = "plan_digest",
      code = "invalid_marker_attr",
    })
  end,

  test_rejects_oversized_field = function()
    build_rejects(origin, string.rep("w", marker.MAX_WORKFLOW_ID_BYTES + 1), digest, {
      path = "workflow_id",
      code = "too_large",
    })
  end,

  test_parse_returns_nil_when_absent = function()
    t.is_nil(marker.parse_blueprint_marker("ordinary comment", origin))
  end,

  test_parse_returns_nil_for_foreign_namespace = function()
    local body = '<!-- fkst:github-devloop:blueprint:v1 origin="' .. origin
      .. '" workflow="' .. workflow_id
      .. '" digest="' .. digest
      .. '" -->'
    t.is_nil(marker.parse_blueprint_marker(body, origin))
  end,

  test_parse_returns_nil_for_malformed_marker = function()
    local body = '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="' .. origin
      .. '" workflow="bad workflow" digest="' .. digest
      .. '" -->'
    t.is_nil(marker.parse_blueprint_marker(body, origin))
  end,

  test_parse_picks_right_origin_among_multiple_markers = function()
    local other = build_or_error("github-devloop/issue/owner/repo/7", "other-workflow", "d-0000000007")
    local first = build_or_error(origin, "older-workflow", "d-1111111111")
    local latest = build_or_error(origin, "newer-workflow", "d-2222222222")
    local parsed = marker.parse_blueprint_marker(other .. "\n" .. first .. "\n" .. latest, origin)
    t.eq(parsed.origin, origin)
    t.eq(parsed.workflow, "newer-workflow")
    t.eq(parsed.digest, "d-2222222222")
  end,
}

return tests
