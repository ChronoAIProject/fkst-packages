local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local base_ids = require("devloop.base_ids")
local strings = require("contract.strings")
local parsers_misc = require("devloop.parsers.misc")
local payloads_builders = require("devloop.payloads.builders")
local C = {}
local source_refs = require("contract.source_ref")
local forge_validators = require("devloop.forge_validators")

local max_decompose_issues = 3
local max_decompose_depth = 1

function C.is_supported_decompose(payload)
  if type(payload) ~= "table" then
    return false
  end
  local repo, issue_number = base_ids.parse_proposal_id(payload.proposal_id)
  local has_review_binding = payload.review_proposal_id ~= nil
    or payload.review_dedup_key ~= nil
    or payload.head_sha ~= nil
  local valid_review_binding = not has_review_binding
    or (strings.is_path_safe_key(payload.review_proposal_id, devloop_base._max_key_len)
      and strings.is_bounded_string(payload.review_dedup_key, devloop_base._max_dedup_len)
      and forge_validators.is_git_sha(payload.head_sha))
  local forward_dedup = base_ids.dedup_key({
    "decompose",
    tostring(payload.proposal_id),
    tostring(payload.version),
  })
  local replay_dedup = base_ids.dedup_key({
    "decompose",
    "replay",
    tostring(payload.proposal_id),
    tostring(payload.version),
    tostring(payload.pr_number),
    tostring(payload.expected_child_count or "unknown"),
    tostring(payload.completed_child_count or "unknown"),
  })
  local has_replay_counts = payload.expected_child_count ~= nil or payload.completed_child_count ~= nil
  local valid_replay_counts = not has_replay_counts
    or (tonumber(payload.expected_child_count) ~= nil
      and tonumber(payload.completed_child_count) ~= nil
      and tonumber(payload.expected_child_count) >= 1
      and tonumber(payload.expected_child_count) <= max_decompose_issues
      and tonumber(payload.completed_child_count) >= 0
      and tonumber(payload.completed_child_count) < tonumber(payload.expected_child_count)
      and tonumber(payload.expected_child_count) % 1 == 0
      and tonumber(payload.completed_child_count) % 1 == 0)
  return payload.schema == "github-devloop.decompose.v1"
    and repo ~= nil
    and issue_number ~= nil
    and strings.is_path_safe_key(payload.proposal_id, devloop_base._max_key_len)
    and forge_validators.is_positive_pr_number(payload.pr_number)
    and strings.is_bounded_string(payload.version, devloop_base._max_dedup_len)
    and valid_review_binding
    and tonumber(payload.round) ~= nil
    and tonumber(payload.round) == devloop_state.version_fix_round(payload.version)
    and strings.is_path_safe_key(payload.dedup_key, devloop_base._max_dedup_len)
    and valid_replay_counts
    and ((not has_replay_counts and tostring(payload.dedup_key) == forward_dedup)
      or (has_replay_counts and tostring(payload.dedup_key) == replay_dedup))
    and source_refs.has_bounded_source_ref(payload.source_ref, devloop_base._max_key_len)
end

function C.decomposed_marker(proposal_id, version, pr_number, count)
  local issue_count = tonumber(count)
  if issue_count == nil or issue_count < 1 or issue_count > max_decompose_issues or issue_count % 1 ~= 0 then
    error("github-devloop: decomposed-count-invalid: invalid decomposed count")
  end
  if not forge_validators.is_positive_pr_number(pr_number) then
    error("github-devloop: invalid-pr-number: invalid decomposed pr number")
  end
  return '<!-- fkst:github-devloop:decomposed:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" pr="' .. tostring(pr_number)
    .. '" count="' .. tostring(issue_count)
    .. '" -->'
end

function C.has_decomposed_marker(comments, proposal_id, version, pr_number)
  if type(comments) ~= "table" then
    return false
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:decomposed:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id)
        and marker:match('version="([^"]*)"') == tostring(version)
        and tostring(marker:match('pr="([^"]+)"')) == tostring(pr_number) then
        return true
      end
    end
  end
  return false
end

function C.decomposed_fact(comments, proposal_id, version, pr_number)
  if type(comments) ~= "table" then
    return nil, "absent"
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:decomposed:v1.-%-%->"
  local fact = nil
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      if marker:match('proposal="([^"]+)"') == tostring(proposal_id) then
        local marker_version = marker:match('version="([^"]*)"')
        local marker_pr_number = marker:match('pr="([^"]+)"')
        local count = tonumber(marker:match('count="([^"]+)"'))
        if (version == nil or marker_version == tostring(version))
          and (pr_number == nil or tostring(marker_pr_number) == tostring(pr_number))
          and forge_validators.is_positive_pr_number(marker_pr_number)
          and count ~= nil
          and count >= 1
          and count <= max_decompose_issues
          and count % 1 == 0 then
          local candidate = {
            proposal_id = tostring(proposal_id),
            version = marker_version,
            pr_number = tonumber(marker_pr_number),
            count = count,
            comment_created_at = parsers_misc._comment_created_at(comment),
          }
          if fact == nil then
            fact = candidate
          elseif candidate.version == fact.version
            and candidate.pr_number == fact.pr_number
            and candidate.count ~= fact.count then
            return nil, "conflict"
          end
        end
      end
    end
  end
  if fact ~= nil then
    return fact, "valid"
  end
  return nil, "absent"
