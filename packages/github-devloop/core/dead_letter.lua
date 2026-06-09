local S = {}

function S.install(M)
local from_states_by_schema = {
  ["consensus.consensus_converge.v1"] = { "thinking" },
  ["consensus.consensus_reached.v1"] = { "thinking", "reviewing" },
  ["github-devloop.ready.v1"] = { "ready" },
  ["github-devloop.reviewing.v1"] = { "pr-open" },
  ["github-devloop.fixing.v1"] = { "fixing" },
  ["github-devloop.review-meta.v1"] = { "review-meta" },
  ["github-devloop.merge-ready.v1"] = { "merge-ready", "merging" },
}

local function find_original_payload(payload)
  if type(payload) ~= "table" then
    return {}
  end
  if type(payload.payload) == "table" then
    return payload.payload
  end
  if type(payload.event) == "table" and type(payload.event.payload) == "table" then
    return payload.event.payload
  end
  if type(payload.original) == "table" and type(payload.original.payload) == "table" then
    return payload.original.payload
  end
  if type(payload.original_event) == "table" and type(payload.original_event.payload) == "table" then
    return payload.original_event.payload
  end
  return payload
end

local function find_original_queue(payload, event)
  if type(payload) == "table" then
    if type(payload.event) == "table" and payload.event.queue ~= nil then
      return tostring(payload.event.queue)
    end
    if type(payload.original) == "table" and payload.original.queue ~= nil then
      return tostring(payload.original.queue)
    end
    if type(payload.original_event) == "table" and payload.original_event.queue ~= nil then
      return tostring(payload.original_event.queue)
    end
    if payload.queue ~= nil and tostring(payload.queue) ~= "github-devloop.dead_letter" then
      return tostring(payload.queue)
    end
    if payload.source_queue ~= nil then
      return tostring(payload.source_queue)
    end
  end
  return event and event.queue or "unknown"
end

local function payload_source_ref(original, wrapper)
  if type(original) == "table" and M._has_bounded_source_ref(original.source_ref) then
    return original.source_ref
  end
  if type(wrapper) == "table" and M._has_bounded_source_ref(wrapper.source_ref) then
    return wrapper.source_ref
  end
  return nil
end

local function payload_dedup_key(original, wrapper)
  if type(original) == "table" and M._is_bounded_string(original.dedup_key, M._max_dedup_len) then
    return original.dedup_key
  end
  if type(wrapper) == "table" and M._is_bounded_string(wrapper.dedup_key, M._max_dedup_len) then
    return wrapper.dedup_key
  end
  return "unknown"
end

local function proposal_from_payload(original)
  if type(original) ~= "table" then
    return nil
  end
  if M._is_bounded_string(original.proposal_id, M._max_key_len) then
    local repo, issue_number = M.parse_proposal_id(original.proposal_id)
    if repo ~= nil then
      return original.proposal_id, repo, issue_number
    end
  end
  if original.schema == "github-proxy.v1"
    and original.type == "issue"
    and original.repo ~= nil
    and original.number ~= nil
    and M.issue_ref_round_trips(original.repo, original.number) then
    return M.proposal_id(original.repo, original.number), tostring(original.repo), tostring(original.number)
  end
  return nil
end

local function review_issue_proposal(original)
  if type(original) ~= "table" or not M._is_bounded_string(original.proposal_id, M._max_key_len) then
    return nil
  end
  local _, _, version = M.parse_pr_review_proposal_id(original.proposal_id)
  if version == nil then
    return nil
  end
  local repo, pr_number = M.parse_pr_source_ref(original.source_ref)
  if repo == nil or pr_number == nil then
    return nil
  end
  return {
    repo = repo,
    pr_number = pr_number,
    version = version,
  }
end

local function pr_target_from_source_ref(original, wrapper)
  local source_ref = payload_source_ref(original, wrapper)
  local repo, pr_number = M.parse_pr_source_ref(source_ref)
  if repo == nil or pr_number == nil then
    return nil
  end
  return {
    repo = repo,
    pr_number = pr_number,
  }
end

function M.dead_letter_original_payload(payload)
  return find_original_payload(payload)
end

