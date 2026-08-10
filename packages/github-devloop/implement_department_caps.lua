local core = require("core")

return {
  git_handle = assert(core.git),
  impl_failure_marker = core.impl_failure_marker,
  implement_attempt_marker = core.implement_attempt_marker,
  implement_version_mismatch_marker = core.implement_version_mismatch_marker,
  implementation_refusal_marker = core.implementation_refusal_marker,
  dependency_wait_marker = core.dependency_wait_marker,
  output_language = core.output_language,
  prompts = require("core.devloop_wiring").prompts(),
  ready_split_version = core.ready_split_version,
  require_supported_implementation_refusal_reason = core.require_supported_implementation_refusal_reason,
  restart_policy = assert(rawget(core, "restart_policy")),
  restart_effect_facade = require("core.restart_effect_facade"),
  restart_effects = require("core.restart_effects"),
  restart_package_name = assert(rawget(core, "restart_package_name")),
  sink_inventory = require("core.restart.sink_inventory"),
}
