local devloop_base = require("devloop.base")

local M = {}
local PROTOCOL = "FKST_IMPLEMENTATION_WORKTREE_LEASE:v1"

local lease_script = [[
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import uuid

PROTOCOL = "FKST_IMPLEMENTATION_WORKTREE_LEASE:v1"


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def process_start_identity(pid):
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    started = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    state = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    identity = started.stdout.strip()
    process_state = state.stdout.strip()
    if started.returncode == 0 and state.returncode == 0 and identity and process_state:
        return None if process_state.startswith("Z") else identity
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError as exc:
        fail(f"worktree lease owner identity is unreadable for live pid {pid}: {exc}")
    fail(f"worktree lease owner identity is unreadable for live pid {pid}")


def load_owner(owner_path):
    try:
        raw = owner_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail(f"worktree lease owner read failed: {exc}")
    try:
        owner = json.loads(raw)
    except (TypeError, ValueError) as exc:
        fail(f"worktree lease owner is malformed: {exc}")
    if (
        not isinstance(owner, dict)
        or owner.get("schema") != PROTOCOL
        or not isinstance(owner.get("pid"), int)
        or owner["pid"] < 1
        or not isinstance(owner.get("start_identity"), str)
        or not owner["start_identity"]
        or not isinstance(owner.get("token"), str)
        or not owner["token"]
    ):
        fail("worktree lease owner is malformed: required identity fields are missing")
    return owner


def write_owner(owner_path, owner):
    temporary = owner_path.with_name(owner_path.name + ".tmp-" + owner["token"])
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            json.dump(owner, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary, owner_path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def acquire(owner_path, owner_pid):
    owner = load_owner(owner_path)
    if owner is not None:
        current_identity = process_start_identity(owner["pid"])
        if current_identity == owner["start_identity"]:
            print(f"{PROTOCOL}:BUSY:{owner['pid']}")
            return
    start_identity = process_start_identity(owner_pid)
    if start_identity is None:
        fail(f"worktree lease claimant pid {owner_pid} is not running")
    token = uuid.uuid4().hex
    write_owner(owner_path, {
        "schema": PROTOCOL,
        "pid": owner_pid,
        "start_identity": start_identity,
        "token": token,
    })
    print(f"{PROTOCOL}:ACQUIRED:{token}")


def release(owner_path, token):
    owner = load_owner(owner_path)
    if owner is not None:
        if owner["token"] != token:
            fail("worktree lease release token does not own the current lease")
        try:
            owner_path.unlink()
        except FileNotFoundError:
            pass
    print(f"{PROTOCOL}:RELEASED:{token}")


def main():
    if len(sys.argv) != 5:
        fail("worktree lease helper received an invalid argument count")
    action, lease_path, token, owner_pid = sys.argv[1:]
    lease = pathlib.Path(lease_path)
    lease.parent.mkdir(parents=True, exist_ok=True)
    owner_path = pathlib.Path(str(lease) + ".owner")
    lock_path = pathlib.Path(str(lease) + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        if action == "acquire":
            if token:
                fail("worktree lease acquire token must be empty")
            try:
                pid = int(owner_pid)
            except ValueError:
                fail("worktree lease claimant pid is invalid")
            acquire(owner_path, pid)
        elif action == "release":
            if not token:
                fail("worktree lease release token is missing")
            release(owner_path, token)
        else:
            fail(f"worktree lease action is invalid: {action}")


main()
]]

local function lease_path(worktree)
  local path = tostring(worktree or "")
  if path == "" or path:find("[\r\n]") ~= nil or path:sub(1, 1) ~= "/" then
    error("github-devloop: implementation-worktree-lease-path-invalid: worktree path must be absolute")
  end
  return path:gsub("/+$", "") .. ".local-iteration-lease"
end

local function command(action, path, token)
  return '"${FKST_PYTHON:-python3}" -c '
    .. devloop_base._shell_single_quote(lease_script)
    .. " " .. devloop_base._shell_single_quote(action)
    .. " " .. devloop_base._shell_single_quote(lease_path(path))
    .. " " .. devloop_base._shell_single_quote(token or "")
    .. ' "$PPID"'
end

local function parse_result(action, result)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop: implementation-worktree-lease-command-failed: " .. action .. ": "
      .. tostring(type(result) == "table" and result.stderr or "missing command result"), 0)
  end
  local status, value = tostring(result.stdout or ""):gsub("[\r\n]+$", "")
    :match("^" .. PROTOCOL .. ":([A-Z]+):([^\r\n]+)$")
  if value == nil then
    error("github-devloop: implementation-worktree-lease-command-failed: "
      .. action .. ": helper returned a malformed result", 0)
  end
  return status, value
end

function M.make(deps)
  deps = deps or {}
  local exec = deps.exec or exec_sync
  if type(exec) ~= "function" then
    error("github-devloop: implementation-worktree-lease-exec-missing: exec_sync is required")
  end

  local function acquire(worktree)
    local status, value = parse_result("acquire", exec({
      cmd = command("acquire", worktree, ""),
      timeout = 30,
    }))
    if status == "BUSY" and value:match("^%d+$") ~= nil then
      return nil, tonumber(value)
    end
    if status ~= "ACQUIRED" or value:match("^[0-9a-f]+$") == nil then
      error("github-devloop: implementation-worktree-lease-acquire-failed: helper returned an invalid status", 0)
    end
    return value, nil
  end

  local function release(worktree, token)
    local status, value = parse_result("release", exec({
      cmd = command("release", worktree, token),
      timeout = 30,
    }))
    if status ~= "RELEASED" or value ~= token then
      error("github-devloop: implementation-worktree-lease-release-failed: helper returned an invalid status", 0)
    end
  end

  local function with_lease(worktree, fn)
    local token, owner_pid = acquire(worktree)
    if token == nil then
      return false, owner_pid
    end
    local ok, result = pcall(fn)
    local released, release_error = pcall(release, worktree, token)
    if not ok then
      if not released then
        error(tostring(result) .. "\nworktree lease release failed: " .. tostring(release_error), 0)
      end
      error(result, 0)
    end
    if not released then
      error(release_error, 0)
    end
    return true, result
  end

  return {
    acquire = acquire,
    release = release,
    with_lease = with_lease,
  }
end

M.lease_path = lease_path

return M