end

function C.parse_decompose_child_issue_list(stdout, result_limit)
  local decoded = json.decode(stdout or "[]")
  local issues = {}
  local observation = {
    complete = false,
    row_count = 0,
  }
  if type(decoded) ~= "table" then
    return issues, observation
  end
  for _, issue in ipairs(decoded) do
    observation.row_count = observation.row_count + 1
    if type(issue) == "table" then
      local author_login = issue.author_login
      if author_login == nil and type(issue.author) == "table" then
        author_login = issue.author.login
      end
      table.insert(issues, {
        number = issue.number,
        title = issue.title,
        state = issue.state,
        body = tostring(issue.body or ""),
        author_login = author_login,
        url = issue.url,
      })
    end
  end
  local limit = tonumber(result_limit)
  observation.complete = limit ~= nil
    and limit >= 1
    and limit % 1 == 0
    and observation.row_count < limit
  return issues, observation
end

function C.decompose_child_issue_fact_indexes(issues, proposal_id, version, pr_number)
  local completed = {}
  local evidence = {
    occurrences = {},
    facts = {},
  }
  local child_pattern = "<!%-%- fkst:github%-devloop:decompose%-child:v1.-%-%->"
  for _, issue in ipairs(issues or {}) do
    local body = tostring(type(issue) == "table" and issue.body or "")
    local issue_number = type(issue) == "table" and tonumber(issue.number) or nil
    local trusted_child = type(issue) == "table"
      and parsers_misc.canonical_login(parsers_misc.comment_author_login(issue))
        == parsers_misc.canonical_login(parsers_misc.trusted_bot_login())
      and tostring(issue.state or ""):upper() == "OPEN"
    if trusted_child then
      for marker in body:gmatch(child_pattern) do
        if marker:match('parent="([^"]+)"') == tostring(proposal_id)
          and marker:match('version="([^"]*)"') == tostring(version)
          and tostring(marker:match('pr="([^"]+)"')) == tostring(pr_number) then
          local index = tonumber(marker:match('index="([^"]+)"'))
          if index ~= nil and index >= 1 and index <= max_decompose_issues and index % 1 == 0 then
            completed[index] = true
            evidence.occurrences[index] = (evidence.occurrences[index] or 0) + 1
            if forge_validators.is_positive_pr_number(issue_number) then
              table.insert(evidence.facts, {
                index = index,
                issue_number = issue_number,
              })
            end
          end
        end
      end
    end
  end
  table.sort(evidence.facts, function(left, right)
    if left.index ~= right.index then
      return left.index < right.index
    end
    return tonumber(left.issue_number or 0) < tonumber(right.issue_number or 0)
  end)
  return completed, evidence
end

function C.decompose_child_fact_indexes(comments, issues, proposal_id, version, pr_number, dedup_by_index)
  local completed = C.decompose_child_issue_fact_indexes(issues, proposal_id, version, pr_number)
  local created_pattern = "<!%-%- fkst:github%-proxy:issue%-created:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments or {})) do
    for marker in parsers_misc._comment_body(comment):gmatch(created_pattern) do
      local dedup = marker:match('dedup="([^"]+)"')
      for index = 1, max_decompose_issues do
        if type(dedup_by_index) == "table"
          and dedup_by_index[index] ~= nil
          and tostring(dedup) == tostring(dedup_by_index[index])
          and not completed[index] then
          completed[index] = true
        end
      end
    end
  end
  return completed
end

local function decompose_child_count(completed)
  local count = 0
  for _, present in pairs(completed or {}) do
    if present then
      count = count + 1
    end
  end
  return count
end

