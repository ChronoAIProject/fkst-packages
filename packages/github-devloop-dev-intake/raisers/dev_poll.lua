-- github-devloop-dev-intake owns its trigger: this cron tick drives the dev_select
-- department to discover OPEN fkst-dev issues and produce the intake candidate seam. It
-- is the adapter's OWN trigger path -- label-scoped, so it never claims a sibling
-- package's issues.
return {
  type = "cron",
  interval = "30m",
  produces = "dev_intake_tick",
}
