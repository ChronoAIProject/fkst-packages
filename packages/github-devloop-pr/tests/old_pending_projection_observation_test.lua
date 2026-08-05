local t = fkst.test

return {
  test_pending_projection_is_pinned_by_the_protected_observation_artifact = function()
    local inventory = json.decode(file.read("migration/restart-lifecycle.inventory.json"))
    local observation = inventory.old_pending_projection or {}
    t.eq(observation.observation_id, "fact-old-pending-projection-exact-graph")
    t.eq(observation.status, "observed")
    t.eq(observation.site.path, "libraries/devloop/restart_pending_projection.lua")
    t.eq(observation.site.symbol, "can_reach")
    t.eq(observation.site.ordinal, "transition_status:pending-projection")
    t.eq(#observation.projection_edges, 33, "complete protected pending projection")
    for _, record in ipairs(observation.projection_edges) do
      t.eq(type(record.edge), "string")
      t.is_true(record.transition_status == "pending" or record.transition_status == "apply")
    end
  end,
}
