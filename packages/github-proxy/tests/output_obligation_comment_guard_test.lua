local t = fkst.test
local comment = require("core.comment")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local forge_strings = require("forge.strings")
local github_fake = require("forge.github_fake")
local marker_builders = require("devloop.markers.builders")
local operator_commands = require("devloop.operator_commands")

local repo = "owner/x"
local proposal_id = "github-devloop/issue/owner/x/42"
local source_issue_number = 42
local escalation_issue_number = 900
local pr_number = 7
local ready_version = "ready/2026-08-01T12-00-00Z"
local terminal_version = conv_reconcile.timeout_reconcile_state_version(ready_version, "ready", 3)
local blocked_version = ready_version .. "/review-loop/3"
local branch = "devloop-owner-x-42-live-recovery"
local head_sha = "abcdef1234567890abcdef1234567890abcdef12"

local function json_string(value)
  return '"' .. tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t") .. '"'
end

local function pr_view_stdout(pr)
  local comments = {}
  for index, item in ipairs(pr.comments or {}) do
    table.insert(comments, '{"id":' .. json_string(item.id or tostring(index))
      .. ',"body":' .. json_string(item.body)
      .. ',"author":{"login":' .. json_string(item.author_login)
      .. '},"createdAt":' .. json_string(item.created_at) .. "}")
  end
  return '{"number":' .. tostring(pr.number)
    .. ',"headRefName":' .. json_string(pr.head)
    .. ',"headRefOid":' .. json_string(pr.head_sha)
    .. ',"baseRefName":' .. json_string(pr.base_branch)
    .. ',"state":' .. json_string(pr.state)
    .. ',"updatedAt":"2026-08-01T12:10:00Z","isDraft":false'
    .. ',"comments":[' .. table.concat(comments, ",") .. ']'
    .. ',"labels":[],"headRepository":{"nameWithOwner":' .. json_string(pr.head_repo)
    .. ',"owner":{"login":"owner"}},"headRepositoryOwner":{"login":"owner"}'
    .. ',"isCrossRepository":' .. (pr.cross_repo and "true" or "false")
    .. ',"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}'
end

local function bot_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-01T12:10:00Z",
  }
end

local function timeout_marker()
  return conv_reconcile.timeout_reconcile_marker(proposal_id, ready_version, "ready", 3, "drop", {
    terminal_version = terminal_version,
    from_state = "ready",
    from_version = ready_version,
    attempt = 3,
    attempt_limit = 3,
    driving_queue = "github-devloop.devloop_ready",
    reason_class = "state-output-obligation-timeout",
    source_ref = entity_lib.issue_source_ref(repo, source_issue_number),
  })
end

local function escalation_fact()
  return {
    proposal_id = proposal_id,
    terminal_version = terminal_version,
    dedup_key = base_ids.dedup_key({
      "output-obligation",
      "blocked",
      base_ids.safe_repo(repo),
      proposal_id,
      terminal_version,
      "state-output-obligation-timeout",
    }),
    reason_class = "state-output-obligation-timeout",
    source_ref = entity_lib.issue_source_ref(repo, source_issue_number),
    source_repo = repo,
    source_issue_number = source_issue_number,
    escalation_repo = repo,
    escalation_issue_number = escalation_issue_number,
    escalation_source_ref = entity_lib.issue_source_ref(repo, escalation_issue_number),
  }
end

local function escalation_marker(fact)
  return '<!-- fkst:github-devloop-ops:output-obligation-escalation:v1 proposal="'
    .. fact.proposal_id .. '" terminal_version="' .. fact.terminal_version
    .. '" dedup="' .. fact.dedup_key .. '" reason_class="' .. fact.reason_class
    .. '" parent="' .. fact.source_ref.ref .. '" -->'
end

local function fixtures()
  local fact = escalation_fact()
  local source = {
    repo = repo,
    number = source_issue_number,
    state = "OPEN",
    title = "Recover output obligation",
    body = "Source issue",
    labels = { devloop_base._blocked_label },
    author_login = "alice",
    comments = {
      bot_comment(marker_builders.intake_decision_marker(
        proposal_id,
        "enable",
        "intake/github-devloop/issue/owner/x/42/original",
        "standard"
      )),
      bot_comment(timeout_marker()),
      bot_comment(devloop_state.state_marker(proposal_id, "blocked", terminal_version)),
      bot_comment(marker_builders.pr_delegation_marker(
        proposal_id,
        entity_lib.pr_proposal_id(repo, pr_number),
        pr_number,
        ready_version,
        "g1"
      )),
    },
  }
  local escalation = {
    repo = repo,
    number = escalation_issue_number,
    state = "OPEN",
    title = "Escalate blocked output obligation",
    body = "Escalation\n\n" .. escalation_marker(fact),
    labels = { devloop_base._hold_label },
    author_login = "fkst-test-bot",
    comments = {},
  }
  local pr = {
    repo = repo,
    number = pr_number,
    state = "OPEN",
    head = branch,
    head_sha = head_sha,
    base_branch = "dev",
    head_repo = repo,
    cross_repo = false,
    comments = {
      bot_comment(marker_builders.pr_origin_marker(
        proposal_id,
        tostring(source_issue_number),
        branch,
        ready_version,
        "dev"
      )),
      bot_comment(devloop_state.state_marker(proposal_id, "blocked", blocked_version)),
    },
  }
  return fact, source, escalation, pr
