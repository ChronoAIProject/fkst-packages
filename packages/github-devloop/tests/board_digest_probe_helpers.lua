local core = require("core")

local M = {}

M.spec = {
  consumes = { "board_digest_probe" },
}

local function lua_quote(value)
  return string.format("%q", tostring(value or ""))
end

local function lua_literal(value)
  local kind = type(value)
  if kind == "nil" then
    return "nil"
  end
  if kind == "boolean" or kind == "number" then
    return tostring(value)
  end
  if kind == "string" then
    return lua_quote(value)
  end
  if kind ~= "table" then
    error("github-devloop test probe: unsupported result field type")
  end
  local parts = {}
  local index = 1
  for key, field in pairs(value) do
    if key == index then
      table.insert(parts, lua_literal(field))
      index = index + 1
    else
      table.insert(parts, "[" .. lua_literal(key) .. "]=" .. lua_literal(field))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function write_result(path, payload)
  if path == nil or tostring(path) == "" then
    error("github-devloop test probe: missing result path")
  end
  file.write(path, "return " .. lua_literal(payload) .. "\n")
end

local function finish(event_payload, payload)
  write_result(event_payload.result_path, payload)
end

function pipeline(event)
  local payload = event.payload or {}
  if payload.mode == "block" then
    finish(payload, {
      body = core.board_digest_block(payload.repo, payload.tick),
    })
    return
  end

  if payload.mode == "append" then
    finish(payload, {
      proposal = core.append_board_digest_to_proposal(payload.proposal, payload.repo, payload.tick),
    })
    return
  end

  if payload.mode == "board_loop" then
    finish(payload, {
      proposal = core.build_board_loop_proposal(
        payload.repo,
        payload.issue_number,
        payload.current,
        payload.source_ref,
        payload.n,
        payload.converge,
        payload.tick
      ),
    })
    return
  end

  if payload.mode == "board_review" then
    finish(payload, {
      proposal = core.build_board_pr_review_proposal(
        payload.repo,
        payload.issue_number,
        payload.pr_number,
        payload.version,
        payload.head_sha,
        payload.current,
        payload.source_ref,
        payload.tick
      ),
    })
    return
  end

  if payload.mode == "board_review_loop" then
    finish(payload, {
      proposal = core.build_board_pr_review_loop_proposal(
        payload.repo,
        payload.issue_number,
        payload.pr_number,
        payload.version,
        payload.head_sha,
        payload.current,
        payload.source_ref,
        payload.n,
        payload.converge,
        payload.tick
      ),
    })
    return
  end

  error("github-devloop test probe: unknown mode")
end

return M
