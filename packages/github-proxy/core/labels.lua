local S = {}

function S.install(M)
local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_result_stderr(result)
  return type(result) == "table" and tostring(result.stderr or "") or ""
end

function M.gh_label_list_cmd(repo)
  return "gh label list --repo " .. shell_single_quote(repo) .. " --limit 1000 --json name"
end

local fkst_dev_label_colors = {
  ["fkst-dev:enabled"] = "1D76DB",
  ["fkst-dev:thinking"] = "8250DF",
  ["fkst-dev:ready"] = "0E8A16",
  ["fkst-dev:implementing"] = "FBCA04",
  ["fkst-dev:pr-open"] = "006B75",
  ["fkst-dev:reviewing"] = "5319E7",
  ["fkst-dev:fixing"] = "D93F0B",
  ["fkst-dev:merge-ready"] = "2EA44F",
  ["fkst-dev:merging"] = "C2E0C6",
  ["fkst-dev:merged"] = "8957E5",
  ["fkst-dev:impl-failed"] = "B60205",
  ["fkst-dev:blocked"] = "1B1F23",
  ["fkst-dev:blocked-on-dependency"] = "E99695",
  ["fkst-dev:review-meta"] = "BFD4F2",
}

function M.gh_label_create_cmd(repo, label)
  local color = fkst_dev_label_colors[label] or "ededed"
  return "gh label create " .. shell_single_quote(label)
    .. " --repo " .. shell_single_quote(repo)
    .. " --color " .. shell_single_quote(color)
end

local function parse_labels(decoded)
  local labels = {}
  for _, label in ipairs(decoded or {}) do
    if type(label) == "table" and label.name ~= nil then
      table.insert(labels, tostring(label.name))
    elseif type(label) == "string" then
      table.insert(labels, label)
    end
  end
  return labels
end

function M.parse_issue_labels(gh_json_stdout)
  return parse_labels(json.decode(gh_json_stdout or "{}").labels)
end

function M.parse_repo_labels(gh_json_stdout)
  return parse_labels(json.decode(gh_json_stdout or "[]"))
end

local function label_set(labels)
  local set = {}
  for _, label in ipairs(labels or {}) do
    set[tostring(label)] = true
  end
  return set
end

local function normalized_unique_labels(labels)
  local unique = {}
  local seen = {}
  for _, label in ipairs(labels or {}) do
    local text = tostring(label)
    if text ~= "" and not seen[text] then
      seen[text] = true
      table.insert(unique, text)
    end
  end
  return unique
end

function M.is_gh_label_already_exists(result)
  local lower = command_result_stderr(result):lower()
  return lower:find("already exists", 1, true) ~= nil
    or lower:find("name already exists", 1, true) ~= nil
end

function M.ensure_repo_label(repo, label, existing_labels)
  if existing_labels[label] then
    return true
  end
  local ok, result_or_error = M.gh_exec_result(M.gh_label_create_cmd(repo, label), 30, "gh label create")
  if not ok then
    local raw_result = result_or_error.result
    if raw_result == nil or not M.is_gh_label_already_exists(raw_result) then
      error(result_or_error.message)
    end
  end
  existing_labels[label] = true
  return true
end

function M.gh_issue_edit_labels_cmd(repo, issue_number, add_labels, remove_labels)
  local cmd = "gh issue edit " .. shell_single_quote(issue_number)
    .. " --repo " .. shell_single_quote(repo)
  for _, label in ipairs(add_labels or {}) do
    cmd = cmd .. " --add-label " .. shell_single_quote(label)
  end
  for _, label in ipairs(remove_labels or {}) do
    cmd = cmd .. " --remove-label " .. shell_single_quote(label)
  end
  return cmd
end

function M.apply_issue_labels(repo, issue_number, add_labels, remove_labels)
  local add = normalized_unique_labels(add_labels)
  local remove = normalized_unique_labels(remove_labels)
  if #add == 0 and #remove == 0 then
    return false
  end
  local listed = M.gh_exec(M.gh_label_list_cmd(repo), 30, "gh label list")
  local existing = label_set(M.parse_repo_labels(listed.stdout))
  for _, label in ipairs(add) do
    M.ensure_repo_label(repo, label, existing)
  end
  local safe_remove = {}
  for _, label in ipairs(remove) do
    if existing[label] then
      table.insert(safe_remove, label)
    else
      log.info("github-proxy: label remove skipped because repo label is missing: " .. label)
    end
  end
  if #add == 0 and #safe_remove == 0 then
    return false
  end
  M.gh_exec(M.gh_issue_edit_labels_cmd(repo, issue_number, add, safe_remove), 30, "gh issue edit")
  return true
end
end

return S