function C.decompose_children_complete(comments, issues, proposal_id, version, pr_number, expected_count)
  local count = tonumber(expected_count)
  if count == nil or count < 1 or count > max_decompose_issues or count % 1 ~= 0 then
    return true, 0, {
      exact = false,
      expected_count = count,
      matched_count = 0,
      facts = {},
    }
  end
  local completed, evidence = C.decompose_child_issue_fact_indexes(
    issues,
    proposal_id,
    version,
    pr_number
  )
  local completed_count = decompose_child_count(completed)
  local exact = completed_count == count and #evidence.facts == count
  local issue_numbers = {}
  for _, fact in ipairs(evidence.facts) do
    if issue_numbers[fact.issue_number] then
      exact = false
    end
    issue_numbers[fact.issue_number] = true
  end
  for index = 1, count do
    if evidence.occurrences[index] ~= 1 then
      exact = false
    end
  end
  return completed_count >= count, completed_count, {
    exact = exact,
    expected_count = count,
    matched_count = #evidence.facts,
    facts = evidence.facts,
  }
end

function C.build_decompose_replay_payload(restart_policy, fact, comments_or_feedback, source_ref, completed_count)
  local feedback = comments_or_feedback
  if type(feedback) == "table" and feedback[1] ~= nil then
    feedback = restart_policy.fixing_replay_feedback_fact(comments_or_feedback, fact.proposal_id, fact.version)
  end
  local payload = payloads_builders.build_devloop_decompose_payload({
    proposal_id = fact.proposal_id,
    pr_number = fact.pr_number,
    issue_version = fact.version,
    review_proposal_id = feedback and feedback.review_proposal_id or nil,
    review_dedup_key = feedback and feedback.review_dedup_key or nil,
    head_sha = feedback and feedback.reviewed_head_sha or nil,
    round = restart_policy.version_fix_round(fact.version),
    source_ref = source_ref,
  })
  payload.expected_child_count = fact.count
  payload.completed_child_count = tonumber(completed_count) or 0
  payload.dedup_key = base_ids.dedup_key({
    "decompose",
    "replay",
    tostring(fact.proposal_id),
    tostring(fact.version),
    tostring(fact.pr_number),
    tostring(payload.expected_child_count),
    tostring(payload.completed_child_count),
  })
  return payload
end

function C.decompose_child_marker(proposal_id, version, pr_number, index)
  return '<!-- fkst:github-devloop:decompose-child:v1 parent="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" pr="' .. tostring(pr_number)
    .. '" index="' .. tostring(index)
    .. '" -->'
end

local function normalized_decompose_lineage_depth(value)
  local n = tonumber(value)
  if n == nil or n < 0 or n >= math.huge or n % 1 ~= 0 then
    return nil
  end
  return n
end

function C.decompose_lineage_marker(root_proposal_id, depth)
  local n = normalized_decompose_lineage_depth(depth)
  if n == nil then
    error("github-devloop: decompose-lineage-depth-invalid: invalid decompose lineage depth")
  end
  return '<!-- fkst:github-devloop:decompose-lineage:v1 root="' .. tostring(root_proposal_id)
    .. '" depth="' .. tostring(n)
    .. '" -->'
end

local decompose_lineage_marker_pattern = "<!%-%- fkst:github%-devloop:decompose%-lineage:v1.-%-%->"
local workflow_lineage_marker_pattern = "<!%-%- fkst:github%-devloop%-workflow:lineage:v1.-%-%->"

local function decompose_lineage_fact(marker)
  local root = marker:match('root="([^"]+)"')
  local depth = normalized_decompose_lineage_depth(marker:match('depth="(%d+)"'))
  if root == nil or depth == nil then
    return nil
  end
  return {
    root = root,
    depth = depth,
  }
end

function C.decompose_lineage(body)
  local text = tostring(body or "")
  local _, marker_end, marker = text:find("^%s*(" .. decompose_lineage_marker_pattern .. ")")
  if marker ~= nil and text:sub(marker_end + 1):find("^%s*" .. workflow_lineage_marker_pattern) ~= nil then
    return decompose_lineage_fact(marker)
  end
  if text:find("^%s*" .. workflow_lineage_marker_pattern) ~= nil then
    return nil
  end

  local best = nil
  for lineage_marker in text:gmatch(decompose_lineage_marker_pattern) do
    local fact = decompose_lineage_fact(lineage_marker)
    if fact ~= nil and (best == nil
      or fact.depth > best.depth
      or (fact.depth == best.depth and fact.root < best.root)) then
      best = fact
    end
  end
  return best
end

function C.strip_decompose_lineage_header(body)
  local text = tostring(body or "")
  local _, marker_end, marker = text:find("^%s*(" .. decompose_lineage_marker_pattern .. ")")
  if marker == nil or decompose_lineage_fact(marker) == nil then
    return text
  end
  return (text:sub(marker_end + 1):gsub("^%s+", ""):gsub("%s+$", ""))
end

function C.decompose_lineage_depth(body)
  local lineage = C.decompose_lineage(body)
  return lineage and lineage.depth or 0
end

function C.max_decompose_issues()
  return max_decompose_issues
end

function C.max_decompose_depth()
  return max_decompose_depth
end

return C
