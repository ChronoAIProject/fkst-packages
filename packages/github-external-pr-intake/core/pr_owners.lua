local M = {}

local axes = {
  "is_integration_rollup",
  "has_actionable_issue_origin",
  "is_managed_author",
  "is_authorized_author",
}

local declarations = {
  {
    kind = "integration-promotion",
    lifecycle_package = "github-devloop-integration",
    claim_kind = "configured-branch-pair",
    authorization_kind = "integration-topology",
    terminal_contract = "promotion-reconciliation",
    disposition = "reserved",
    match = {
      is_integration_rollup = true,
    },
  },
  {
    kind = "github-devloop-pr",
    lifecycle_package = "github-devloop-pr",
    claim_kind = "backing-issue-assignee",
    authorization_kind = "trusted-pr-origin",
    terminal_contract = "pr-saga-terminal",
    disposition = "reserved",
    match = {
      is_integration_rollup = false,
      has_actionable_issue_origin = true,
    },
  },
  {
    kind = "operator-hotfix-bridge",
    lifecycle_package = "github-external-pr-intake",
    claim_kind = "pr-assignee",
    authorization_kind = "github-author-policy",
    terminal_contract = "backing-issue-resolution",
    disposition = "bridge",
    match = {
      is_integration_rollup = false,
      has_actionable_issue_origin = false,
      is_managed_author = true,
      is_authorized_author = true,
    },
  },
  {
    kind = "external-pr-bridge",
    lifecycle_package = "github-external-pr-intake",
    claim_kind = "pr-assignee",
    authorization_kind = "github-author-policy",
    terminal_contract = "backing-issue-resolution",
    disposition = "bridge",
    match = {
      is_integration_rollup = false,
      has_actionable_issue_origin = false,
      is_managed_author = false,
      is_authorized_author = true,
    },
  },
  {
    kind = "unauthorized-pr-retirement",
    lifecycle_package = "github-external-pr-intake",
    claim_kind = "authorization-policy",
    authorization_kind = "github-author-policy",
    terminal_contract = "authorization-denial",
    disposition = "retire",
    match = {
      is_integration_rollup = false,
      has_actionable_issue_origin = false,
      is_authorized_author = false,
    },
  },
}

local required_string_fields = {
  "kind",
  "lifecycle_package",
  "claim_kind",
  "authorization_kind",
  "terminal_contract",
  "disposition",
}

local axis_set = {}
for _, axis in ipairs(axes) do
  axis_set[axis] = true
end

local function declaration_matches(declaration, facts)
  if type(declaration) ~= "table" or type(declaration.match) ~= "table" then
    return false
  end
  for axis, expected in pairs(declaration.match) do
    if facts[axis] ~= expected then
      return false
    end
  end
  return true
end

local function fact_label(facts)
  local parts = {}
  for _, axis in ipairs(axes) do
    table.insert(parts, axis .. "=" .. tostring(facts[axis]))
  end
  return table.concat(parts, ",")
end

local function matching_declarations(facts, owner_declarations)
  local matches = {}
  for _, declaration in ipairs(owner_declarations or {}) do
    if declaration_matches(declaration, facts) then
      table.insert(matches, declaration)
    end
  end
  return matches
end

local function each_fact_shape(fn)
  for _, rollup in ipairs({ false, true }) do
    for _, origin in ipairs({ false, true }) do
      for _, managed in ipairs({ false, true }) do
        for _, authorized in ipairs({ false, true }) do
          fn({
            is_integration_rollup = rollup,
            has_actionable_issue_origin = origin,
            is_managed_author = managed,
            is_authorized_author = authorized,
          })
        end
      end
    end
  end
end

function M.declarations()
  return declarations
end

function M.classify_facts(facts, owner_declarations)
  if type(facts) ~= "table" then
    error("github-external-pr-intake: pr-owner-facts-required: PR ownership requires classification facts")
  end
  for _, axis in ipairs(axes) do
    if type(facts[axis]) ~= "boolean" then
      error("github-external-pr-intake: invalid-pr-owner-axis: " .. axis)
    end
  end
  local matches = matching_declarations(facts, owner_declarations or declarations)
  if #matches == 0 then
    error("github-external-pr-intake: unowned-pr: " .. fact_label(facts))
  end
  if #matches > 1 then
    error("github-external-pr-intake: ambiguous-pr-owner: " .. fact_label(facts))
  end
  return matches[1]
end

function M.conformance_errors(owner_declarations)
  local rows = owner_declarations or declarations
  local errors = {}
  local kinds = {}
  if type(rows) ~= "table" or #rows == 0 then
    return { "PR owner declarations must be a non-empty array" }
  end
  for index, declaration in ipairs(rows) do
    if type(declaration) ~= "table" then
      table.insert(errors, "PR owner declaration " .. tostring(index) .. " must be a table")
    else
      for _, field in ipairs(required_string_fields) do
        if type(declaration[field]) ~= "string" or declaration[field] == "" then
          table.insert(errors, "PR owner declaration " .. tostring(index) .. " requires " .. field)
        end
      end
      if type(declaration.kind) == "string" and declaration.kind ~= "" then
        if kinds[declaration.kind] then
          table.insert(errors, "duplicate PR owner kind: " .. declaration.kind)
        end
        kinds[declaration.kind] = true
      end
      if declaration.disposition ~= "reserved"
        and declaration.disposition ~= "bridge"
        and declaration.disposition ~= "retire" then
        table.insert(errors, "PR owner declaration " .. tostring(index) .. " has invalid disposition")
      end
      if type(declaration.match) ~= "table" then
        table.insert(errors, "PR owner declaration " .. tostring(index) .. " requires match")
      else
        for axis, expected in pairs(declaration.match) do
          if not axis_set[axis] then
            table.insert(errors, "PR owner declaration " .. tostring(index) .. " has unknown axis " .. tostring(axis))
          elseif type(expected) ~= "boolean" then
            table.insert(errors, "PR owner declaration " .. tostring(index) .. " axis " .. axis .. " must be boolean")
          end
        end
      end
    end
  end
  each_fact_shape(function(facts)
    local count = #matching_declarations(facts, rows)
    if count == 0 then
      table.insert(errors, "unowned facts: " .. fact_label(facts))
    elseif count > 1 then
      table.insert(errors, "ambiguous facts: " .. fact_label(facts))
    end
  end)
  return errors
end

return M
