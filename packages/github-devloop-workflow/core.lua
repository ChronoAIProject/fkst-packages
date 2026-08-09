local blueprint = require("core.blueprint")
local catalog = require("core.catalog")
local child_disposition_receipt = require("core.child_disposition_receipt")
local child_result = require("core.child_result")
local child_transfer = require("core.child_transfer")
local default_catalog = require("core.default_catalog")
local digest = require("core.digest")
local frontier = require("core.frontier")
local generator = require("core.generator")
local marker = require("core.marker")
local materialize_reconcile = require("materialize_reconcile")
local materialization = require("core.materialization")
local select_request = require("core.select_request")
local default_intake = require("devloop.intake.default")
local intake_class = require("core.intake_class")
local intake_service_class = require("core.intake_service_class")
local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local devloop_dependency_gate = require("devloop.dependency_gate")
local devloop_logging = require("devloop.logging")
local devloop_prompts = require("devloop.prompts")
local devloop_state = require("devloop.state")
local entity = require("devloop.entity")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local saga_conformance = require("devloop.saga_conformance")

local M
local intake_prompt_surface = devloop_prompts.new({
  prompts = {
    intake = default_intake.prompt,
  },
}, {
  intake = true,
  intake_parser = true,
})

local function conformance_errors()
  return saga_conformance.errors(M)
end

M = {
  blueprint = blueprint,
  catalog = catalog,
  child_disposition_receipt = child_disposition_receipt,
  child_result = child_result,
  child_transfer = child_transfer,
  default_catalog = default_catalog,
  digest = digest,
  frontier = frontier,
  generator = generator,
  marker = marker,
  materialize_reconcile = materialize_reconcile,
  materialization = materialization,
  default_intake = default_intake,
  conformance_errors = conformance_errors,
}

