-- Fire-raiser fixture harness for github-devloop-dev-intake. Mirrors the workflow-security
-- fixture: it stages an isolated workspace (this package + its libs + a minimal github-proxy
-- event-dep stub + a minimal github-devloop-intake stub whose department consumes the
-- candidate seam this package produces), writes a child test that fires the cron raiser
-- through the real framework, and asserts the producer-liveness trace. Runs only in CI,
-- where BIN points at the framework binary.
local H = {}

local PACKAGE = "github-devloop-dev-intake"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function read_command(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  if ok == false or ok == nil then
    error("github-devloop-dev-intake: fixture-command-failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function repo_root()
  return (read_command("pwd"):gsub("%s+$", ""))
end

local function temp_root(name)
  return (read_command("mktemp -d " .. shell_quote("/tmp/fkst-dev-intake-fire-" .. tostring(name) .. ".XXXXXX")):gsub("%s+$", ""))
end

local function copy_dir(src, dst)
  run_command("mkdir -p " .. shell_quote(dst))
  run_command("cp -R " .. shell_quote(src) .. "/. " .. shell_quote(dst) .. "/")
end

-- A minimal stub package whose single department consumes `queue` (bare, so it resolves to
-- `<package>.<queue>`). This closes the graph for a queue this package produces.
local function write_stub_consumer(root, package_name, dept, queue)
  file.write(root .. "/packages/" .. package_name .. "/fkst.toml",
    "kind = \"package\"\nname = \"" .. package_name .. "\"\n\n[code]\nroot = \".\"\n")
  local dir = root .. "/packages/" .. package_name .. "/departments/" .. dept
  run_command("mkdir -p " .. shell_quote(dir))
  file.write(dir .. "/main.lua", table.concat({
    "local M = {}",
    "M.spec = {",
    "  consumes = { " .. string.format("%q", queue) .. " },",
    "  published_seam = { " .. string.format("%q", queue) .. " },",
    "  stall_window = \"30s\",",
    "}",
    "function M.pipeline(_event)",
    "end",
    "return M",
  }, "\n") .. "\n")
end

function H.setup_workspace(name, child_test)
  local root = temp_root(name)
  local source = repo_root()
  file.write(root .. "/fkst.workspace.toml", '[workspace]\nunits = ["packages/*", "libraries/*"]\n')
  for _, lib in ipairs({ "contract", "workflow", "testkit", "forge", "devloop", "github-issue" }) do
    copy_dir(source .. "/libraries/" .. lib, root .. "/libraries/" .. lib)
  end
  copy_dir(source .. "/packages/" .. PACKAGE, root .. "/packages/" .. PACKAGE)
  run_command("rm -rf " .. shell_quote(root .. "/packages/" .. PACKAGE .. "/tests"))
  run_command("mkdir -p " .. shell_quote(root .. "/packages/" .. PACKAGE .. "/tests"))
  -- github-proxy: the declared event dep must be present.
  file.write(root .. "/packages/github-proxy/fkst.toml", "kind = \"package\"\nname = \"github-proxy\"\n\n[code]\nroot = \".\"\n")
  -- github-devloop-intake: a stub whose department consumes the candidate seam this package
  -- produces, so the produced queue has a consumer in the workspace graph.
  write_stub_consumer(root, "github-devloop-intake", "candidate_sink", "devloop_intake_candidate")
  file.write(root .. "/packages/" .. PACKAGE .. "/tests/fire_raiser_child_test.lua", child_test)
  return root
end

local function framework_bin()
  local bin = os.getenv("BIN") or "/Users/auric/fkst-substrate/target/debug/fkst-framework"
  if bin == "" then
    error("github-devloop-dev-intake: fixture-missing-bin: BIN is required")
  end
  return bin
end

function H.run_child(root)
  local bin = framework_bin()
  local command = table.concat({
    "BIN=" .. shell_quote(bin),
    "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
    "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
    shell_quote(bin),
    "test",
    "--project-root",
    shell_quote(root .. "/packages/" .. PACKAGE),
    "--package-root",
    shell_quote(root .. "/packages/" .. PACKAGE),
    "--package-root",
    shell_quote(root .. "/packages/github-proxy"),
    "--package-root",
    shell_quote(root .. "/packages/github-devloop-intake"),
  }, " ")
  return read_command(command)
end

function H.fire_raiser_child(body)
  return [[
local t = fkst.test

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
end

return {
]] .. body .. [[
}
]]
end

return H
