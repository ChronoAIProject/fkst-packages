local source_refs = require("contract.source_ref")
local strings = require("contract.strings")

local M = {}

local max_repo_length = 200
local max_url_length = 2048
local max_dedup_length = 200
local max_source_ref_length = 240
local max_viewport_dimension = 4096

local function positive_integer(value, maximum)
  local number = tonumber(value)
  return number ~= nil and number >= 1 and number <= maximum and number % 1 == 0
end

local function valid_repo(repo)
  return strings.is_bounded_string(repo, max_repo_length)
    and repo:find("^[%w_.-]+/[%w_.-]+$") ~= nil
end

local function valid_url(url)
  return strings.is_bounded_string(url, max_url_length)
    and url:find("^https?://") ~= nil
    and url:find("[%c%s]") == nil
end

local function copy_source_ref(value)
  return {
    kind = value.kind,
    ref = value.ref,
  }
end

local function copy_viewport(value)
  return {
    width = tonumber(value.width),
    height = tonumber(value.height),
  }
end

function M.validate_request(payload)
  if type(payload) ~= "table" or payload.schema ~= "browser-qa.request.v1" then
    error("browser-qa: invalid-request: unsupported schema", 0)
  end
  if not valid_repo(payload.repo) then
    error("browser-qa: invalid-request: invalid repo", 0)
  end
  if not positive_integer(payload.pr_number, 2147483647) then
    error("browser-qa: invalid-request: invalid pr_number", 0)
  end
  if not valid_url(payload.url) then
    error("browser-qa: invalid-request: invalid url", 0)
  end
  if type(payload.viewport) ~= "table"
    or not positive_integer(payload.viewport.width, max_viewport_dimension)
    or not positive_integer(payload.viewport.height, max_viewport_dimension) then
    error("browser-qa: invalid-request: invalid viewport", 0)
  end
  if not strings.is_path_safe_key(payload.dedup_key, max_dedup_length) then
    error("browser-qa: invalid-request: invalid dedup_key", 0)
  end
  if not source_refs.has_bounded_source_ref(payload.source_ref, max_source_ref_length)
    or payload.source_ref.kind ~= "external"
    or payload.source_ref.ref ~= tostring(payload.repo) .. "#pr/" .. tostring(payload.pr_number) then
    error("browser-qa: invalid-request: invalid PR source_ref", 0)
  end
  return {
    schema = payload.schema,
    repo = payload.repo,
    pr_number = tonumber(payload.pr_number),
    url = payload.url,
    viewport = copy_viewport(payload.viewport),
    dedup_key = payload.dedup_key,
    source_ref = copy_source_ref(payload.source_ref),
  }
end

local function nonnegative_integer(value)
  local number = tonumber(value)
  return number ~= nil and number >= 0 and number % 1 == 0
end

function M.validate_navigation(navigation)
  if type(navigation) ~= "table" or type(navigation.blank_render) ~= "boolean" then
    error("browser-qa: browser-adapter-invalid-result: missing blank_render", 0)
  end
  if not nonnegative_integer(navigation.console_error_count)
    or not nonnegative_integer(navigation.network_error_count) then
    error("browser-qa: browser-adapter-invalid-result: invalid error counts", 0)
  end
  if not source_refs.has_bounded_source_ref(navigation.screenshot_ref, max_source_ref_length) then
    error("browser-qa: browser-adapter-invalid-result: invalid screenshot_ref", 0)
  end
  return {
    blank_render = navigation.blank_render,
    console_error_count = tonumber(navigation.console_error_count),
    network_error_count = tonumber(navigation.network_error_count),
    screenshot_ref = copy_source_ref(navigation.screenshot_ref),
  }
end

local function artifact_label(source_ref)
  return tostring(source_ref.kind) .. ":" .. tostring(source_ref.ref)
end

function M.failed_result(request, navigation)
  return {
    schema = "browser-qa.result.v1",
    status = "failed",
    reason = "blank-render",
    repo = request.repo,
    pr_number = request.pr_number,
    url = request.url,
    viewport = copy_viewport(request.viewport),
    console_error_count = navigation.console_error_count,
    network_error_count = navigation.network_error_count,
    screenshot_ref = copy_source_ref(navigation.screenshot_ref),
    dedup_key = request.dedup_key .. "/result/blank-render",
    source_ref = copy_source_ref(request.source_ref),
  }
end

function M.comment_request(request, navigation)
  local body = table.concat({
    "Browser QA found a blank render.",
    "",
    "URL: " .. request.url,
    "Viewport: " .. tostring(request.viewport.width) .. "x" .. tostring(request.viewport.height),
    "Reason: blank-render",
    "Screenshot: " .. artifact_label(navigation.screenshot_ref),
  }, "\n")
  return {
    schema = "github-proxy.v1",
    repo = request.repo,
    pr_number = request.pr_number,
    body = body,
    dedup_key = request.dedup_key .. "/comment/blank-render",
    source_ref = copy_source_ref(request.source_ref),
  }
end

function M.adapter_error_message(err)
  if type(err) ~= "table" then
    return "browser-qa: browser-adapter-failed: " .. tostring(err)
  end
  return "browser-qa: " .. tostring(err.class or "browser-adapter-failed") .. ": " .. tostring(err.message or "navigate failed")
end

return M
