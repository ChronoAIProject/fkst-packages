local T = {
  source_queue = "devloop_branch_poll",
  target_queue = "devloop_branch_tick",
  schema = "github-devloop.branch-tick.v1",
  dedup_key = "github-devloop-integration/devloop-branch-tick/forbid",
  poll_interval = "5m",
  overlap_policy = "Forbid",
}

function T.payload()
  return {
    schema = T.schema,
    dedup_key = T.dedup_key,
  }
end

return T
