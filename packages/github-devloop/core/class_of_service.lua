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
    return tostring(a_fifo or "") < tostring(b_fifo or "")
  end)
  return items
end
end

return S