end

local function request_for(fact, source, escalation, pr)
  local target_version = operator_commands.operator_rereview_version(blocked_version, head_sha)
  local marker = '<!-- fkst:github-devloop-ops:output-obligation-command:v1 escalation_dedup="'
    .. fact.dedup_key .. '" terminal_version="' .. terminal_version
    .. '" decision="rereview" pr="' .. tostring(pr_number) .. '" head_sha="' .. head_sha
    .. '" target_version="' .. target_version .. '" -->'
  local guard = {
    schema = "github-devloop.output-obligation-command-guard.v1",
    decision = "rereview",
    fact = fact,
    target = {
      pr_number = pr_number,
      head_sha = head_sha,
      target_version = target_version,
    },
  }
  return operator_commands.build_operator_command_intent_request(
    { kind = "pr", repo = repo, number = pr_number },
    "rereview",
    "output-obligation-command/stale-delivery/rereview",
    entity_lib.pr_source_ref(repo, pr_number),
    marker,
    guard
  )
end

local function subject_for(github)
  local subject = {}
  comment.install(subject, {
    strip_bot_login_suffix = forge_strings.strip_bot_login_suffix,
  })
  subject.read_env = function(name)
    if name == "FKST_GITHUB_WRITE" then
      return "1"
    end
    if name == "FKST_GITHUB_BOT_LOGIN" then
      return "fkst-test-bot"
    end
    return nil
  end
  subject.assert_trusted_bot_configured = function()
    return "fkst-test-bot"
  end
  subject.github = function()
    return github
  end
  subject.gh_exec = function(call, timeout)
    local result = call(timeout)
    if result.exit_code ~= 0 then
      error(result.stderr)
    end
    return result
  end
  subject.verify_issue_claim_before_write = function()
    return true
  end
  subject.with_github_debug_stamp = function(body)
    return body
  end
  subject.invalidate_entity_after_write = function() end
  subject.log_line = function() end
  return subject
end

local function run_delivery(mutate)
  local fact, source, escalation, pr = fixtures()
  local model = github_fake.model({
    issues = {
      [repo .. "#issue/42"] = source,
      [repo .. "#issue/900"] = escalation,
    },
  })
  model.prs = { [repo .. "#pr/7"] = pr }
  local github = github_fake.new(model)
  github.pr_cli_view = function(read_repo, read_pr_number)
    local current = model.prs[tostring(read_repo) .. "#pr/" .. tostring(read_pr_number)]
    return {
      stdout = pr_view_stdout(current),
      stderr = "",
      exit_code = 0,
    }
  end
  local creates = 0
  local target = {
    kind = "pr",
    number = pr_number,
    number_field = "pr_number",
    view_comments = function()
      return { stdout = "[]", stderr = "", exit_code = 0 }
    end,
    comment_create = function()
      creates = creates + 1
      return { stdout = '{"id":123,"body":"created","user":{"login":"fkst-test-bot"}}', stderr = "", exit_code = 0 }
    end,
    view_label = "test PR comments",
    comment_label = "test PR comment",
  }
  local request = request_for(fact, source, escalation, pr)
  if mutate ~= nil then
    mutate(model, request)
  end
  target.number = request.pr_number
  subject_for(github).write_comment_request(request, target)
  return creates
end

return {
  test_output_obligation_command_guard_allows_unchanged_authority = function()
    t.eq(run_delivery(nil), 1)
  end,

  test_output_obligation_command_guard_refuses_delayed_stale_head = function()
    local creates = run_delivery(function(model)
      model.prs[repo .. "#pr/7"].head_sha = "1234567890abcdef1234567890abcdef12345678"
    end)
    t.eq(creates, 0)
  end,

  test_output_obligation_command_guard_refuses_missing_guard = function()
    local creates = run_delivery(function(_, request)
      request.command_guard = nil
    end)
    t.eq(creates, 0)
  end,

  test_output_obligation_command_guard_refuses_target_drift = function()
    local creates = run_delivery(function(_, request)
      request.pr_number = 8
    end)
    t.eq(creates, 0)
  end,

  test_output_obligation_command_guard_refuses_command_body_drift = function()
    local creates = run_delivery(function(_, request)
      request.body = request.body:gsub("^fkst: rereview", "fkst: reintake")
    end)
    t.eq(creates, 0)
  end,
}