local function install_intake_surface(target)
  require("forge.github_debug_stamp").install(target, devloop_base.read_env)
  target.safe_updated_at = function(...) return devloop_base.safe_updated_at(...) end
  target.intake_dedup_key = function(...) return devloop_base.intake_dedup_key(...) end
  target.intake_candidate_delivery_dedup_key = function(...) return devloop_base.intake_candidate_delivery_dedup_key(...) end
  target.judgment_worktree_path = devloop_base.judgment_worktree_path
  target.max_body_len = function(...) return devloop_base.max_body_len(...) end
  target.quote_untrusted_prompt_text = function(...) return devloop_base.quote_untrusted_prompt_text(...) end
  target.gh_exec_opts = function(...) return devloop_base.gh_exec_opts(...) end
  target._max_key_len = devloop_base._max_key_len
  target._max_dedup_len = devloop_base._max_dedup_len
  target._max_title_len = devloop_base._max_title_len
  target._max_body_len = devloop_base._max_body_len
  target._max_comments_len = devloop_base._max_comments_len
  target._max_meta_reason_len = devloop_base._max_meta_reason_len
  target._max_framing_len = devloop_base._max_framing_len
  target._max_impl_output_len = devloop_base._max_impl_output_len
  target._max_blocking_gap_len = devloop_base._max_blocking_gap_len
  target._max_review_ledger_len = devloop_base._max_review_ledger_len
  target._max_pr_issue_context_len = devloop_base._max_pr_issue_context_len
  target._max_pr_title_len = devloop_base._max_pr_title_len
  target._action_label = devloop_base._action_label
  target._intake_label = devloop_base._intake_label
  target._class_label = devloop_base._class_label
  target._reason_label = devloop_base._reason_label
  target._verdict_label = devloop_base._verdict_label
  target._reply_label = devloop_base._reply_label
  target._untrusted_issue_data_begin = devloop_base._untrusted_issue_data_begin
  target._untrusted_issue_data_end = devloop_base._untrusted_issue_data_end
  target._test_bot_login = devloop_base._test_bot_login
  target._enabled_label = devloop_base._enabled_label
  target._tracking_label = devloop_base._tracking_label
  target._hold_label = devloop_base._hold_label
  target._thinking_label = devloop_base._thinking_label
  target._ready_label = devloop_base._ready_label
  target._implementing_label = devloop_base._implementing_label
  target._awaiting_pr_label = devloop_base._awaiting_pr_label
  target._pr_open_label = devloop_base._pr_open_label
  target._reviewing_label = devloop_base._reviewing_label
  target._merge_ready_label = devloop_base._merge_ready_label
  target._merging_label = devloop_base._merging_label
  target._merged_label = devloop_base._merged_label
  target._fixing_label = devloop_base._fixing_label
  target._review_meta_label = devloop_base._review_meta_label
  target._impl_failed_label = devloop_base._impl_failed_label
  target._blocked_label = devloop_base._blocked_label
  target._blocked_on_dependency_label = devloop_base._blocked_on_dependency_label
  target._label_colors = devloop_base._label_colors
  target._has_value = devloop_base._has_value
  target._is_review_meta_action = devloop_base._is_review_meta_action

  target.gh_issue_view = devloop_commands.gh_issue_view
  target.gh_issue_view_intake_judge = devloop_commands.gh_issue_view_intake_judge
  target.gh_issue_list_intake = devloop_commands.gh_issue_list_intake
  target.gh_issue_list_recent_closed = devloop_commands.gh_issue_list_recent_closed
  target.gh_pr_view_context = devloop_commands.gh_pr_view_context
  target.gh_pr_diff = devloop_commands.gh_pr_diff
  target.gh_pr_diff_name_only = devloop_commands.gh_pr_diff_name_only

  target.comment_bodies = devloop_state.comment_bodies
  target.has_label = devloop_state.has_label
  target.state_label_changes = devloop_state.state_label_changes
  target.state_marker = devloop_state.state_marker
  target.is_state_label = devloop_state.is_state_label
  target.cached_entity_view = function(...) return github_proxy_entity_view.cached_entity_view(...) end
  target.fetch_pr_view_origin = github_proxy_entity_view.fetch_pr_view_origin
  target.invalidate_entity_after_write = github_proxy_entity_view.invalidate_entity_after_write
  target.wrap_pipeline_failure = devloop_logging.wrap_pipeline_failure

  target.intake_service_class_label = intake_service_class.intake_service_class_label
  target.intake_service_class_labels = intake_service_class.intake_service_class_labels
  target.intake_service_class_label_changes = intake_service_class.intake_service_class_label_changes
  target.build_intake_service_class_label_request = function(...) return intake_service_class.build_intake_service_class_label_request(target, ...) end
  target.intake_class_identity = function(...) return intake_class.intake_class_identity(target, ...) end
  target.intake_class_carrier_marker = function(...) return intake_class.intake_class_carrier_marker(target, ...) end
  target.intake_class_followup_marker = function(...) return intake_class.intake_class_followup_marker(target, ...) end
  target.fetch_recent_closed_intake_class_issues = function(...) return intake_class.fetch_recent_closed_intake_class_issues(target, ...) end
  target.intake_class_issue_title = function(...) return intake_class.intake_class_issue_title(target, ...) end
  target.find_open_intake_class_carrier = function(...) return intake_class.find_open_intake_class_carrier(target, ...) end
  target.build_intake_class_followup_comment_request = function(...) return intake_class.build_intake_class_followup_comment_request(target, ...) end
  target.build_intake_class_folded_label_request = function(...) return intake_class.build_intake_class_folded_label_request(target, ...) end
  target.build_intake_class_issue_create_request = function(...) return intake_class.build_intake_class_issue_create_request(target, ...) end
  target.output_language = devloop_prompts.output_language
  target.prompt_preamble = devloop_prompts.prompt_preamble
  target.judge_harness_clause = devloop_prompts.judge_harness_clause
  target.actor_harness_clause = devloop_prompts.actor_harness_clause
  target.review_observation_boundary_clause = devloop_prompts.review_observation_boundary_clause
  target.short_review_observation_boundary_clause = devloop_prompts.short_review_observation_boundary_clause
  target.execution_boundary_clause = devloop_prompts.execution_boundary_clause
  target.render_prompt_template = devloop_prompts.render_prompt_template
  target.build_intake_prompt = intake_prompt_surface.build_intake_prompt
  target.parse_intake_action = intake_prompt_surface.parse_intake_action
  target.intake_prompt_surface = intake_prompt_surface
  target.linked_pr_surface_snapshot = function(...) return entity.linked_pr_surface_snapshot(target, ...) end
end

M._max_dedup_len = devloop_base._max_dedup_len
M._max_meta_reason_len = devloop_base._max_meta_reason_len
M._test_bot_login = devloop_base._test_bot_login

function M.install(target)
  blueprint.install(target)
  catalog.install(target)
  child_disposition_receipt.install(target)
  child_result.install(target)
  child_transfer.install(target)
  default_catalog.install(target)
  digest.install(target)
  frontier.install(target)
  generator.install(target)
  marker.install(target)
  materialization.install(target)
  select_request.install(target)
  target.default_intake = default_intake
  install_intake_surface(target)
  target.github_graphql_queries = devloop_dependency_gate.github_graphql_queries
  target.render_github_graphql_query = devloop_dependency_gate.render_github_graphql_query
  target.github_graphql = devloop_dependency_gate.github_graphql
  local dependency_resolver = devloop_dependency_gate.new(target)
  target.dependency_gate = dependency_resolver.dependency_gate
end

M.install(M)

return M
