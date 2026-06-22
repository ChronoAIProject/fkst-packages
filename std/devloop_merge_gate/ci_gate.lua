local S = {}

function S.install(M, shared)
local strings = shared.strings
local is_open_pr = shared.is_open_pr
local log_check_runs_fallback = shared.log_check_runs_fallback
local fetch_commit_check_runs = shared.fetch_commit_check_runs
local check_run_id = shared.check_run_id
local check_run_head_sha = shared.check_run_head_sha
local check_run_name = shared.check_run_name
local check_run_state = shared.check_run_state
local required_head_check_run_status = shared.required_head_check_run_status
local ci_classification = shared.ci_classification
local integration_or_external_red = shared.integration_or_external_red
local merge_gate_reason_row = shared.merge_gate_reason_row
local substrate_ref_path = ".fkst/substrate-ref"
local substrate_remote = "https://github.com/ChronoAIProject/fkst-substrate.git"
local substrate_branch = "dev"
local substrate_dev_ref = "refs/remotes/fkst-substrate/dev"
local git_handle

local function git()
  if git_handle == nil then
    git_handle = require("std.git").new(exec_argv)
  end
  return git_handle
end

function M.pr_identity_matches(pr, expected)
  if type(pr) ~= "table" then
    return false, "missing-pr"
  end
  if not is_open_pr(pr) then
    return false, "pr-not-open"
  end
  if tostring(pr.head_sha or "") ~= tostring(expected and expected.head_sha or "") then
    return false, "head-sha-mismatch"
  end
  if tostring(pr.head_ref_name or "") ~= tostring(expected and expected.head_branch or "") then
    return false, "head-branch-mismatch"
  end
  if tostring(pr.base_ref_name or "") ~= tostring(expected and expected.base_branch or "") then
    return false, "base-branch-mismatch"
  end
  if not M.is_same_repo_pr_head(pr, expected and expected.repo) then
    return false, "foreign-head-repository"
  end
  return true, "pr-ok"
end

function M.commit_check_runs_merge_gate(repo, head_sha, opts)
  local result = M.gh_commit_check_runs(repo, head_sha, 30)
  if result.exit_code ~= 0 then
    error("github-devloop: gh commit check-runs failed: " .. tostring(result.stderr))
  end
  local runs = M.parse_commit_check_runs(result.stdout)
  local green, reason = M.commit_check_runs_green(runs)
  log_check_runs_fallback(M, opts, repo, head_sha, runs, reason)
  return green, reason, runs
end

function M.classify_pr_ci_gate(pr, opts)
  local green, reason = M.pr_rollup_green(pr)
  if green then
    return ci_classification("OK", "rollup-green")
  end
  if reason == "rollup-pending" then
    return ci_classification("CHECKS_PENDING", "checks-pending")
  end
  local repo = opts and opts.repo or nil
  local head_sha = tostring(pr and pr.head_sha or "")
  if not M.is_safe_head_sha(head_sha) then
    return ci_classification("CI_UNKNOWN", "ci-unknown")
  end
  if tostring(repo or "") == "" then
    return ci_classification("CI_UNKNOWN", "ci-unknown")
  end
  local runs, fetch_reason = fetch_commit_check_runs(repo, head_sha)
  if runs == nil then
    return ci_classification("CI_UNKNOWN", fetch_reason or "ci-unknown")
  end
  log_check_runs_fallback(M, opts, repo, head_sha, runs, reason)
  local head_status = required_head_check_run_status(runs, head_sha)
  if head_status == "red" then
    return ci_classification("OWN_CI_RED", "own-ci-red", {
      check_runs = runs,
      dependency_recovery = M.ci_dependency_recovery_hint(runs, head_sha, {
        upstream_branch = opts and (opts.upstream_branch or (opts.branches and opts.branches.upstream)),
      }),
    })
  end
  if head_status == "pending" then
    return ci_classification("CHECKS_PENDING", "checks-pending", { check_runs = runs })
  end
  if head_status == "unknown" then
    return ci_classification("CI_UNKNOWN", "ci-unknown", { check_runs = runs })
  end
  if reason == "rollup-red" then
    return integration_or_external_red(pr, head_sha, runs)
  end
  return ci_classification("OK", "rollup-green", { check_runs = runs })
end

local function check_run_output_text(run)
  if type(run) ~= "table" or type(run.output) ~= "table" then
    return ""
  end
  return table.concat({
    tostring(run.output.title or ""),
    tostring(run.output.summary or ""),
    tostring(run.output.text or ""),
  }, "\n")
end

local missing_symbol_needles = {
  "nil",
  "missing",
  "not available",
  "not found",
  "undefined",
  "attempt to call",
}

local function output_reports_missing_symbol(text, symbol)
  local lower = tostring(text or ""):lower()
  if lower:find(tostring(symbol):lower(), 1, true) == nil then
    return false
  end
  for _, needle in ipairs(missing_symbol_needles) do
    if lower:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local stale_substrate_symbols = {
  "restricted_lua_load",
}

