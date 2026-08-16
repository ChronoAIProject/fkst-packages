local binding = {
  family = "merge-gate-wait",
  resolver = "merge-gate-wait",
  surface = "pr-comment-stream",
  version_form = "raw",
  producer = "core/merge_ci_wait.lua",
  queue = "github-proxy.github_pr_comment_request",
  marker_source = "libraries/devloop/merge_gate_wait.lua",
  request_source = "libraries/devloop/merge_gate_wait.lua",
  marker_builder = "merge_gate_wait_marker",
  request_builder = "build_merge_gate_wait_comment_request",
}

function binding.progress_signal()
  return {
    family = binding.family,
    producer = binding.family,
    resolver = binding.resolver,
    surface = binding.surface,
    version_form = binding.version_form,
    max_age_minutes = 360,
  }
end

return binding
