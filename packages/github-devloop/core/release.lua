local S = {}

function S.install(M)
local ai_sentinel = "⟦AI:FKST⟧"
local release_branch = "dev"
local max_release_notes_len = 6000

local function release_tag_number(tag)
  local n = tostring(tag or ""):match("^v0%.(%d+)%.0$")
  return n and tonumber(n) or nil
end

local function require_release_tag(tag)
  if release_tag_number(tag) == nil then
    error("github-devloop: invalid release tag")
  end
  return tostring(tag)
end

local function release_git_range(base_ref, head_sha)
  if not M._is_git_sha(head_sha) and tostring(head_sha) ~= "refs/remotes/origin/dev" then
    error("github-devloop: invalid release range head")
  end
  if tostring(base_ref or "") == "v0.0.0" then
    return tostring(head_sha)
  end
  return tostring(base_ref) .. ".." .. tostring(head_sha)
end

local function bounded_text(text, limit)
  local value = tostring(text or "")
  if #value > limit then
    return value:sub(1, limit)
  end
  return value
end

function M.release_source_ref(repo)
  return {
    kind = "external",
    ref = tostring(repo) .. "#repo",
  }
end

function M.release_proposal_id(repo, tag, head_sha)
  if not M._is_git_sha(head_sha) then
    error("github-devloop: invalid release head sha")
  end
  local tag_number = release_tag_number(tag)
  if tag_number == nil then
    error("github-devloop: invalid release tag")
  end
  local base = "v0." .. tostring(tag_number - 1) .. ".0"
  return "github-devloop/release/"
    .. M.safe_pr_review_repo_segment(repo)
    .. "/"
    .. base
    .. "/"
    .. require_release_tag(tag)
    .. "/"
    .. tostring(head_sha)
end

