local S = {}

function S.install(M)
local classes = {
  expedite = true,
  standard = true,
  background = true,
}

local class_rank = {
  expedite = 1,
  standard = 2,
  background = 3,
}

local class_order = {
  "expedite",
  "standard",
  "background",
}

local function normalize_class(value)
  local text = tostring(value or ""):lower()
  if classes[text] then
    return text
  end
  return "standard"
end

function M.normalize_intake_class(value)
  return normalize_class(value)
end

function M.is_intake_class(value)
  return classes[tostring(value or "")] == true
end

function M.intake_class_label(value)
  return "fkst-class:" .. normalize_class(value)
end

function M.intake_class_labels_except(value)
  local selected = normalize_class(value)
  local labels = {}
  for _, class in ipairs(class_order) do
    if class ~= selected then
      table.insert(labels, M.intake_class_label(class))
    end
  end
  return labels
end

function M.intake_class_rank(value)
  return class_rank[normalize_class(value)] or class_rank.standard
end

function M.sort_by_intake_class(items, class_for_item, fifo_for_item)
  local sequence = {}
  for index, item in ipairs(items or {}) do
    sequence[item] = index
  end
  table.sort(items, function(a, b)
    local a_class = type(class_for_item) == "function" and class_for_item(a) or nil
    local b_class = type(class_for_item) == "function" and class_for_item(b) or nil
    local a_rank = M.intake_class_rank(a_class)
    local b_rank = M.intake_class_rank(b_class)
    if a_rank ~= b_rank then
      return a_rank < b_rank
    end
    local a_fifo = type(fifo_for_item) == "function" and fifo_for_item(a) or nil
    local b_fifo = type(fifo_for_item) == "function" and fifo_for_item(b) or nil
    local a_key = tostring(a_fifo or "")
    local b_key = tostring(b_fifo or "")
    if a_key ~= b_key then
      return a_key < b_key
    end
    return (sequence[a] or 0) < (sequence[b] or 0)
  end)
  return items
end

function M.select_intake_class_batch(items, class_for_item, fifo_for_item, limit)
  local sorted = M.sort_by_intake_class(items, class_for_item, fifo_for_item)
  local batch_limit = tonumber(limit)
  if batch_limit == nil or batch_limit <= 0 or batch_limit >= #sorted then
    return sorted
  end

  local selected = {}
  local selected_items = {}
  local non_expedite_index = nil
  for index, item in ipairs(sorted) do
    local item_class = type(class_for_item) == "function" and class_for_item(item) or nil
    if M.normalize_intake_class(item_class) ~= "expedite" then
      non_expedite_index = index
      break
    end
  end

  local reserve_non_expedite = non_expedite_index ~= nil and batch_limit > 1
  local primary_limit = reserve_non_expedite and (batch_limit - 1) or batch_limit
  for index, item in ipairs(sorted) do
    if #selected >= primary_limit then
      break
    end
    if not reserve_non_expedite or index ~= non_expedite_index then
      table.insert(selected, item)
      selected_items[item] = true
    end
  end
  if reserve_non_expedite and selected_items[sorted[non_expedite_index]] ~= true then
    table.insert(selected, sorted[non_expedite_index])
  end
  return selected
end
end

return S
