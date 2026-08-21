local h = require("tests.proxy_integration_helpers")
local sha256 = require("contract.sha256")
local t = h.t
local core = h.core
local issue_list_json = h.issue_list_json
local pr_list_json = h.pr_list_json
local runtime_root = h.runtime_root
local opts = h.opts
local mock_repo_env = h.mock_repo_env
local mock_proxy_replay_budget_env = h.mock_proxy_replay_budget_env
local mock_poll_label_prefix_env = h.mock_poll_label_prefix_env
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_issue_list = h.mock_issue_list
local mock_pr_list = h.mock_pr_list
local mock_poll = h.mock_poll
local json_string = h.json_string
local comment_json = h.comment_json
local mock_comment_view = h.mock_comment_view
local mock_comment_view_failure = h.mock_comment_view_failure
local mock_comment_write = h.mock_comment_write
local mock_pr_comment_view = h.mock_pr_comment_view
local mock_pr_comment_write = h.mock_pr_comment_write
local calls_matching = h.calls_matching
local count_calls = h.count_calls
local capture_comment_department_logs = h.capture_comment_department_logs
local long_dedup = h.long_dedup
local reviewing_marker = h.reviewing_marker
local pr_json = h.poll_pr_json
local pr_list_many_json = h.poll_pr_list_many_json
local issue_json = h.poll_issue_json
local issue_list_from = h.poll_issue_list_from
local pr_list_from = h.poll_pr_list_from
local numbers = h.changed_numbers
local observed_issue_raises = h.observed_issue_raises
local changed_raises = h.changed_raises
local find_entity_raise = h.find_entity_raise
local assert_observed_issue = h.assert_observed_issue

local function allocated_poll_epoch(timestamp, sub_epoch)
  return tostring(timestamp) .. "/sub-epoch/" .. tostring(sub_epoch)
end
local issue_comment_create = "gh api --method POST repos/owner/x/issues/42/comments"

local function delivery_snapshot(deliveries, dead_letters)
  return {
    schema_version = 1,
    generated_at_ms = 1785574920000,
    source = {
      durable_root = "/tmp/fkst-durable",
      database = "/tmp/fkst-durable/delivery.redb",
      read_semantics = "single read transaction",
      history_semantics = "mutable delivery queue snapshot",
    },
    limits = { max_deliveries = 10000, max_dead_letters = 10000, max_terminal_suppressions = 10000 },
    truncated = { deliveries = false, dead_letters = false, terminal_suppressions = false },
    queues = json.decode("[]"),
    deliveries = deliveries or json.decode("[]"),
    dead_letters = dead_letters or json.decode("[]"),
    terminal_suppressions = json.decode("[]"),
  }
end

local function poll_delivery_payload_summary(dedup_key)
  return {
    schema = "github-proxy.v1",
    dedup_key = dedup_key,
    digest = string.rep("b", 64),
    bytes = 128,
  }
end

local function poll_delivery_source()
  return {
    kind = "cron",
    reference = "github-proxy.github_poll/slot/1785574800000",
  }
end

local function mock_poll_env(replay_budget, label_prefix)
  mock_repo_env()
  mock_poll_label_prefix_env(label_prefix or "adapter-")
  if replay_budget ~= nil then
    mock_proxy_replay_budget_env(replay_budget)
  end
end

return {
  h = h,
  sha256 = sha256,
  t = t,
  core = core,
  issue_list_json = issue_list_json,
  pr_list_json = pr_list_json,
  runtime_root = runtime_root,
  opts = opts,
  mock_repo_env = mock_repo_env,
  mock_proxy_replay_budget_env = mock_proxy_replay_budget_env,
  mock_poll_label_prefix_env = mock_poll_label_prefix_env,
  mock_write_env = mock_write_env,
  mock_bot_env = mock_bot_env,
  mock_issue_list = mock_issue_list,
  mock_pr_list = mock_pr_list,
  mock_poll = mock_poll,
  json_string = json_string,
  comment_json = comment_json,
  mock_comment_view = mock_comment_view,
  mock_comment_view_failure = mock_comment_view_failure,
  mock_comment_write = mock_comment_write,
  mock_pr_comment_view = mock_pr_comment_view,
  mock_pr_comment_write = mock_pr_comment_write,
  calls_matching = calls_matching,
  count_calls = count_calls,
  capture_comment_department_logs = capture_comment_department_logs,
  long_dedup = long_dedup,
  reviewing_marker = reviewing_marker,
  pr_json = pr_json,
  pr_list_many_json = pr_list_many_json,
  issue_json = issue_json,
  issue_list_from = issue_list_from,
  pr_list_from = pr_list_from,
  numbers = numbers,
  observed_issue_raises = observed_issue_raises,
  changed_raises = changed_raises,
  find_entity_raise = find_entity_raise,
  assert_observed_issue = assert_observed_issue,
  allocated_poll_epoch = allocated_poll_epoch,
  issue_comment_create = issue_comment_create,
  delivery_snapshot = delivery_snapshot,
  poll_delivery_payload_summary = poll_delivery_payload_summary,
  poll_delivery_source = poll_delivery_source,
  mock_poll_env = mock_poll_env,
}
