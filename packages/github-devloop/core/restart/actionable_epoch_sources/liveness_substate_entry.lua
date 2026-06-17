return {
  source = "liveness_substate_entry:v1",
  durable = true,
  opens_generation = true,
  excludes_deferred_time = true,
  allowed_when = "hierarchical_liveness_substate",
}
