local strings = require("contract.strings")
local fail = require("core.errors").fail

local M = {}

M.MAX_ORIGIN_PROPOSAL_ID_BYTES = 200
M.MAX_WORKFLOW_ID_BYTES = 128
M.MAX_PLAN_DIGEST_BYTES = 64

local MARKER_PATTERN = "<!%-%- fkst:github%-devloop%-workflow:blueprint:v1.-%-%->"

local function attr(marker, name)
  return marker:match(name .. '="([^"]*)"')
end

local function validate_attr(value, path, limit)
  if type(value) ~= "string" then
    return false, fail(path, "not_string", "must be a string")
  end
  if value == "" then
    return false, fail(path, "empty", "must not be empty")
  end
  if #value > limit then
    return false, fail(path, "too_large", "exceeds byte limit", {
      max_bytes = limit,
      actual_bytes = #value,
    })
  end
  if value:find("%c") ~= nil or value:find('"', 1, true) ~= nil or value:find("[<>]") ~= nil then
    return false, fail(path, "invalid_marker_attr", "must be safe for a marker attribute")
  end
  if not strings.is_path_safe_key(value, limit) then
    return false, fail(path, "invalid_key", "must be a safe bounded key")
  end
  return true, nil
end

local function validate_origin(value, path)
  return validate_attr(value, path, M.MAX_ORIGIN_PROPOSAL_ID_BYTES)
end

local function validate_workflow(value, path)
  return validate_attr(value, path, M.MAX_WORKFLOW_ID_BYTES)
end

local function validate_digest(value, path)
  return validate_attr(value, path, M.MAX_PLAN_DIGEST_BYTES)
end

function M.build_blueprint_marker(origin_proposal_id, workflow_id, plan_digest)
  local ok, err = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then return nil, err end
  ok, err = validate_workflow(workflow_id, "workflow_id")
  if not ok then return nil, err end
  ok, err = validate_digest(plan_digest, "plan_digest")
  if not ok then return nil, err end

  return '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="' .. origin_proposal_id
    .. '" workflow="' .. workflow_id
    .. '" digest="' .. plan_digest
    .. '" -->',
    nil
end

local function fact_from_marker(marker, origin_proposal_id)
  local origin = attr(marker, "origin")
  local workflow = attr(marker, "workflow")
  local digest = attr(marker, "digest")
  local ok = validate_origin(origin, "origin")
  if not ok then return nil end
  ok = validate_workflow(workflow, "workflow")
  if not ok then return nil end
  ok = validate_digest(digest, "digest")
  if not ok then return nil end
  if origin ~= tostring(origin_proposal_id) then
    return nil
  end
  return {
    origin = origin,
    workflow = workflow,
    digest = digest,
  }
end

function M.parse_blueprint_marker(comment_body, origin_proposal_id)
  if type(comment_body) ~= "string" then
    return nil
  end
  local ok = validate_origin(origin_proposal_id, "origin_proposal_id")
  if not ok then
    return nil
  end

  -- Caller owns bot-author trust filtering; this parser only inspects one body string.
  local latest_marker = nil
  for marker in comment_body:gmatch(MARKER_PATTERN) do
    if attr(marker, "origin") == tostring(origin_proposal_id) then
      latest_marker = marker
    end
  end
  if latest_marker == nil then
    return nil
  end
  return fact_from_marker(latest_marker, origin_proposal_id)
end

function M.install(target)
  target.marker = M
end

return M
