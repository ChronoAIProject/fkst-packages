return {
  family = "implement-attempt",
  resolver = "implement-attempt",
  surface = "issue-comment-stream",
  producer = "departments/implement/main.lua",
  queue = "github-proxy.github_issue_comment_request",
  marker_source = "core/implement_attempt.lua",
  marker_builder = "implement_attempt_marker",
  request_builder = "build_implement_attempt_comment_request",
}
