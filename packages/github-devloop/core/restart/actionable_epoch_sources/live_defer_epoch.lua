return {
  source = "live_defer_epoch:v1",
  durable = true,
  opens_generation = true,
  excludes_deferred_time = true,
  allowed_when = "live_defer_with_clear_fact",
  requires_live_marker = true,
  requires_clear_fact = true,
  requires_observed_fact = true,
}
