local t = fkst.test

local M = {}

-- Stubs the FKST_GITHUB_REPO env read with `repo`. devloop_base is injected because this library
-- may depend only on contract, workflow and forge, while devloop.base lives in devloop.
function M.bind_mock_repo(devloop_base, repo)
  return function()
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
  end
end

-- Stubs the upstream and integration branch env reads. Six suites carried this identically.
function M.mock_branch_config()
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

return M
