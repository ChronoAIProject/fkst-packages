local L = {}

L.label_by_state = {
  thinking = "fkst-dev:thinking",
  dependency_wait = "fkst-dev:ready",
  ready = "fkst-dev:ready",
  implementing = "fkst-dev:implementing",
  ["awaiting-pr"] = "fkst-dev:awaiting-pr",
  ["pr-open"] = "fkst-dev:pr-open",
  reviewing = "fkst-dev:reviewing",
  ["merge-ready"] = "fkst-dev:merge-ready",
  merging = "fkst-dev:merging",
  merged = "fkst-dev:merged",
  ["closed-unmerged"] = "fkst-dev:blocked",
  fixing = "fkst-dev:fixing",
  ["review-meta"] = "fkst-dev:review-meta",
  ["impl-failed"] = "fkst-dev:impl-failed",
  declined = "fkst-dev:declined",
  blocked = "fkst-dev:blocked",
}

L.state_labels = {}
for _, label in pairs(L.label_by_state) do
  L.state_labels[label] = true
end

L.state_graph = {
  unmanaged = { "thinking" },
  thinking = { "dependency_wait", "ready", "declined", "blocked" },
  dependency_wait = { "dependency_wait", "ready", "blocked" },
  ready = { "dependency_wait", "implementing", "blocked" },
  implementing = { "awaiting-pr", "impl-failed" },
  ["awaiting-pr"] = { "merged", "ready", "blocked" },
  ["pr-open"] = { "reviewing", "blocked" },
  reviewing = { "merge-ready", "fixing", "review-meta" },
  ["merge-ready"] = { "merging", "blocked" },
  merging = { "merged", "reviewing", "fixing", "blocked" },
  merged = {},
  ["closed-unmerged"] = {},
  fixing = { "reviewing", "review-meta", "blocked" },
  ["review-meta"] = { "fixing", "blocked" },
  ["impl-failed"] = { "implementing" },
  declined = {},
  blocked = {},
}

L.issue_state_order = {
  "thinking",
  "dependency_wait",
  "ready",
  "implementing",
  "pr-open",
  "reviewing",
  "merge-ready",
  "fixing",
  "impl-failed",
  "declined",
  "blocked",
  "review-meta",
  "merging",
  "merged",
  "awaiting-pr",
}

L.state_order = {
  "thinking",
  "dependency_wait",
  "ready",
  "implementing",
  "pr-open",
  "reviewing",
  "merge-ready",
  "fixing",
  "impl-failed",
  "declined",
  "blocked",
  "review-meta",
  "merging",
  "merged",
  "closed-unmerged",
  "awaiting-pr",
}

L.state_stage_rank = {
  thinking = 100,
  dependency_wait = 500,
  ready = 500,
  implementing = 600,
  ["awaiting-pr"] = 625,
  ["pr-open"] = 650,
  reviewing = 675,
  ["merge-ready"] = 690,
  merging = 695,
  fixing = 700,
  ["review-meta"] = 710,
  ["impl-failed"] = 750,
  declined = 800,
  blocked = 800,
  ["closed-unmerged"] = 825,
  merged = 900,
}

function L.copy_array(values)
  local out = {}
  for _, value in ipairs(values or {}) do
    table.insert(out, value)
  end
  return out
end

function L.is_state(state)
  return L.label_by_state[state] ~= nil
end

function L.is_state_label(label)
  return L.state_labels[tostring(label)] == true
end

function L.state_label(state)
  return L.label_by_state[state]
end

function L.state_label_changes(to_state)
  local add_label = L.state_label(to_state)
  if add_label == nil then
    error("github-devloop: invalid state")
  end

  local remove_labels = {}
  local remove_seen = {}
  for _, state in ipairs(L.state_order) do
    local label = L.label_by_state[state]
    if state ~= to_state and label ~= add_label and remove_seen[label] ~= true then
      table.insert(remove_labels, label)
      remove_seen[label] = true
    end
  end
  return { add_label }, remove_labels
end

function L.state_label_reconcile_changes(labels, to_state)
  local expected_label = L.state_label(to_state)
  if expected_label == nil then
    error("github-devloop: invalid state")
  end

  local add_labels = {}
  local remove_labels = {}
  local has_expected = false
  for _, label in ipairs(labels or {}) do
    local label_text = tostring(label)
    if label_text == expected_label then
      has_expected = true
    elseif L.is_state_label(label_text) then
      table.insert(remove_labels, label_text)
    end
  end
  if not has_expected then
    table.insert(add_labels, expected_label)
  end
  return add_labels, remove_labels
end

function L.state_label_hint_matches(labels, state)
  local expected_label = L.state_label(state)
  if expected_label == nil then
    return false
  end

  local has_expected = false
  for _, label in ipairs(labels or {}) do
    local label_text = tostring(label)
    if label_text == expected_label then
      has_expected = true
    elseif L.is_state_label(label_text) then
      return false
    end
  end
  return has_expected
end

return L
