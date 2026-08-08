local H = {}

local run_sequence = 0

local function codex_run_id()
  run_sequence = run_sequence + 1
  return "codex-01ARZ3NDEKTSV4RRFFQ69G" .. string.format("%04X", run_sequence)
end

local function json_string(value)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function json_value(value)
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if value == nil then
    return "null"
  end
  return '"' .. json_string(value) .. '"'
end

local function json_object(record)
  local parts = {}
  for key, value in pairs(record or {}) do
    table.insert(parts, '"' .. json_string(key) .. '":' .. json_value(value))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function log_dir(run_opts)
  local root = run_opts and run_opts.env and run_opts.env.FKST_RUNTIME_LOG_DIR
  if root == nil or root == "" then
    error("codex-lifetime-witness: runtime-log-dir-missing: FKST_RUNTIME_LOG_DIR is required to seed codex status")
  end
  return root .. "/codex"
end

local witness_program = [[
import fcntl
import os
import signal
import sys

def stop(_signum, _frame):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
handles = []
for path in sys.argv[1:]:
    handle = open(path, "r+", encoding="utf-8")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    handles.append(handle)
print(os.getpid(), flush=True)
signal.pause()
]]

local function seed_codex_run(run_opts, record)
  local dir = log_dir(run_opts)
  os.execute("mkdir -p " .. shell_quote(dir))
  local path = dir .. "/fixture-" .. tostring(record.run_id) .. ".log"
  local file = assert(io.open(path, "a"))
  file:write("CODEX_STATUS:" .. json_object(record) .. "\n")
  file:close()
  return path
end

local function live_run_timing()
  local started = now() - 60
  return os.date("!%Y-%m-%dT%H:%M:%SZ", started),
    started * 1000,
    (now() + 3600) * 1000
end

function H.role_codex_run(role, proposal_id, dedup_key, extra)
  local started_at, started_at_ms, lease_expires_at_ms = live_run_timing()
  local record = {
    run_id = codex_run_id(),
    role = role,
    dept = role,
    proposal_id = proposal_id,
    dedup_key = dedup_key,
    status = "running",
    started_at = started_at,
    started_at_ms = started_at_ms,
    lease_expires_at_ms = lease_expires_at_ms,
    timeout_seconds = 3600,
  }
  for key, value in pairs(extra or {}) do
    record[key] = value
  end
  return record
end

function H.implement_codex_run(proposal_id, dedup_key, extra)
  return H.role_codex_run("implement", proposal_id, dedup_key, extra)
end

function H.with_live_codex_runs(run_opts, running, fn)
  local command = "python3 -u -c " .. shell_quote(witness_program)
  for _, record in ipairs(running or {}) do
    command = command .. " " .. shell_quote(seed_codex_run(run_opts, record))
  end
  local holder = assert(io.popen(command, "r"))
  local pid = tonumber(holder:read("*l"))
  if pid == nil then
    holder:close()
    error("codex-lifetime-witness: readiness-not-reported: witness holder did not report its pid")
  end

  local ok, err = pcall(fn)
  local killed, kill_kind, kill_code = os.execute("kill -TERM " .. tostring(pid))
  if killed ~= true then
    error("codex-lifetime-witness: release-failed: "
      .. tostring(kill_kind) .. ":" .. tostring(kill_code))
  end
  local closed, close_kind, close_code = holder:close()
  if closed ~= true and close_code ~= 0 then
    error("codex-lifetime-witness: holder-exited-unexpectedly: "
      .. tostring(close_kind) .. ":" .. tostring(close_code))
  end
  if not ok then
    error(err, 0)
  end
end

return H
