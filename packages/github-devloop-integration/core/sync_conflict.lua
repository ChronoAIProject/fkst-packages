local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local S = {}
local strings = require("contract.strings")
local decimal_checksum = strings.decimal_checksum
local conflict_telemetry = require("devloop.conflict_telemetry")
local sync_conflict_owner = require("devloop.sync_conflict_owner")

function S.install(M)
local max_sync_conflict_attempts = 3
local sync_conflict_attempt_schema = "github-devloop.sync-conflict-attempt.v1"
local self_hash_normalizers = {
  ["migration/restart-lifecycle.inventory.json"] = "scripts/check_repo_restart_lifecycle.py",
}

local function safe_ref_segment(value, limit)
  local safe = strings.sanitize_key(tostring(value or ""), false)
    :gsub("/", "-")
    :gsub("%.", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
  if safe == "" then
    safe = "empty"
  end
  return safe:sub(1, limit):gsub("%-+$", "")
end

local function conflict_fingerprint(conflict, unmerged_stdout)
  local paths = conflict_telemetry.conflict_file_paths_from_unmerged(unmerged_stdout)
  local material = {
    "repo=" .. tostring(conflict.repo or ""),
    "upstream=" .. tostring(conflict.upstream_branch or ""),
    "integration=" .. tostring(conflict.integration_branch or ""),
    "upstream_sha=" .. tostring(conflict.upstream_sha or ""),
    "integration_sha=" .. tostring(conflict.integration_sha or ""),
  }
  for _, path in ipairs(paths) do
    table.insert(material, "path=" .. path)
  end
  if #paths == 0 then
    local normalized = M._normalize_error_fact_text(unmerged_stdout or "")
    table.insert(material, "unmerged=" .. normalized)
  end
  return "sync-conflict-" .. decimal_checksum(table.concat(material, "\n"))
end

function M.max_sync_conflict_attempts()
  return max_sync_conflict_attempts
end

function M.sync_conflict_lineage(conflict)
  return base_ids.dedup_key({
    "sync-conflict-lineage",
    tostring(conflict.repo or ""),
    tostring(conflict.upstream_branch or ""),
    tostring(conflict.integration_branch or ""),
    tostring(conflict.integration_sha or ""),
  })
end

function M.sync_conflict_attempt_ref(conflict)
  local lane = table.concat({
    tostring(conflict.repo or ""),
    tostring(conflict.upstream_branch or ""),
    tostring(conflict.integration_branch or ""),
    tostring(conflict.integration_sha or ""),
  }, "\n")
  local ref = "refs/fkst/sync-conflict-attempts/"
    .. safe_ref_segment(conflict.repo, 48)
    .. "/"
    .. safe_ref_segment(conflict.upstream_branch, 40)
    .. "/"
    .. safe_ref_segment(conflict.integration_branch, 40)
    .. "-"
    .. decimal_checksum(lane)
    .. "/"
    .. safe_ref_segment(conflict.integration_sha, 40)
  if not strings.is_path_safe_key(ref, M._max_dedup_len) then
    error("github-devloop: sync-conflict-ref-invalid: invalid sync conflict attempt ref")
  end
  return ref
end

function M.parse_sync_conflict_attempt_ref_sha(stdout, conflict)
  local expected_ref = M.sync_conflict_attempt_ref(conflict)
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    local sha, ref = line:match("^(%x+)%s+([^%s]+)$")
    if ref == expected_ref and sha ~= nil and #sha == 40 then
      return sha
    end
  end
  return nil
end

function M.sync_conflict_fingerprint(conflict, unmerged_stdout)
  return conflict_fingerprint(conflict, unmerged_stdout)
end

function M.sync_conflict_self_hash_normalizer_paths(unmerged_stdout)
  local paths = conflict_telemetry.conflict_file_paths_from_unmerged(unmerged_stdout)
  local selected = {}
  local seen = {}
  for _, path in ipairs(paths) do
    if self_hash_normalizers[path] ~= nil and seen[path] ~= true then
      table.insert(selected, path)
      seen[path] = true
    end
  end
  table.sort(selected)
  return selected
end

function M.sync_conflict_self_hash_normalizer_argv(source_root, worktree, path)
  local script = self_hash_normalizers[path]
  local trusted_root = tostring(source_root or ""):gsub("/+$", "")
  local root = tostring(worktree or ""):gsub("/+$", "")
  if script == nil then
    error("github-devloop: sync-conflict-normalizer-unknown: no self-hash normalizer for path")
  end
  if trusted_root == "" or trusted_root:find("[\r\n]") ~= nil then
    error("github-devloop: sync-conflict-normalizer-source-root-invalid: invalid source root")
  end
  if root == "" or root:find("[\r\n]") ~= nil then
    error("github-devloop: sync-conflict-normalizer-worktree-invalid: invalid worktree")
  end
  return {
    "python3",
    "-B",
    trusted_root .. "/" .. script,
    "--root",
    root,
    "--fix-artifact-sha256",
  }
end

function M.sync_conflict_attempt_ledger(conflict, attempt)
  local count = tonumber(attempt)
  if count == nil or count < 1 or count ~= math.floor(count) then
    error("github-devloop: sync-conflict-attempt-invalid: invalid sync conflict attempt")
  end
  return "{"
    .. '"schema":' .. strings.json_string(sync_conflict_attempt_schema)
    .. ',"lineage":' .. strings.json_string(M.sync_conflict_lineage(conflict))
    .. ',"attempt":' .. tostring(count)
    .. "}"
end

function M.decode_sync_conflict_attempt_ledger(stdout, conflict)
  local text = tostring(stdout or "")
  local _, header_end = text:find("\n\n", 1, true)
  if header_end ~= nil then
    text = text:sub(header_end + 1)
  end
  local ok, decoded = pcall(json.decode, text)
  local attempt = ok and type(decoded) == "table" and tonumber(decoded.attempt) or nil
  if not ok
    or type(decoded) ~= "table"
    or decoded.schema ~= sync_conflict_attempt_schema
    or type(decoded.lineage) ~= "string"
    or decoded.lineage == ""
    or attempt == nil
    or attempt < 1
    or attempt ~= math.floor(attempt) then
    return nil
  end
  if conflict ~= nil and decoded.lineage ~= M.sync_conflict_lineage(conflict) then
    return nil
  end
  return {
    schema = decoded.schema,
    lineage = decoded.lineage,
    attempt = attempt,
  }
end

function M.build_sync_conflict_escalation_request(conflict, fingerprint, attempt, reason, unmerged_stdout)
  local title = "Branch sync conflict requires manual resolution: "
    .. tostring(conflict.upstream_branch)
    .. " into "
    .. tostring(conflict.integration_branch)
  if #title > M._max_title_len then
    title = base_ids.truncate_utf8(title, M._max_title_len)
  end

  local paths = conflict_telemetry.conflict_file_paths_from_unmerged(unmerged_stdout)
  local path_lines = {}
  for _, path in ipairs(paths) do
    table.insert(path_lines, "- " .. path)
  end
  if #path_lines == 0 then
    table.insert(path_lines, "- no safe path list available")
  end

  local body_lines = {
    "The autonomous branch sync conflict resolver exhausted its bounded retry budget.",
    "",
    "Reason: " .. devloop_base.neutralize_untrusted_comment_text(reason or "unresolved sync conflict"),
    "Attempt: " .. tostring(attempt),
    "Max attempts: " .. tostring(M.max_sync_conflict_attempts()),
    "Conflict lineage: " .. M.sync_conflict_lineage(conflict),
    "Fingerprint: " .. tostring(fingerprint),
    "Repository: " .. tostring(conflict.repo),
    "Upstream branch: " .. tostring(conflict.upstream_branch),
    "Integration branch: " .. tostring(conflict.integration_branch),
    "Upstream head: " .. tostring(conflict.upstream_sha),
    "Integration parent: " .. tostring(conflict.integration_sha),
    "",
    "Unmerged paths:",
    table.concat(path_lines, "\n"),
    "",
    "Resolve the branch sync conflict manually or split the conflicting work so the rollup can make progress.",
  }
  local branch_sync_ref = M.branch_sync_source_ref(
    conflict.repo,
    conflict.upstream_branch,
    conflict.integration_branch
  )
  local owner_issue_number = sync_conflict_owner.owner_issue_number(
    conflict.repo,
    conflict.integration_branch
  )
  if tostring(conflict.source_ref and conflict.source_ref.kind or "") == tostring(branch_sync_ref.kind)
    and tostring(conflict.source_ref and conflict.source_ref.ref or "") == tostring(branch_sync_ref.ref)
    and owner_issue_number ~= nil then
    table.insert(body_lines, 1, "")
    table.insert(body_lines, 1, sync_conflict_owner.marker(
      conflict.repo,
      conflict.integration_branch,
      conflict.integration_sha
    ))
  end
  local body = table.concat(body_lines, "\n")
  if #body > M._max_body_len then
    body = base_ids.truncate_utf8(body, M._max_body_len)
  end

  return {
    schema = "github-proxy.issue-create.v1",
    repo = conflict.repo,
    title = title,
    body = body,
    labels = json.decode("[]"),
    dedup_key = base_ids.dedup_key({
      "sync-conflict-escalation",
      M.sync_conflict_lineage(conflict),
    }),
    source_ref = base_ids.normalize_source_ref(conflict.source_ref),
  }
end
end

return S
