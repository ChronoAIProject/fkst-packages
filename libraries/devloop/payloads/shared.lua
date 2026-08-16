local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local parsers_shared = require("devloop.parsers.shared")
local strings = require("contract.strings")
local C = {}
local github_handle = nil
local github_factory = require("devloop.github_factory")

function C.github(_M)
  if github_handle ~= nil then
    return github_handle
  end
  if type(exec_argv) ~= "function" then
    error("github-devloop: github-adapter-missing-exec-argv: GitHub adapter requires exec_argv")
  end
  github_handle = github_factory.production_handle()
  return github_handle
end

function C.label_names(_M, labels)
  return parsers_shared.label_names(labels)
end

function C.bounded_framing(framing)
  if framing == nil then
    return nil
  end
  local value = tostring(framing)
  if #value > devloop_base._max_framing_len then
    value = base_ids.truncate_utf8(value, devloop_base._max_framing_len)
  end
  return value
end

function C.bounded_control_text(value, limit)
  local text = strings.normalize_control_line(value)
  if text == nil then
    return nil
  end
  local cap = limit or devloop_base._max_blocking_gap_len
  if #text > cap then
    text = base_ids.truncate_utf8(text, cap)
  end
  return text
end

function C.issue_redrive_delivery_dedup_key(proposal_id, effect_version, redrive_delivery)
  if not devloop_base.is_safe_proposal_ref(proposal_id, effect_version) then
    error("github-devloop: issue-redrive-effect-version-invalid: invalid issue redrive effect version")
  end
  if type(redrive_delivery) ~= "table"
    or not strings.is_path_safe_key(redrive_delivery.generation_key, devloop_base._max_dedup_len) then
    error("github-devloop: issue-redrive-generation-invalid: invalid issue redrive generation")
  end
  local attempt = tonumber(redrive_delivery.attempt)
  if attempt == nil or attempt < 1 or attempt ~= math.floor(attempt) then
    error("github-devloop: issue-redrive-attempt-invalid: invalid issue redrive attempt")
  end
  return base_ids.dedup_key({
    effect_version,
    "delivery-redrive",
    redrive_delivery.generation_key,
    tostring(attempt),
  })
end

function C.ready_operator_reimplement_delivery_dedup_key(proposal_id, implementation_version, delivery)
  if not devloop_base.is_safe_proposal_ref(proposal_id, implementation_version) then
    error("github-devloop: operator-reimplement-version-invalid: invalid operator reimplement version")
  end
  if type(delivery) ~= "table"
    or not strings.is_path_safe_key(delivery.command_key, devloop_base._max_dedup_len) then
    error("github-devloop: operator-reimplement-command-key-invalid: invalid operator reimplement command key")
  end
  return base_ids.dedup_key({
    implementation_version,
    "operator-reimplement",
    delivery.command_key,
  })
end

return C
