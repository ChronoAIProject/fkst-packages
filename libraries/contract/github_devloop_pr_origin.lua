-- contract.github_devloop_pr_origin: canonical parser for trusted pr-origin:v1 facts.
local strings = require("contract.strings")

local O = {}

local max_impl_version_len = 512
local max_pr_number = 2147483647

local function strip_bot_login_suffix(login)
  if login == nil then
    return nil
  end
  return (tostring(login):lower():gsub("%[bot%]$", ""))
end

local function comment_author_login(comment, fallback_author_login)
  if type(comment) ~= "table" then
    return strip_bot_login_suffix(fallback_author_login)
  end
  if comment.author_login ~= nil then
    return strip_bot_login_suffix(comment.author_login)
  end
  if type(comment.author) == "table" and comment.author.login ~= nil then
    return strip_bot_login_suffix(comment.author.login)
  end
  if type(comment.user) == "table" and comment.user.login ~= nil then
    return strip_bot_login_suffix(comment.user.login)
  end
  return nil
end

local function comment_body(comment)
  if type(comment) == "table" then
    return tostring(comment.body or "")
  end
  return tostring(comment or "")
end

local function parse_issue_proposal_id(proposal_id)
  local rest = type(proposal_id) == "string"
    and proposal_id:match("^github%-devloop/issue/(.+)$")
    or nil
  if rest == nil then
    return nil, nil
  end
  local issue_number = rest:match("/([^/]+)$")
  local repo = issue_number and rest:sub(1, #rest - #issue_number - 1) or nil
  if repo == nil or repo == "" or issue_number == nil or issue_number == "" then
    return nil, nil
  end
  return repo, issue_number
end

local function parse_pr_proposal_id(proposal_id)
  local repo, number = tostring(proposal_id or ""):match("^github%-devloop/pr/(.+)/(%d+)$")
  local pr_number = tonumber(number)
  if repo == nil
    or pr_number == nil
    or pr_number < 1
    or pr_number % 1 ~= 0
    or pr_number > max_pr_number then
    return nil, nil
  end
  return repo, pr_number
end

function O.fact(comments, options)
  if type(comments) ~= "table" then
    return nil
  end
  local opts = options or {}
  local trusted_bot_login = strip_bot_login_suffix(opts.trusted_bot_login)
  local is_git_ref_safe = opts.is_git_ref_safe
  if type(is_git_ref_safe) ~= "function" then
    error("contract: git-ref-validator-required: is_git_ref_safe is required")
  end

  local marker_pattern = "<!%-%- fkst:github%-devloop:pr%-origin:v1.-%-%->"
  for _, comment in ipairs(comments) do
    if comment_author_login(comment, opts.fallback_author_login) == trusted_bot_login then
      for marker in comment_body(comment):gmatch(marker_pattern) do
        local marker_proposal = marker:match('proposal="([^"]+)"')
        local marker_issue = marker:match('issue="([^"]+)"')
        local marker_branch = marker:match('branch="([^"]+)"')
        local marker_impl_version = marker:match('impl_version="([^"]*)"')
        local marker_base_branch = marker:match('base_branch="([^"]+)"')
        local repo, issue_number = parse_issue_proposal_id(marker_proposal)
        if repo ~= nil
          and marker_issue == issue_number
          and is_git_ref_safe(marker_branch)
          and strings.is_bounded_string(marker_impl_version, max_impl_version_len)
          and is_git_ref_safe(marker_base_branch) then
          return {
            proposal_id = marker_proposal,
            repo = repo,
            issue_number = issue_number,
            branch = marker_branch,
            impl_version = marker_impl_version,
            base_branch = marker_base_branch,
          }
        end
        local pr_repo, pr_number = parse_pr_proposal_id(marker_proposal)
        if pr_repo ~= nil
          and marker_issue == tostring(pr_number)
          and is_git_ref_safe(marker_branch)
          and strings.is_bounded_string(marker_impl_version, max_impl_version_len)
          and is_git_ref_safe(marker_base_branch) then
          return {
            proposal_id = marker_proposal,
            repo = pr_repo,
            issue_number = nil,
            pr_number = pr_number,
            branch = marker_branch,
            impl_version = marker_impl_version,
            base_branch = marker_base_branch,
            pr_native = true,
          }
        end
      end
    end
  end
  return nil
end

return O
