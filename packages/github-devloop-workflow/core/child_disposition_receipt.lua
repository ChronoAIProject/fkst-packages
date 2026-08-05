local base_ids = require("devloop.base_ids")
local commands = require("devloop.commands")
local devloop_base = require("devloop.base")
local gitref = require("forge.gitref")
local marker = require("core.marker")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")

local M = {}

M.IDENTITY_SCHEMA = "github-devloop-workflow.child-disposition-identity.v1"
M.RECEIPT_SCHEMA = "github-devloop-workflow.child-disposition-receipt.v1"

local REF_PREFIX = "refs/fkst/github-devloop-workflow/child-disposition/"
local REMOTE = "origin"
local READ_TIMEOUT_SECONDS = 30
local PUSH_TIMEOUT_SECONDS = 60

local function fail(error_class, reason)
  error(
    "github-devloop-workflow: child-disposition-receipt-failed: error_class="
      .. tostring(error_class) .. " reason=" .. tostring(reason),
    0
  )
end

local function canonical_issue_number(value, field)
  if type(value) ~= "string" and type(value) ~= "number" then
    fail("receipt-identity-invalid", field .. " must be a positive issue number")
  end
  local text = tostring(value)
  local number = tonumber(text)
  if text:find("^[1-9]%d*$") == nil
    or number == nil
    or number ~= math.floor(number)
    or number > 2147483647 then
    fail("receipt-identity-invalid", field .. " must be a canonical positive issue number")
  end
  return text
end

local function normalize_identity(value)
  if type(value) ~= "table" then
    fail("receipt-identity-invalid", "identity must be a table")
  end
  if type(value.repo) ~= "string" or value.repo == "" or base_ids.safe_repo(value.repo) ~= value.repo then
    fail("receipt-identity-invalid", "repo must be a canonical repository identity")
  end
  if type(value.origin) ~= "string" then
    fail("receipt-identity-invalid", "origin must be a proposal identity")
  end
  local origin_repo, origin_issue = base_ids.parse_proposal_id(value.origin)
  if origin_repo ~= value.repo then
    fail("receipt-identity-invalid", "origin must belong to repo")
  end
  canonical_issue_number(origin_issue, "origin issue")
  local child_issue = canonical_issue_number(value.child_issue, "child_issue")
  if not base_ids.issue_ref_round_trips(value.repo, child_issue) then
    fail("receipt-identity-invalid", "child issue identity must round-trip")
  end
  if type(value.blueprint_digest) ~= "string" or type(value.slot) ~= "string" then
    fail("receipt-identity-invalid", "blueprint_digest and slot must be strings")
  end
  local lineage = marker.build_lineage_header(value.origin, value.blueprint_digest, value.slot)
  if lineage == nil then
    fail("receipt-identity-invalid", "workflow lineage is invalid")
  end
  return {
    repo = value.repo,
    origin = value.origin,
    blueprint_digest = value.blueprint_digest,
    slot = value.slot,
    child_issue = child_issue,
  }
end

