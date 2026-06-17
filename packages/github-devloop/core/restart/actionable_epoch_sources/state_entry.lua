return {
  source = "state_entry:v1",
  durable = true,
  opens_generation = true,
  excludes_deferred_time = false,
  allowed_when = "no_defer_possible",
}
