local entity_list_cache = require("devloop.entity_list_cache")
local h = require("tests.proxy_integration_helpers")
local author_policy = require("testkit_internal.github_author_policy")
local testing = require("testkit_internal.testing")
local github_poll = require("departments.github_poll.main")
local t = h.t

return {
  test_github_poll_records_the_current_authorization_epoch = function()
    local event = {
      queue = "github_poll_tick",
      ts = "2026-07-30T01:02:03Z",
      payload = {},
    }
    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    author_policy.mock_env(t, h.opts("poll-authorization-epoch"))
    h.mock_poll()

    local recorded_repo = nil
    local recorded_epoch = nil
    local original_record = entity_list_cache.record_poll_epoch
    entity_list_cache.record_poll_epoch = function(repo, epoch)
      recorded_repo = repo
      recorded_epoch = epoch
      return epoch
    end
    local ok, result = pcall(testing.run_fake, github_poll, event)
    entity_list_cache.record_poll_epoch = original_record
    if not ok then
      error(result, 0)
    end

    t.eq(recorded_repo, "owner/x")
    t.eq(recorded_epoch, event.ts)
    t.eq(result.raises[1].payload.poll_token, recorded_epoch)
  end,
}
