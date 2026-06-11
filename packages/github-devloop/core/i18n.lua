local S = {}

function S.install(M)
local configured_output_lang = nil
local loaded_catalogs = {}

local function in_test_mode()
  return type(_G.fkst) == "table" and type(_G.fkst.test) == "table"
end

local function normalize_output_lang(value)
  local lang = tostring(value or ""):lower()
  if lang:match("^zh") then
    return "zh-CN"
  end
  return "en"
end

local function catalog_for(lang)
  local normalized = normalize_output_lang(lang)
  if loaded_catalogs[normalized] ~= nil then
    return loaded_catalogs[normalized]
  end
  local ok, catalog = false, nil
  local found, path = pcall(package.searchpath, "locales." .. normalized, package.path)
  if found and path ~= nil then
    ok, catalog = pcall(dofile, path)
  end
  if not ok or type(catalog) ~= "table" then
    if normalized ~= "en" then
      return catalog_for("en")
    end
    catalog = {}
  end
  loaded_catalogs[normalized] = catalog
  return catalog
end

function M.configure_output_lang(lang)
  configured_output_lang = lang and normalize_output_lang(lang) or nil
end

function M.output_lang(exec)
  if configured_output_lang ~= nil then
    return configured_output_lang
  end
  if exec == nil and in_test_mode() then
    return "en"
  end
  local ok, value = pcall(function()
    return M.read_env("FKST_OUTPUT_LANG", exec)
  end)
  if not ok then
    return "en"
  end
  return normalize_output_lang(value)
end

function M.catalog_string(key, exec)
  local text = nil
  local lang = M.output_lang(exec)
  if configured_output_lang == nil and exec == nil and not in_test_mode() and type(_G.t) == "function" then
    local ok, value = pcall(_G.t, key)
    if ok and value ~= nil and value ~= "" and value ~= key then
      text = value
    end
  end
  if text == nil then
    text = catalog_for(lang)[key]
    if text == nil and lang ~= "en" then
      text = catalog_for("en")[key]
    end
  end
  return text ~= nil and tostring(text) or tostring(key)
end

function M.comment_string(key, exec)
  return M.catalog_string("comments." .. tostring(key), exec)
end

function M.prompt_preamble_string(key, exec)
  return M.catalog_string("prompt_preamble." .. tostring(key), exec)
end

function M.dashboard_string(key, exec)
  return M.catalog_string("dashboard." .. tostring(key), exec)
end

function M.operator_command_string(key, exec)
  return M.catalog_string("operator_commands." .. tostring(key), exec)
end

function M.catalog_strings(lang, prefix)
  local catalog = catalog_for(lang)
  local result = {}
  local needle = tostring(prefix or "")
  for key, value in pairs(catalog) do
    if needle == "" or key:sub(1, #needle) == needle then
      result[key] = value
    end
  end
  return result
end

function M.comment_strings(lang)
  local catalog = M.catalog_strings(lang, "comments.")
  local result = {}
  for key, value in pairs(catalog) do
    result[key:sub(#"comments." + 1)] = value
  end
  return result
end

local human_comment_keys = {
  "comments.convergence_suffix",
  "comments.narrowed_question_label",
  "comments.angle_stances_label",
  "comments.verdict_summary_label",
  "comments.comment_evidence_empty",
  "comments.thinking_started",
  "comments.decision_prefix",
  "comments.convergence_round_prefix",
  "comments.pr_review_convergence_round_prefix",
  "comments.reconcile_action_prefix",
  "comments.fix_reconcile_action_prefix",
  "comments.review_reconcile_action_prefix",
  "comments.reason_block_label",
  "comments.reason_inline_label",
  "comments.no_reason_provided",
  "comments.implementation_started",
  "comments.worktree_label",
  "comments.branch_label",
  "comments.head_label",
  "comments.base_branch_label",
  "comments.base_head_label",
  "comments.implementation_failed_prefix",
  "comments.no_implementation_output",
  "comments.pr_opened_prefix",
  "comments.pr_ready_for_review",
  "comments.pr_review_decision_prefix",
  "comments.blocking_gap_label",
  "comments.merge_gate_failed_prefix",
  "comments.reproduce_locally_prefix",
  "comments.reproduce_locally_suffix",
  "comments.fix_round_summary_label",
  "comments.fix_pushed_for_rereview",
  "comments.previous_reviewed_head_label",
  "comments.new_head_label",
  "comments.current_head_label",
  "comments.pr_head_advanced",
  "comments.fix_escalated_to_review_meta_prefix",
  "comments.review_meta_action_prefix",
  "comments.dependency_hold_prefix",
  "comments.intake_decision_prefix",
  "comments.is_merging_pr_prefix",
  "comments.merged_pr_prefix",
  "comments.no_fix_output",
  "comments.decomposed_prefix",
  "comments.decomposed_suffix",
}

local template_audit = {
  { id = "github-devloop-marker-comments", classification = "machine" },
  { id = "dedup-key-parts", classification = "machine" },
  { id = "state-labels", classification = "machine" },
  { id = "ai-sentinel", classification = "machine" },
  { id = "pr-title-and-body", classification = "repo-policy" },
  { id = "spec-amendment-issue-create", classification = "repo-policy" },
}

for _, key in ipairs(human_comment_keys) do
  table.insert(template_audit, { id = key, classification = "human" })
end

function M.comment_template_audit()
  local copy = {}
  for _, row in ipairs(template_audit) do
    table.insert(copy, {
      id = row.id,
      classification = row.classification,
    })
  end
  return copy
end
end

return S
