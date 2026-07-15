local graph = require("testkit.graph")
local t = fkst.test

local function request_event()
  local source_ref = {
    kind = "external",
    ref = "owner/repo#pr/42",
  }
  return {
    queue = "browser-qa.browser_qa_request",
    payload = {
      schema = "browser-qa.request.v1",
      repo = "owner/repo",
      pr_number = 42,
      url = "http://127.0.0.1:4173/dashboard",
      viewport = { width = 1280, height = 720 },
      dedup_key = "browser-qa/owner/repo/pr/42/dashboard/1280x720",
      source_ref = source_ref,
    },
    source_ref = {
      kind = source_ref.kind,
      reference = source_ref.ref,
    },
  }
end

return {
  test_blank_render_comment_intent_reaches_github_proxy_dry_run = function()
    t.mock_command("node -e", {
      stdout = '{"ok":true,"observation":{"visible_text_chars":0,"visible_visual_count":0},"console_error_count":0,"network_error_count":0,"screenshot_ref":{"kind":"host-worktree","ref":".fkst/artifacts/browser-qa/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.png"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(request_event(), { max_steps = 4 }))
    local inspect_delivery = graph.find_delivery(trace, {
      queue = "browser-qa.browser_qa_request",
      consumer = "browser-qa.inspect",
    })
    if inspect_delivery == nil then
      error("missing browser-qa inspect delivery: " .. graph.signature(trace), 0)
    end
    if graph.find_raise(trace, "github-proxy.github_pr_comment_request") == nil then
      error("missing browser-qa comment raise: " .. graph.signature(trace), 0)
    end
    if graph.find_delivery(trace, { queue = "github-proxy.github_pr_comment_request" }) == nil then
      error("missing github-proxy comment delivery: " .. graph.signature(trace), 0)
    end
    graph.assert_covers(trace, {
      "browser-qa.browser_qa_result -> browser-qa.result_log",
      "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
    })

    local comment, _, comment_raise_index = graph.require_raise(
      trace,
      "github-proxy.github_pr_comment_request",
      function(raised)
        return raised.payload.reason == nil
          and raised.payload.source_ref.ref == "owner/repo#pr/42"
          and raised.payload.body:find("blank-render", 1, true) ~= nil
      end
    )
    local delivery, delivery_index = graph.require_delivery(trace, {
      queue = "github-proxy.github_pr_comment_request",
      consumer = "github-proxy.github_pr_comment",
    })

    t.eq(delivery.exit_code, 0)
    t.is_true(delivery_index > comment_raise_index)
    t.eq(comment.payload.pr_number, 42)
    for _, call in ipairs(t.command_calls()) do
      t.is_true(call.program ~= "gh")
    end
  end,
}
