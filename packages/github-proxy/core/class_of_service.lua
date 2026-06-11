local S = {}

function S.install(M)
local class_rank = {
  expedite = 1,
  standard = 2,
  background = 3,
}

local function class_from_labels(labels)
  for _, label in ipairs(labels or {}) do
    local class = tostring(label):match("^fkst%-class:(%a+)$")
    if class_rank[class] ~= nil then
      return class
    end
  end
  return "standard"
end

function M.entity_class_rank(entity)
  return class_rank[class_from_labels(entity and entity.labels)] or class_rank.standard
end

function M.entity_fifo_key(entity_type, entity)
  return tostring(entity and entity.updated_at or "") .. "/" .. tostring(entity_type or "") .. "/" .. tostring(entity and entity.number or "")
end

function M.sort_entities_by_class(items)
  table.sort(items, function(a, b)
    local a_rank = M.entity_class_rank(a.entity)
    local b_rank = M.entity_class_rank(b.entity)
    if a_rank ~= b_rank then
      return a_rank < b_rank
    end
    return M.entity_fifo_key(a.entity_type, a.entity) < M.entity_fifo_key(b.entity_type, b.entity)
  end)
  return items
end
end

return S
