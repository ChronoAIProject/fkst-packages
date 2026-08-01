local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local forge_validators = require("devloop.forge_validators")
local S = {}

S.valid_round = require("devloop.rounds").valid_round
S.strings = require("contract.strings")
S.max_attr_len = 240

local intake_service_class_set = {
  expedite = true,
  standard = true,
  background = true,
}

function S.normalize_intake_service_class(value)
  local text = tostring(value or ""):lower()
  if intake_service_class_set[text] then
    return text
  end
  return "standard"
end

function S.is_intake_service_class(value)
  return intake_service_class_set[tostring(value or "")] == true
end

function S.parse_fix_feedback_fact(fact)
  if type(fact) ~= "table" then
    error("github-devloop: fix-feedback-invalid-fact: fix feedback must be a table", 2)
  end
  if fact.review_proposal_id == nil then
    error("github-devloop: fix-feedback-missing-review-proposal-id: fix feedback lacks review_proposal_id", 2)
  end
  if fact.review_dedup_key == nil then
    error("github-devloop: fix-feedback-missing-review-dedup-key: fix feedback lacks review_dedup_key", 2)
  end
  if fact.reviewed_head_sha == nil then
    error("github-devloop: fix-feedback-missing-reviewed-head-sha: fix feedback lacks reviewed_head_sha", 2)
  end
  if devloop_base.parse_pr_review_proposal_id(fact.review_proposal_id) == nil then
    error("github-devloop: fix-feedback-invalid-review-proposal-id: fix feedback has an invalid review_proposal_id", 2)
  end
  if not S.strings.is_bounded_string(fact.review_dedup_key, devloop_base._max_dedup_len) then
    error("github-devloop: fix-feedback-invalid-review-dedup-key: fix feedback has an invalid review_dedup_key", 2)
  end
  if not forge_validators.is_git_sha(fact.reviewed_head_sha) then
    error("github-devloop: fix-feedback-invalid-reviewed-head-sha: fix feedback has an invalid reviewed_head_sha", 2)
  end
  return fact
end

function S.marker_attr(marker, name)
  return marker:match(name .. '="([^"]*)"')
end

function S.safe_marker_attr(value, limit)
  local text = tostring(value or "")
  text = text:gsub("<!%-%- fkst:[^\n]*%-%->", " ")
  text = text:gsub("&lt;!%-%- fkst:[^\n]*%-%-&gt;", " ")
  text = text:gsub("%c", " "):gsub('"', "'"):gsub("[<>]", ""):gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  local cap = limit or S.max_attr_len
  if #text > cap then
    text = base_ids.truncate_utf8(text, cap)
  end
  return text
end

function S.encode_exact_marker_attr(value)
  return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

function S.decode_exact_marker_attr(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local decoded = {}
  local offset = 1
  while offset <= #value do
    local char = value:sub(offset, offset)
    if char == "%" then
      local byte = value:sub(offset + 1, offset + 2)
      if #byte ~= 2 or byte:find("^%x%x$") == nil then
        return nil
      end
      table.insert(decoded, string.char(tonumber(byte, 16)))
      offset = offset + 3
    elseif char:find("^[%w%-%._~]$") ~= nil then
      table.insert(decoded, char)
      offset = offset + 1
    else
      return nil
    end
  end
  return table.concat(decoded)
end

function S.decode_marker_attr(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if value:find("%c") ~= nil or value:find("[<>]") ~= nil or value:find('"', 1, true) ~= nil then
    return nil
  end
  return value
end

return S