function M.parse_release_proposal_id(id)
  if type(id) ~= "string" then
    return nil
  end
  local rest = id:match("^github%-devloop/release/(.+)$")
  if rest == nil then
    return nil
  end
  local head_sha = rest:match("/([^/]+)$")
  local without_head = head_sha and rest:sub(1, #rest - #head_sha - 1) or nil
  local tag = without_head and without_head:match("/([^/]+)$") or nil
  local without_tag = tag and without_head:sub(1, #without_head - #tag - 1) or nil
  local base = without_tag and without_tag:match("/([^/]+)$") or nil
  local repo = base and without_tag:sub(1, #without_tag - #base - 1) or nil
  if repo == nil or repo == "" or tag == nil or head_sha == nil then
    return nil
  end
  if not M._is_path_safe_key(repo, 64) or release_tag_number(tag) == nil or release_tag_number(base) == nil or not M._is_git_sha(head_sha) then
    return nil
  end
  if release_tag_number(tag) ~= release_tag_number(base) + 1 then
    return nil
  end
  return repo, base, tag, head_sha
end

function M.release_dedup_key(repo, tag, head_sha)
  return M._dedup_key({
    "release",
    M.safe_repo(repo),
    require_release_tag(tag),
    tostring(head_sha),
  })
end

function M.next_release_tag(latest_tag)
  local n = release_tag_number(latest_tag or "v0.0.0")
  if n == nil then
    error("github-devloop: invalid latest release tag")
  end
  return "v0." .. tostring(n + 1) .. ".0"
end

function M.release_marker(repo, tag, head_sha, status, dedup_key)
  if status ~= "pending" and status ~= "published" then
    error("github-devloop: invalid release marker status")
  end
  if not M._is_git_sha(head_sha) or not M._is_bounded_string(dedup_key, M._max_dedup_len) then
    error("github-devloop: invalid release marker")
  end
  return '<!-- fkst:github-devloop:release:v1 repo="' .. tostring(M.safe_repo(repo))
    .. '" tag="' .. require_release_tag(tag)
    .. '" head_sha="' .. tostring(head_sha)
    .. '" status="' .. tostring(status)
    .. '" dedup="' .. tostring(dedup_key)
    .. '" -->'
end

function M.release_fact(comments, repo, tag, head_sha)
  if type(comments) ~= "table" then
    return nil
  end
  local marker_pattern = "<!%-%- fkst:github%-devloop:release:v1.-%-%->"
  local best = nil
  for _, comment in ipairs(M._trusted_marker_comments(comments)) do
    for marker in M._comment_body(comment):gmatch(marker_pattern) do
      local marker_repo = marker:match('repo="([^"]+)"')
      local marker_tag = marker:match('tag="([^"]+)"')
      local marker_head = marker:match('head_sha="([^"]+)"')
      local status = marker:match('status="([^"]+)"')
      local dedup = marker:match('dedup="([^"]*)"')
      if marker_repo == M.safe_repo(repo)
        and marker_tag == tostring(tag)
        and marker_head == tostring(head_sha)
        and (status == "pending" or status == "published")
        and M._is_bounded_string(dedup, M._max_dedup_len) then
        local fact = {
          repo = marker_repo,
          tag = marker_tag,
          head_sha = marker_head,
          status = status,
          dedup_key = dedup,
        }
        if status == "published" then
          return fact
        end
        best = best or fact
      end
    end
  end
  return best
end

function M.build_release_proposal(repo, tag, head_sha, base_ref)
  local proposal_id = M.release_proposal_id(repo, tag, head_sha)
  local range = release_git_range(base_ref, head_sha)
  return {
    schema = "consensus.proposal.v1",
    verdict_mode = "gate",
    proposal_id = proposal_id,
    title = "Release " .. tostring(tag),
    body = "Decide whether the current dev branch delta should ship as release " .. tostring(tag)
      .. ".\nRepository: " .. tostring(repo)
      .. "\nBranch: " .. release_branch
      .. "\nBase: " .. tostring(base_ref)
      .. "\nHead: " .. tostring(head_sha)
      .. "\nUse the source_ref and content_fetch commands to derive the current log and issue context.",
    content_fetch = "git log --oneline --decorate " .. M._shell_single_quote(range)
      .. "\n"
      .. "gh issue list --repo " .. M._shell_single_quote(repo)
      .. " --state closed --search " .. M._shell_single_quote("closed:" .. tostring(base_ref) .. ".." .. tostring(head_sha))
      .. " --json number,title,closedAt",
    dedup_key = M.release_dedup_key(repo, tag, head_sha),
    source_ref = M.release_source_ref(repo),
  }
end

function M.is_supported_release_result(payload)
  if type(payload) ~= "table"
    or payload.schema ~= "consensus.consensus_reached.v1"
    or payload.decision ~= "approve"
    or not M._is_bounded_string(payload.body, M._max_body_len)
    or not M._has_bounded_source_ref(payload.source_ref) then
    return false
  end
  local repo, base, tag, head_sha = M.parse_release_proposal_id(payload.proposal_id)
  if repo == nil then
    return false
  end
  local inner = tostring(payload.dedup_key or ""):match("^consensus:(.+)$") or tostring(payload.dedup_key or "")
  local source_repo = tostring(payload.source_ref.ref or ""):match("^(.-)#repo$")
  return source_repo ~= nil
    and M.safe_pr_review_repo_segment(source_repo) == repo
    and inner == M.release_dedup_key(source_repo, tag, head_sha)
    and base ~= nil
end

function M.release_notes_prompt(repo, tag, base_ref, head_sha)
  local range = release_git_range(base_ref, head_sha)
  return table.concat({
    "Draft GitHub Release notes for this repository release.",
    "Return only the release notes body.",
    "English is primary; include a short Chinese secondary section.",
    "Use concise bullets from the commit subjects and closed issue titles.",
    "Do not invent changes not present in the fetched data.",
    "End with " .. ai_sentinel .. ".",
    "",
    "Repository: " .. tostring(repo),
    "Release: " .. tostring(tag),
    "Range: " .. range,
    "",
    "Fetch current source data yourself:",
    "git log --oneline " .. M._shell_single_quote(range),
    "gh issue list --repo " .. M._shell_single_quote(repo)
      .. " --state closed --search " .. M._shell_single_quote("closed:" .. tostring(base_ref) .. ".." .. tostring(head_sha))
      .. " --json number,title,closedAt",
  }, "\n")
end

function M.normalize_release_notes(text, tag)
  local notes = bounded_text(text, max_release_notes_len):gsub("%s+$", "")
  if notes == "" then
    notes = "Release " .. tostring(tag) .. "\n\n## English\n- Automated release notes were unavailable.\n\n## Chinese\n- Automated release notes were unavailable."
  end
  if not notes:find(ai_sentinel, 1, true) then
    notes = notes .. "\n\n" .. ai_sentinel
  end
  return notes
end

function M.release_lock_key(repo)
  return M._dedup_key({ "release", "lock", M.safe_repo(repo) })
end

function M.git_latest_release_tag_cmd(branch)
  if branch ~= release_branch then
    error("github-devloop: releases only scan dev")
  end
  return "git describe --tags --match 'v*' --abbrev=0 refs/remotes/origin/" .. M._shell_single_quote(branch)
end

function M.git_release_delta_count_cmd(base_ref, head_sha)
  return "git rev-list --count " .. M._shell_single_quote(release_git_range(base_ref, head_sha))
end

function M.git_release_log_cmd(base_ref, head_sha)
  if not M._is_git_sha(head_sha) then
    error("github-devloop: invalid release log head")
  end
  return "git log --format=%s " .. M._shell_single_quote(release_git_range(base_ref, head_sha))
end

function M.git_tag_exists_cmd(tag)
  return "git rev-parse --verify --quiet refs/tags/" .. M._shell_single_quote(require_release_tag(tag))
end

function M.git_annotated_tag_cmd(tag, head_sha, message_file)
  if not M._is_git_sha(head_sha) then
    error("github-devloop: invalid release tag head")
  end
  return "git tag -a " .. M._shell_single_quote(require_release_tag(tag))
    .. " " .. M._shell_single_quote(head_sha)
    .. " -F " .. M._shell_single_quote(message_file)
end

function M.git_push_tag_cmd(tag)
  return "git push origin " .. M._shell_single_quote(require_release_tag(tag))
end

function M.gh_release_view_cmd(repo, tag)
  return "gh release view " .. M._shell_single_quote(require_release_tag(tag))
    .. " --repo " .. M._shell_single_quote(repo)
end

function M.gh_release_create_cmd(repo, tag, notes_file)
  return "gh release create " .. M._shell_single_quote(require_release_tag(tag))
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --target " .. M._shell_single_quote(tag)
    .. " --title " .. M._shell_single_quote(tag)
    .. " --notes-file " .. M._shell_single_quote(notes_file)
end

function M.gh_issue_list_release_markers_cmd(repo)
  return "gh issue list --repo " .. M._shell_single_quote(repo)
    .. " --state open"
    .. " --limit 100"
    .. " --json author,body,comments"
end

function M.parse_release_marker_issue_list(stdout)
  local decoded = json.decode(stdout or "[]")
  local comments = {}
  if type(decoded) ~= "table" then
    return comments
  end
  for _, issue in ipairs(decoded) do
    if type(issue) == "table" then
      if issue.body ~= nil then
        local author_login = nil
        if type(issue.author) == "table" and issue.author.login ~= nil then
          author_login = tostring(issue.author.login)
        elseif issue.author_login ~= nil then
          author_login = tostring(issue.author_login)
        end
        table.insert(comments, {
          body = tostring(issue.body),
          author_login = author_login,
          created_at = issue.createdAt or issue.created_at,
        })
      end
      for _, comment in ipairs(M.comments_from_json(issue.comments)) do
        table.insert(comments, comment)
      end
    end
  end
  return comments
end
end

return S
