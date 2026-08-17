local keys = require("forge.merge.self_heal_keys")
local h = require("tests.devloop_helpers")
local t = h.t

local sha = string.rep("a", 40)

return {
  test_self_heal_keys_preserve_durable_bytes = function()
    t.eq(
      keys.ci_selfheal_once_key(nil, nil, sha),
      "github-devloop/ci-selfheal/empty/pr/empty/" .. sha
    )
    t.eq(
      keys.ci_missing_status_first_observed_key("//Owner///Repo//", " #42? ", sha),
      "github-devloop/ci-missing-status-observed/Owner/Repo/pr/-#42--/" .. sha
    )
    t.eq(
      keys.ci_selfheal_once_key(string.rep("r", 101), string.rep("9", 31), sha),
      "github-devloop/ci-selfheal/" .. string.rep("r", 100) .. "/pr/" .. string.rep("9", 30) .. "/" .. sha
    )
    t.eq(
      keys.ci_verification_selfheal_once_key("owner/repo", 42, sha, string.rep("b", 40)),
      "github-devloop/ci-verification-selfheal/owner/repo/pr/42/" .. sha .. "/" .. string.rep("b", 40)
    )
  end,

  test_self_heal_keys_reject_invalid_head_sha = function()
    t.raises(function()
      keys.ci_selfheal_once_key("owner/repo", 42, "not-a-sha")
    end)
    t.raises(function()
      keys.ci_missing_status_first_observed_key("owner/repo", 42, "")
    end)
    t.raises(function()
      keys.ci_verification_selfheal_once_key("owner/repo", 42, sha, "not-a-sha")
    end)
    t.raises(function()
      keys.ci_verification_selfheal_first_observed_key("owner/repo", 42, sha, "")
    end)
  end,
}