local function read_substrate_pin_at(ref)
  if not M.is_safe_head_sha(ref) then
    return nil
  end
  local ok, result = pcall(function()
    return M.git_show_file(ref, substrate_ref_path, 30)
  end)
  if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
    return nil
  end
  local pin = M._trim(result.stdout)
  if not M.is_safe_head_sha(pin) then
    return nil
  end
  return pin:lower()
end

local function fetch_substrate_dev_head()
  local ok, result = pcall(function()
    return git().fetch_remote_branch_to_tracking_ref(substrate_remote, substrate_branch, substrate_dev_ref, 60)
  end)
  if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
    return nil
  end
  ok, result = pcall(function()
    return git().rev_parse_ref_commit(substrate_dev_ref, 30)
  end)
  if not ok or type(result) ~= "table" or result.exit_code ~= 0 then
    return nil
  end
  local head = M._trim(result.stdout)
  if not M.is_safe_head_sha(head) then
    return nil
  end
  return head:lower()
end

local function is_substrate_ancestor(ancestor_sha, descendant_sha)
  if not M.is_safe_head_sha(ancestor_sha) or not M.is_safe_head_sha(descendant_sha) then
    return false
  end
  local ok, result = pcall(function()
    return M.git_is_ancestor(ancestor_sha, descendant_sha, 30)
  end)
  return ok and type(result) == "table" and result.exit_code == 0
end

local function substrate_pin_stale_proof(head_sha, opts)
  local upstream_branch = tostring(opts and (opts.upstream_branch or (opts.branches and opts.branches.upstream)) or "")
  if upstream_branch == "" then
    return false
  end
  local upstream_head = M.current_base_head(upstream_branch)
  if not M.is_safe_head_sha(upstream_head) then
    return false
  end
  local head_pin = read_substrate_pin_at(head_sha)
  local upstream_pin = read_substrate_pin_at(upstream_head)
  if head_pin == nil or upstream_pin == nil or head_pin == upstream_pin then
    return false
  end
  local substrate_dev_head = fetch_substrate_dev_head()
  if substrate_dev_head == nil then
    return false
  end
  return is_substrate_ancestor(upstream_pin, substrate_dev_head)
    and is_substrate_ancestor(head_pin, upstream_pin)
end

function M.ci_dependency_recovery_hint(runs, head_sha, opts)
  if type(runs) ~= "table" or not M.is_safe_head_sha(head_sha) then
    return nil
  end
  local expected = tostring(head_sha):lower()
  local required = {}
  for _, name in ipairs(M._required_check_run_names or {}) do
    required[tostring(name)] = true
  end
  for _, run in ipairs(runs) do
    local name = check_run_name(run)
    if required[name] then
      local run_head = check_run_head_sha(run)
      local state, conclusion = check_run_state(run)
      if (run_head == nil or run_head == expected)
        and state == "COMPLETED"
        and tostring(conclusion or "") ~= "SUCCESS" then
        local output = check_run_output_text(run)
        for _, symbol in ipairs(stale_substrate_symbols) do
          if output_reports_missing_symbol(output, symbol) then
            if substrate_pin_stale_proof(head_sha, opts) then
              return "substrate-pin-stale"
            end
            return nil
          end
        end
      end
    end
  end
  return nil
end

function M.rerunnable_check_run_ids_for_head(runs, head_sha)
  if type(runs) ~= "table" or not M.is_safe_head_sha(head_sha) then
    return {}
  end
  local ids = {}
  local seen = {}
  local expected = tostring(head_sha):lower()
  for _, run in ipairs(runs) do
    local id = check_run_id(run)
    local run_head = check_run_head_sha(run)
    if id ~= nil
      and (run_head == nil or run_head == expected)
      and not seen[id] then
      table.insert(ids, id)
      seen[id] = true
    end
  end
  return ids
end

function M.evaluate_ci_status_gate(pr, opts)
  local green, green_reason = M.pr_rollup_green(pr)
  local check_runs = nil
  if not green and green_reason == "missing-status-rollup" and type(opts) == "table" and opts.repo ~= nil then
    local head_sha = tostring(pr and pr.head_sha or "")
    if head_sha ~= "" then
      green, green_reason, check_runs = M.commit_check_runs_merge_gate(opts.repo, head_sha, opts)
    end
  end
  return green, green_reason, check_runs
end

function M.evaluate_ci_merge_gate(pr, opts)
  local mergeable, mergeable_reason = M.pr_mergeable(pr)
  if not mergeable then
    return false, mergeable_reason
  end
  local green, green_reason = M.evaluate_ci_status_gate(pr, opts)
  if not green then
    if green_reason == "rollup-red" then
      local classification = M.classify_pr_ci_gate(pr, opts)
      return false, classification.reason
    end
    return false, green_reason
  end
  return true, "merge-gate-ok"
end

function M.merge_gate_reason_class(reason)
  local row = merge_gate_reason_row(reason)
  if row ~= nil then
    return row.class
  end
  local text = tostring(reason or "")
  if M.is_not_mergeable_reason(text) then
    return text
  end
  return strings.sanitize_key(text ~= "" and text or "gate-failed", false):gsub("/", "-")
end

function M.merge_gate_reason_requires_pr_merge_product(reason)
  local row = merge_gate_reason_row(reason)
  if row ~= nil then
    return row.requires_pr_merge_product == true
  end
  return false
end
end

return S
