local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local ready = h.ready

return {
  test_implementing_comment_request_carries_open_pr_handoff = function()
    local event = ready()
    local handoff = {
      kind = "github-devloop.open_pr",
      proposal_id = event.proposal_id,
      repo = "owner/repo",
      issue_number = 42,
      version = event.dedup_key,
      dedup_key = event.dedup_key,
      branch = "devloop-owner-repo-42-01HY",
      head_sha = "def456",
      base_branch = "dev",
      source_ref = event.source_ref,
    }
    local request = core.build_implementing_comment_request(
      "owner/repo",
      42,
      event,
      "/tmp/devloop-owner-repo-42",
      "devloop-owner-repo-42-01HY",
      "def456",
      "dev",
      "abc123",
      1,
      "123",
      "exec-ref-1",
      handoff
    )

    t.eq(request.handoff.kind, "github-devloop.open_pr")
    t.eq(request.handoff.proposal_id, event.proposal_id)
    t.eq(request.handoff.repo, "owner/repo")
    t.eq(tostring(request.handoff.issue_number), "42")
    t.eq(request.handoff.version, event.dedup_key)
    t.eq(request.handoff.dedup_key, event.dedup_key)
    t.eq(request.handoff.branch, "devloop-owner-repo-42-01HY")
    t.eq(request.handoff.head_sha, "def456")
    t.eq(request.handoff.base_branch, "dev")
    t.eq(request.handoff.source_ref.ref, event.source_ref.ref)
  end,
}