function M.dead_letter_marker(proposal_id, original_queue, dedup_key, state, version)
  if not M._is_bounded_string(proposal_id, M._max_key_len)
    or not M._is_bounded_string(dedup_key, M._max_dedup_len) then
    error("github-devloop: invalid dead-letter marker")
  end
  local safe_queue = M.sanitize_key(original_queue or "unknown", false):gsub("/", "-")
  if safe_queue == "" then
    safe_queue = "unknown"
  end
  return '<!-- fkst:github-devloop:dead-letter:v1 proposal="' .. tostring(proposal_id)
    .. '" queue="' .. tostring(safe_queue)
    .. '" dedup="' .. tostring(dedup_key)
    .. '" state="' .. tostring(state or "")
    .. '" version="' .. tostring(version or "")
    .. '" -->'
end

function M.has_dead_letter_marker(comments, proposal_id, dedup_key)
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:dead%-letter:v1.-%-%->"
  for _, comment in ipairs(M._trusted_marker_comments(comments)) do
    for marker in M._comment_body(comment):gmatch(marker_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id)
        and marker:match('dedup="([^"]*)"') == tostring(dedup_key) then
        return true
      end
    end
  end
  return false
end

function M.dead_letter_issue_view_cmd(repo, issue_number)
  return "gh issue view " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --json labels,comments"
end

