local H = {}
local testing = require("testkit_internal.testing")

local function live_run_timing()
  local started = now() - 60
  return os.date("!%Y-%m-%dT%H:%M:%SZ", started),
    started * 1000,
    (now() + 3600) * 1000
end

function H.seed_codex_run(run_opts, record)
  return testing.seed_running_codex_status(run_opts, record)
end

function H.seed_implement_codex_run(run_opts, proposal_id, dedup_key, extra)
  local started_at, started_at_ms, lease_expires_at_ms = live_run_timing()
  local record = {
    role = "implement",
    dept = "implement",
    proposal_id = proposal_id,
    dedup_key = dedup_key,
    status = "running",
    started_at = started_at,
    started_at_ms = started_at_ms,
    lease_expires_at_ms = lease_expires_at_ms,
    timeout_seconds = 3600,
    log_path = "/tmp/fkst-packages-test/codex.log",
    cmd_line = "codex exec -",
  }
  for key, value in pairs(extra or {}) do
    record[key] = value
  end
  return H.seed_codex_run(run_opts, record)
end

function H.seed_role_codex_run(run_opts, role, proposal_id, dedup_key, extra)
  local started_at, started_at_ms, lease_expires_at_ms = live_run_timing()
  local record = {
    role = role,
    dept = role,
    proposal_id = proposal_id,
    dedup_key = dedup_key,
    status = "running",
    started_at = started_at,
    started_at_ms = started_at_ms,
    lease_expires_at_ms = lease_expires_at_ms,
    timeout_seconds = 3600,
    log_path = "/tmp/fkst-packages-test/codex.log",
    cmd_line = "codex exec -",
  }
  for key, value in pairs(extra or {}) do
    record[key] = value
  end
  return H.seed_codex_run(run_opts, record)
end

return H
