local h = require("tests.proxy_integration_helpers")
local t = h.t
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_label_write = h.mock_label_write
local mock_repo_label_list = h.mock_repo_label_list
local mock_label_create = h.mock_label_create
local calls_matching = h.calls_matching
local count_calls = h.count_calls
local capture_label_department_logs = h.capture_label_department_logs
local long_dedup = h.long_dedup

local function has_arg_pair(rendered, flag, value)
  local text = tostring(rendered or "")
  return text:find(tostring(flag) .. " '" .. tostring(value) .. "'", 1, true) ~= nil
    or text:find(tostring(flag) .. " " .. tostring(value), 1, true) ~= nil
end

return {
  test_label_request_dry_run_write_and_rewrite = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = { "adapter-ready" },
        remove_labels = { "adapter-thinking" },
        dedup_key = "generic-workflow/issue/owner/x/42/result",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    mock_write_env("")
    local dry_logs, dry_write_requests = capture_label_department_logs(
      "departments/github_issue_label/main.lua",
      event,
      ""
    )
    t.eq(dry_write_requests, 0)
    t.eq(dry_logs[1], "github-proxy dept=github_issue_label tag=OUTBOUND mode=dry-run repo=owner/x issue=42 add=adapter-ready remove=adapter-thinking dedup_key=generic-workflow/issue/owner/x/42/result reason=FKST_GITHUB_WRITE!=1")

    local dry = t.run_department("departments/github_issue_label/main.lua", event, opts("label-dry-run"))
    t.eq(dry.exit_code, 0)
    t.eq(count_calls("gh issue edit"), 0)

    local write_opts = opts("label-write", {
      FKST_GITHUB_WRITE = "1",
    })
    local real_logs, real_write_requests = capture_label_department_logs(
      "departments/github_issue_label/main.lua",
      event,
      "1"
    )
    t.eq(real_write_requests, 1)
    t.eq(real_logs[1], "github-proxy dept=github_issue_label tag=OUTBOUND mode=real repo=owner/x issue=42 add=adapter-ready remove=adapter-thinking dedup_key=generic-workflow/issue/owner/x/42/result")

    mock_write_env("1")
    mock_label_write()
    local write = t.run_department("departments/github_issue_label/main.lua", event, write_opts)
    t.eq(write.exit_code, 0)
    t.eq(count_calls("gh label list"), 1)
    t.eq(count_calls("gh label create"), 0)
    t.eq(count_calls("gh issue edit"), 1)
    local edit_calls = calls_matching("gh issue edit")
    t.is_true(has_arg_pair(edit_calls[1].rendered, "--add-label", "adapter-ready"))
    t.is_true(has_arg_pair(edit_calls[1].rendered, "--remove-label", "adapter-thinking"))

    mock_write_env("1")
    mock_label_write()
    local again = t.run_department("departments/github_issue_label/main.lua", event, write_opts)
    t.eq(again.exit_code, 0)
    t.eq(count_calls("gh label list"), 2)
    t.eq(count_calls("gh label create"), 0)
    t.eq(count_calls("gh issue edit"), 2)
  end,

  test_label_request_creates_missing_repo_label_before_add = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = { "adapter-fresh" },
        remove_labels = {},
        dedup_key = "generic-workflow/issue/owner/x/42/fresh-label",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    mock_write_env("1")
    mock_repo_label_list({ "adapter-ready" })
    mock_label_create()
    t.mock_command("gh issue edit", { stdout = "", exit_code = 0 })
    local result = t.run_department("departments/github_issue_label/main.lua", event, opts("label-create-missing", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh label list"), 1)
    t.eq(count_calls("gh label create"), 1)
    t.eq(count_calls("gh issue edit"), 1)
    local create = calls_matching("gh label create")[1]
    t.is_true(create.rendered:find("adapter-fresh", 1, true) ~= nil)
    t.is_true(create.rendered:find("--repo owner/x", 1, true) ~= nil)
    local edit = calls_matching("gh issue edit")[1]
    t.is_true(has_arg_pair(edit.rendered, "--add-label", "adapter-fresh"))
  end,

  test_label_request_skips_remove_when_repo_label_is_missing = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = {},
        remove_labels = { "adapter-gone" },
        dedup_key = "generic-workflow/issue/owner/x/42/remove-gone-label",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    mock_write_env("1")
    mock_repo_label_list({ "adapter-ready" })
    local result = t.run_department("departments/github_issue_label/main.lua", event, opts("label-remove-missing", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh label list"), 1)
    t.eq(count_calls("gh label create"), 0)
    t.eq(count_calls("gh issue edit"), 0)

    local logs, write_requests = capture_label_department_logs(
      "departments/github_issue_label/main.lua",
      event,
      "1",
      false
    )
    t.eq(write_requests, 1)
    t.eq(logs[1], "github-proxy dept=github_issue_label tag=OUTBOUND mode=real repo=owner/x issue=42 add= remove=adapter-gone dedup_key=generic-workflow/issue/owner/x/42/remove-gone-label")
    t.eq(logs[2], "github-proxy dept=github_issue_label tag=SKIP reason=no-effective-label-change repo=owner/x issue=42 add= remove=adapter-gone dedup_key=generic-workflow/issue/owner/x/42/remove-gone-label")
  end,

  test_long_label_dedup_uses_bounded_lock_key = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = { "adapter-ready" },
        remove_labels = {},
        dedup_key = long_dedup("-label", 430),
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    t.is_true(#event.payload.dedup_key > 400)
    mock_write_env("1")
    mock_label_write()
    local result = t.run_department("departments/github_issue_label/main.lua", event, opts("label-long-dedup", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh issue edit"), 1)
  end,

  test_label_request_writes_without_state_precondition = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = { "adapter-ready" },
        remove_labels = { "adapter-thinking" },
        dedup_key = "generic-workflow/issue/owner/x/42/ready-hint",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    local write_opts = opts("label-no-precondition", {
      FKST_GITHUB_WRITE = "1",
    })

    mock_write_env("1")
    mock_label_write()
    local current = t.run_department("departments/github_issue_label/main.lua", event, write_opts)
    t.eq(current.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 0)
    t.eq(count_calls("gh issue edit"), 1)
    local current_edit = calls_matching("gh issue edit")[1]
    t.is_true(has_arg_pair(current_edit.rendered, "--add-label", "adapter-ready"))
    t.is_true(has_arg_pair(current_edit.rendered, "--remove-label", "adapter-thinking"))
  end,

  test_label_request_applies_exclusive_hint_without_state_precondition = function()
    local event = {
      queue = "github_issue_label_request",
      payload = {
        schema = "github-proxy.label.v1",
        repo = "owner/x",
        issue_number = 42,
        add_labels = { "adapter-blocked" },
        remove_labels = { "adapter-blocked", "adapter-thinking", "adapter-ready" },
        dedup_key = "generic-workflow/issue/owner/x/42/blocked-hint",
        source_ref = {
          kind = "external",
          ref = "owner/x#issue/42",
        },
      },
    }

    mock_write_env("1")
    mock_label_write()
    local result = t.run_department("departments/github_issue_label/main.lua", event, opts("label-blocked-hint", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 0)
    t.eq(count_calls("gh issue edit"), 1)
    local edit = calls_matching("gh issue edit")[1]
    t.is_true(has_arg_pair(edit.rendered, "--add-label", "adapter-blocked"))
    t.is_true(has_arg_pair(edit.rendered, "--remove-label", "adapter-ready"))
  end,
}
