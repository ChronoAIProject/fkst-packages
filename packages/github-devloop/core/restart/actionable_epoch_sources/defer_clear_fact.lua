return {
  source = "defer_clear_fact:v1",
  durable = true,
  opens_generation = true,
  excludes_deferred_time = true,
  allowed_when = "defer_clear_fact",
  requires_clear_fact = true,
}
