local entity = require("devloop.entity")

local separator = "#codex-progress-cohort-v1#"

local function canonical_pr_proposal_id(value)
  local target = entity.parse_entity_proposal_id(value)
  if target == nil or target.kind ~= "pr" then
    return nil
  end
  if entity.pr_proposal_id(target.repo, target.pr_number) ~= value then
    return nil
  end
  return target
end

local function require_cohort_id(value)
  if type(value) ~= "string" or #value ~= 64 or value:find("[^0-9a-f]") ~= nil then
    error("devloop: codex-progress-cohort-invalid: cohort id must be 64 lowercase hex characters")
  end
  return value
end

local function label(target_proposal_id, cohort_id)
  if canonical_pr_proposal_id(target_proposal_id) == nil then
    error("devloop: codex-progress-target-invalid: canonical PR proposal id is required")
  end
  return target_proposal_id .. separator .. require_cohort_id(cohort_id)
end

local function new_cohort_id()
  local parts = {}
  for index = 1, 4 do
    parts[index] = string.format("%016x", math.random(0))
  end
  return require_cohort_id(table.concat(parts))
end

local function new_label(target_proposal_id)
  return label(target_proposal_id, new_cohort_id())
end

local function parse_label(value)
  if type(value) ~= "string" then
    return nil
  end
  local marker_start = value:find(separator, 1, true)
  if marker_start == nil or value:find(separator, marker_start + #separator, true) ~= nil then
    return nil
  end
  local target_proposal_id = value:sub(1, marker_start - 1)
  local cohort_id = value:sub(marker_start + #separator)
  local target = canonical_pr_proposal_id(target_proposal_id)
  if target == nil or #cohort_id ~= 64 or cohort_id:find("[^0-9a-f]") ~= nil then
    return nil
  end
  return {
    target = target,
    target_proposal_id = target_proposal_id,
    cohort_id = cohort_id,
    snapshot_id = "cohort-" .. cohort_id,
  }
end

return {
  label = label,
  new_label = new_label,
  parse_label = parse_label,
}