function M.dead_letter_pr_view_cmd(repo, pr_number)
  return "gh pr view " .. M._shell_single_quote(pr_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --json comments"
end

function M.parse_dead_letter_entity_view(stdout)
  local decoded = json.decode(stdout or "{}")
  return {
    labels = {},
    comments = M.comments_from_json(decoded.comments),
  }
end

function M.build_dead_letter_comment_request(target, proposal_id, original_queue, original, state, source_ref)
  local dedup_key = payload_dedup_key(original, original)
  local target_source_ref = source_ref
  if not M._has_bounded_source_ref(target_source_ref) then
    if target.kind == "issue" then
      target_source_ref = M.issue_source_ref(target.repo, target.number)
    else
      target_source_ref = M.pr_source_ref(target.repo, target.number)
    end
  end
  local marker = M.dead_letter_marker(proposal_id, original_queue, dedup_key, state and state.state, state and state.version)
  local body = "github-devloop dead-letter parked"
    .. "\n\nOriginal queue: " .. tostring(original_queue or "unknown")
    .. "\nOriginal schema: " .. tostring(type(original) == "table" and original.schema or "unknown")
    .. "\nCurrent state: " .. tostring(state and state.state or "unmanaged")
    .. "\nCurrent version: " .. tostring(state and state.version or "")
    .. "\n\n" .. marker
  return M.build_entity_comment_request(target, body, M._dedup_key({
    "dead-letter",
    "comment",
    tostring(proposal_id),
    tostring(dedup_key),
  }), target_source_ref)
end

local function transition_for_dead_letter(original, state, issue_proposal_id)
  local schema = type(original) == "table" and original.schema or nil
  local from_states = from_states_by_schema[schema]
  if schema == "github-proxy.v1" and type(original) == "table" then
    if original.type == "issue" then
      from_states = { "implementing" }
    elseif original.type == "pr" then
      from_states = { "pr-open", "unmanaged" }
    end
  end
  if (schema == "consensus.consensus_reached.v1" or schema == "consensus.consensus_converge.v1")
    and type(original) == "table"
    and M.parse_pr_review_proposal_id(original.proposal_id) ~= nil then
    from_states = { "reviewing" }
  end
  if from_states == nil then
    return "unknown"
  end
  local proposal_id = issue_proposal_id or (type(original) == "table" and original.proposal_id)
  local incoming_version = payload_dedup_key(original, original)
  if schema == "github-devloop.reviewing.v1"
    or schema == "github-devloop.fixing.v1"
    or schema == "github-devloop.review-meta.v1"
    or schema == "github-devloop.merge-ready.v1" then
    incoming_version = original.version or incoming_version
  end
  if (schema == "consensus.consensus_reached.v1" or schema == "consensus.consensus_converge.v1")
    and issue_proposal_id ~= nil
    and type(original) == "table"
    and M.parse_pr_review_proposal_id(original.proposal_id) ~= nil then
    incoming_version = state and state.version or incoming_version
  end
  if proposal_id == nil then
    return "unknown"
  end
  return M.versioned_transition_status(state, from_states, "__dead_letter_park__", incoming_version)
end

local function should_park(original, state, issue_proposal_id)
  local transition = transition_for_dead_letter(original, state, issue_proposal_id)
  return transition == "apply" or transition == "pending" or transition == "unknown", transition
end

local function read_issue(repo, issue_number)
  local view = exec_sync({ cmd = M.dead_letter_issue_view_cmd(repo, issue_number), timeout = 30 })
  if view.exit_code ~= 0 then
    error("github-devloop: gh issue dead-letter view failed: " .. tostring(view.stderr))
  end
  return M.parse_dead_letter_entity_view(view.stdout)
end

local function read_pr(repo, pr_number)
  local view = exec_sync({ cmd = M.dead_letter_pr_view_cmd(repo, pr_number), timeout = 30 })
  if view.exit_code ~= 0 then
    error("github-devloop: gh PR dead-letter view failed: " .. tostring(view.stderr))
  end
  return M.parse_dead_letter_entity_view(view.stdout)
end

function M.handle_dead_letter(event)
  local wrapper = event and event.payload or {}
  local original = find_original_payload(wrapper)
  local original_queue = find_original_queue(wrapper, event)
  local dedup_key = payload_dedup_key(original, wrapper)
  local source_ref = payload_source_ref(original, wrapper)

  local proposal_id, repo, issue_number = proposal_from_payload(original)
  local pr_review = review_issue_proposal(original)
  local pr_target = pr_target_from_source_ref(original, wrapper)
  local lock_key = proposal_id and M.transition_lock_key(proposal_id)

  if pr_target ~= nil then
    lock_key = M.pr_transition_lock_key(pr_target.repo, pr_target.pr_number)
  elseif lock_key == nil and pr_review ~= nil then
    pr_target = pr_review
    lock_key = M.pr_transition_lock_key(pr_target.repo, pr_target.pr_number)
  end
  if lock_key == nil then
    M.log_line("info", "dead_letter", proposal_id or "unknown", "PARK", {
      "queue=" .. tostring(original_queue),
      "dedup_key=" .. tostring(dedup_key),
      "outcome=skip-foreign(no lock key)",
    })
    return
  end

  with_lock(lock_key, function()
    M.assert_trusted_bot_configured()
    local target = nil
    local current = nil
    local issue_proposal_id = proposal_id
    local comments = nil

    if pr_target ~= nil then
      local pr = read_pr(pr_target.repo, pr_target.pr_number)
      comments = pr.comments
      local origin = M.pr_origin_fact(comments)
      if origin == nil then
        M.log_line("info", "dead_letter", proposal_id or "unknown", "PARK", {
          "queue=" .. tostring(original_queue),
          "dedup_key=" .. tostring(dedup_key),
          "outcome=skip-foreign(no trusted PR origin)",
        })
        return
      end
      issue_proposal_id = origin.proposal_id
      current = M.current_state(comments, issue_proposal_id)
      target = {
        kind = "pr",
        repo = pr_target.repo,
        number = pr_target.pr_number,
      }
    elseif repo ~= nil then
      local issue = read_issue(repo, issue_number)
      comments = issue.comments
      current = M.current_state(comments, proposal_id)
      target = {
        kind = "issue",
        repo = repo,
        number = issue_number,
      }
    end

    if M.has_dead_letter_marker(comments, issue_proposal_id, dedup_key) then
      M.log_line("info", "dead_letter", issue_proposal_id, "PARK", {
        "queue=" .. tostring(original_queue),
        "dedup_key=" .. tostring(dedup_key),
        "outcome=skip-idempotent(already parked)",
      })
      return
    end

    local park, transition = should_park(original, current, issue_proposal_id)
    if not park then
      M.log_cas_decision("dead_letter", issue_proposal_id, current, "dead-letter", "park", "skip-stale(" .. tostring(transition) .. ")", "dead-letter event no longer matches current marker")
      return
    end

    local request = M.build_dead_letter_comment_request(target, issue_proposal_id, original_queue, original, current, source_ref)
    local queue = target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request"
    M.log_apply("dead_letter", issue_proposal_id, "dead-letter", dedup_key, { add = {}, remove = {} }, {
      queue,
    })
    M.log_raise("dead_letter", issue_proposal_id, queue, request)
  end)
end
end

return S