local function append_field(parts, name, value)
  parts[#parts + 1] = name
  parts[#parts + 1] = tostring(#value)
  parts[#parts + 1] = value
end

function M.canonical_identity(value)
  local identity = normalize_identity(value)
  local parts = {}
  append_field(parts, "schema", M.IDENTITY_SCHEMA)
  append_field(parts, "repo", identity.repo)
  append_field(parts, "origin", identity.origin)
  append_field(parts, "blueprint_digest", identity.blueprint_digest)
  append_field(parts, "slot", identity.slot)
  append_field(parts, "child_issue", identity.child_issue)
  return table.concat(parts, "\n")
end

function M.receipt_ref(value)
  return REF_PREFIX .. sha256.hex(M.canonical_identity(value))
end

local function normalize_successor_source_ref(value, identity)
  local successor_repo, successor_issue = devloop_base.parse_issue_source_ref(value)
  if successor_repo == nil or successor_repo ~= identity.repo then
    fail("receipt-successor-invalid", "successor_source_ref must be a canonical issue ref in repo")
  end
  local successor = {
    kind = "external",
    ref = tostring(successor_repo) .. "#issue/" .. tostring(successor_issue),
  }
  if successor.ref == identity.repo .. "#issue/" .. identity.child_issue then
    fail("receipt-successor-invalid", "transferred successor must differ from child_issue")
  end
  return successor
end

local function normalize_disposition(value, identity)
  if value.disposition == "satisfied" then
    if value.successor_source_ref ~= nil then
      fail("receipt-successor-invalid", "satisfied receipts must not carry a successor")
    end
    return "satisfied", nil
  end
  if value.disposition == "transferred" then
    local successor = normalize_successor_source_ref(value.successor_source_ref, identity)
    return "transferred", successor
  end
  fail("receipt-disposition-invalid", "disposition must be satisfied or transferred")
end

local function encode_receipt(identity, disposition, successor_source_ref)
  local encoded = "{"
    .. '"schema":' .. strings.json_string(M.RECEIPT_SCHEMA)
    .. ',"repo":' .. strings.json_string(identity.repo)
    .. ',"origin":' .. strings.json_string(identity.origin)
    .. ',"blueprint_digest":' .. strings.json_string(identity.blueprint_digest)
    .. ',"slot":' .. strings.json_string(identity.slot)
    .. ',"child_issue":' .. strings.json_string(identity.child_issue)
    .. ',"disposition":' .. strings.json_string(disposition)
  if successor_source_ref ~= nil then
    encoded = encoded
      .. ',"successor_kind":' .. strings.json_string(successor_source_ref.kind)
      .. ',"successor_ref":' .. strings.json_string(successor_source_ref.ref)
  end
  return encoded .. "}"
end

local function operation_result(result, error_class, operation)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    fail(error_class, operation .. " failed: " .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

local function remote_ref_sha(stdout, expected_ref)
  local sha = nil
  for line in (tostring(stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local candidate, listed_ref = line:match("^(%x+)%s+([^%s]+)$")
      if candidate == nil or listed_ref ~= expected_ref or not gitref.is_git_sha(candidate) or sha ~= nil then
        fail("receipt-ref-invalid", "ls-remote returned an invalid receipt ref")
      end
      sha = candidate
    end
  end
  return sha
end

local function commit_message(stdout)
  local text = tostring(stdout or ""):gsub("\r\n", "\n")
  local boundary = text:find("\n\n", 1, true)
  if boundary == nil then
    fail("receipt-commit-invalid", "receipt commit has no message boundary")
  end
  local headers = text:sub(1, boundary - 1)
  local tree_count = 0
  for line in (headers .. "\n"):gmatch("([^\n]*)\n") do
    local tree_sha = line:match("^tree (%x+)$")
    if tree_sha ~= nil then
      if not gitref.is_git_sha(tree_sha) then
        fail("receipt-commit-invalid", "receipt commit tree is invalid")
      end
      tree_count = tree_count + 1
    elseif line:find("^parent ") ~= nil then
      fail("receipt-commit-not-root", "receipt commit must be parentless")
    end
  end
  if tree_count ~= 1 then
    fail("receipt-commit-invalid", "receipt commit must contain one tree header")
  end
  local message = text:sub(boundary + 2)
  if strings.trim(message) == "" then
    fail("receipt-commit-invalid", "receipt commit message is empty")
  end
  return message
end

local receipt_fields = {
  schema = true,
  repo = true,
  origin = true,
  blueprint_digest = true,
  slot = true,
  child_issue = true,
  disposition = true,
  successor_kind = true,
  successor_ref = true,
}

local function decode_receipt(decoder, message, expected, commit_sha)
  local ok, decoded = pcall(decoder.decode, message)
  if not ok or type(decoded) ~= "table" then
    fail("receipt-decode-failed", "receipt commit message is not valid JSON")
  end
  for key in pairs(decoded) do
    if receipt_fields[key] ~= true then
      fail("receipt-invalid", "receipt contains an unsupported field")
    end
  end
  if decoded.schema ~= M.RECEIPT_SCHEMA then
    fail("receipt-invalid", "receipt schema or disposition is invalid")
  end
  local normalized_ok, embedded = pcall(normalize_identity, decoded)
  if not normalized_ok then
    fail("receipt-invalid", "receipt embeds an invalid identity")
  end
  for _, field in ipairs({ "repo", "origin", "blueprint_digest", "slot", "child_issue" }) do
    if embedded[field] ~= expected[field] then
      fail("receipt-identity-mismatch", "receipt identity differs at " .. field)
    end
  end
  local receipt_value = {
    schema = M.RECEIPT_SCHEMA,
    repo = embedded.repo,
    origin = embedded.origin,
    blueprint_digest = embedded.blueprint_digest,
    slot = embedded.slot,
    child_issue = embedded.child_issue,
    disposition = decoded.disposition,
    commit_sha = commit_sha,
  }
  if decoded.disposition == "satisfied" then
    if decoded.successor_kind ~= nil or decoded.successor_ref ~= nil then
      fail("receipt-invalid", "satisfied receipt carries successor fields")
    end
  elseif decoded.disposition == "transferred" then
    receipt_value.successor_source_ref = normalize_successor_source_ref({
      kind = decoded.successor_kind,
      ref = decoded.successor_ref,
    }, embedded)
  else
    fail("receipt-invalid", "receipt schema or disposition is invalid")
  end
  return receipt_value
end

local function body_file(identity)
  return "/tmp/fkst-github-devloop-workflow-child-disposition-"
    .. sha256.hex(M.canonical_identity(identity)) .. ".json"
end

function M.new(deps)
  local selected = deps or {}
  local adapter = selected.commands or commands
  if selected.git ~= nil then
    local git = selected.git
    adapter = {
      git_ls_remote_ref = function(...) return git.ls_remote_ref(...) end,
      git_fetch_ref = function(...) return git.fetch_ref(...) end,
      git_cat_file_pretty = function(...) return git.cat_file_pretty(...) end,
      git_rev_parse_ref_commit = function(...) return git.rev_parse_ref_commit(...) end,
      git_rev_parse_ref_tree = function(...) return git.rev_parse_ref_tree(...) end,
      git_commit_tree = function(...) return git.commit_tree(...) end,
      git_push_ref_update = function(...) return git.push_ref_update(...) end,
    }
  end
  local file_port = selected.file or file
  local decoder = selected.json or json

  local function read(value)
    local identity = normalize_identity(value)
    local ref = M.receipt_ref(identity)
    local listed = operation_result(
      adapter.git_ls_remote_ref(REMOTE, ref, READ_TIMEOUT_SECONDS),
      "receipt-list-failed",
      "receipt ls-remote"
    )
    local commit_sha = remote_ref_sha(listed.stdout, ref)
    if commit_sha == nil then
      return nil
    end
    operation_result(
      adapter.git_fetch_ref(REMOTE, ref, READ_TIMEOUT_SECONDS),
      "receipt-fetch-failed",
      "receipt fetch"
    )
    local resolved = operation_result(
      adapter.git_rev_parse_ref_commit(commit_sha, READ_TIMEOUT_SECONDS),
      "receipt-object-not-commit",
      "receipt commit verification"
    )
    if strings.trim(resolved.stdout) ~= commit_sha then
      fail("receipt-object-not-commit", "receipt ref does not name the resolved commit directly")
    end
    local committed = operation_result(
      adapter.git_cat_file_pretty(commit_sha, READ_TIMEOUT_SECONDS),
      "receipt-read-failed",
      "receipt cat-file"
    )
    return decode_receipt(decoder, commit_message(committed.stdout), identity, commit_sha)
  end

  local function put_once(value)
    if type(value) ~= "table" then
      fail("receipt-disposition-invalid", "receipt must be a table")
    end
    local identity = normalize_identity(value)
    local disposition, successor_source_ref = normalize_disposition(value, identity)
    local existing = read(identity)
    if existing ~= nil then
      return existing
    end

    local tree = operation_result(
      adapter.git_rev_parse_ref_tree("HEAD", READ_TIMEOUT_SECONDS),
      "receipt-tree-failed",
      "receipt tree read"
    )
    local tree_sha = strings.trim(tree.stdout)
    if not gitref.is_git_sha(tree_sha) then
      fail("receipt-tree-invalid", "receipt tree SHA is invalid")
    end
    local path = body_file(identity)
    file_port.write(path, encode_receipt(identity, disposition, successor_source_ref) .. "\n")
    local committed = operation_result(
      adapter.git_commit_tree(tree_sha, nil, path, READ_TIMEOUT_SECONDS),
      "receipt-commit-failed",
      "receipt commit-tree"
    )
    local candidate_sha = strings.trim(committed.stdout)
    if not gitref.is_git_sha(candidate_sha) then
      fail("receipt-commit-invalid", "receipt commit SHA is invalid")
    end

    local pushed = adapter.git_push_ref_update(
      REMOTE,
      candidate_sha,
      M.receipt_ref(identity),
      false,
      PUSH_TIMEOUT_SECONDS
    )
    if type(pushed) ~= "table" or tonumber(pushed.exit_code) ~= 0 then
      local visible_ok, winner = pcall(read, identity)
      if visible_ok and winner ~= nil then
        return winner
      end
      fail("receipt-push-failed", "receipt ref creation failed: "
        .. tostring(pushed and pushed.stderr or "missing result"))
    end

    local visible = read(identity)
    if visible == nil then
      fail("receipt-readback-missing", "receipt ref is not source-visible after push")
    end
    return visible
  end

  return {
    read = read,
    put_once = put_once,
  }
end

function M.install(target)
  target.child_disposition_receipt = M
end

return M
