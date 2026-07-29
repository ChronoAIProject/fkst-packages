local result_facts = require("devloop.markers.result_facts")
local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local M = {}

local generic_profile = "generic"
local lean_profile = "lean-proof"
local lean_toolchain_path = "lean-toolchain"

local function normalized_lean_target(framing)
  if type(framing) ~= "string" then
    return nil
  end
  local selected = nil
  local offset = 1
  while true do
    local first, last, candidate = framing:find("([%w%._%-%/#]+%.lean)", offset)
    if first == nil then
      return selected
    end
    local following = framing:sub(last + 1, last + 1)
    local normalized = strings.is_path_safe_key(candidate, devloop_base._max_key_len)
      and candidate:find("//", 1, true) == nil
      and candidate:match("[^/]+%.lean$") ~= nil
      and (following == "" or following:find("[%w_./%-]") == nil)
    if normalized then
      if selected ~= nil and selected ~= candidate then
        return nil
      end
      selected = candidate
    end
    offset = last + 1
  end
end

local function is_missing_toolchain(result)
  if type(result) ~= "table"
    or result.exit_code ~= 128
    or tostring(result.stdout or ""):gsub("%s+$", "") ~= "" then
    return false
  end
  local stderr = tostring(result.stderr or "")
  local absent = "fatal: path '" .. lean_toolchain_path .. "' does not exist in '"
  local absent_but_on_disk = "fatal: path '" .. lean_toolchain_path .. "' exists on disk, but not in '"
  return stderr:find(absent, 1, true) ~= nil
    or stderr:find(absent_but_on_disk, 1, true) ~= nil
end

function M.accepted_framing(ready, comments)
  if type(ready) ~= "table" then
    return nil
  end
  if ready.framing ~= nil then
    return ready.framing
  end
  local fact = result_facts.current_result_fact(comments, ready.proposal_id, ready.dedup_key)
  if fact ~= nil and fact.decision == "approve" then
    return fact.framing
  end
  return nil
end

function M.resolve(git, target_ref, framing)
  local target = normalized_lean_target(framing)
  if target == nil then
    return generic_profile
  end
  if type(git) ~= "table" or type(git.object_type) ~= "function" then
    error("github-devloop: implement-profile-git-adapter-unavailable: object_type is required")
  end
  local result = git.object_type(target_ref, lean_toolchain_path, 30)
  if type(result) == "table" and result.exit_code == 0 then
    local object_type = tostring(result.stdout or ""):gsub("%s+$", "")
    if object_type == "blob" then
      return lean_profile, target
    end
    return generic_profile
  end
  if is_missing_toolchain(result) then
    return generic_profile
  end
  error("github-devloop: implement-profile-source-type-read-failed: "
    .. tostring(result and result.stderr or "nil git result"))
end

return M
