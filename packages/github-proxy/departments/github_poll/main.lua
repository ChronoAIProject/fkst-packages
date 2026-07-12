local core = require("core")
local devloop_base = require("devloop.base")
local github_env = require("core.env")
local m_claims = require("devloop.claims")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github_poll_tick" },
  produces = { "github_entity_changed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local entity_types = {
  { type = "issue", read = function(repo, timeout) return core.github().issue_list(repo, timeout) end },
  { type = "pr", read = function(repo, timeout) return core.github().pr_list(repo, timeout) end },
}

local function replay_sort_key(entity)
  return tostring(entity.updated_at or "")
    .. "/"
    .. string.format("%010d", tonumber(entity.number) or 0)
    .. "/"
    .. tostring(entity.type or "")
end

local intake_claim_label = m_claims.claimed_label()

local function has_configured_label_prefix(labels, prefixes, except_label)
  if #prefixes == 0 then
    return false
  end
  for _, label in ipairs(labels or {}) do
    local text = tostring(label)
    if text ~= except_label then
      for _, prefix in ipairs(prefixes) do
        if text:sub(1, #prefix) == prefix then
          return true
        end
      end
    end
  end
  return false
end

local function has_label(labels, expected)
  for _, label in ipairs(labels or {}) do
    if tostring(label) == expected then
      return true
    end
  end
  return false
end

local function poll_claim_owner()
  local ok, login = pcall(github_env.read_env, "FKST_GITHUB_BOT_LOGIN")
  if not ok or login == nil or tostring(login) == "" then
    return nil
  end
  return devloop_base.strip_bot_login_suffix(login)
end

local function is_self_assigned(logins, owner)
  return owner ~= nil
    and #logins == 1
    and devloop_base.strip_bot_login_suffix(logins[1]) == owner
end

local function is_intake_candidate_snapshot(entity_type, entity, poll_label_prefixes, owner)
  local logins = m_claims.assignee_logins(entity.assignees)
  return entity_type == "issue"
    and tostring(entity.state or ""):upper() == "OPEN"
    and not has_configured_label_prefix(entity.labels, poll_label_prefixes, intake_claim_label)
    and (
      #logins == 0
      or is_self_assigned(logins, owner)
      or has_label(entity.labels, intake_claim_label)
    )
end

local function collect_changed(repo, entity_type, entities, fresh_changes, replay_candidates, poll_label_prefixes, owner)
  for _, entity in ipairs(entities) do
    local key = core.entity_cache_key(repo, entity_type, entity.number)
    local cached_updated_at = cache_get(key)
    -- A self-held claim is an ownership lease, not durable intake progress.
    -- Admission re-derives trusted markers and current ownership on every replay.
    local level_replay = is_intake_candidate_snapshot(entity_type, entity, poll_label_prefixes, owner)
    if level_replay or cached_updated_at ~= entity.updated_at then
      local item = {
        entity_type = entity_type,
        entity = entity,
        key = key,
        level_replay = level_replay,
        replay = cached_updated_at == nil,
      }
      item.entity.type = entity_type
      if item.replay and not item.level_replay then
        table.insert(replay_candidates, item)
      else
        table.insert(fresh_changes, item)
      end
    end
  end
end

local function replay_allowance(replay_candidates, budget)
  table.sort(replay_candidates, function(left, right)
    return replay_sort_key(left.entity) < replay_sort_key(right.entity)
  end)
  local allowed = {}
  for index = 1, math.min(#replay_candidates, budget) do
    table.insert(allowed, replay_candidates[index])
  end
  return allowed
end

local function item_dedup_key(repo, item, poll_token)
  local entity = item.entity
  local dedup_key = core.entity_dedup_key(repo, item.entity_type, entity.number, entity.updated_at)
  if item.level_replay then
    return dedup_key .. "/poll/" .. tostring(poll_token or now())
  end
  return dedup_key
end

local function raise_changed_item(repo, item, poll_token)
  with_lock(item.key, function()
    local entity = item.entity
    if item.level_replay or cache_get(item.key) ~= entity.updated_at then
      local dedup_key = item_dedup_key(repo, item, poll_token)
      -- At-least-once: raise before cache_set. If this process crashes
      -- before the write, the next tick raises the same dedup_key again.
      raise("github_entity_changed", {
        schema = "github-proxy.v1",
        type = item.entity_type,
        repo = repo,
        number = entity.number,
        title = entity.title,
        url = entity.url,
        state = entity.state,
        labels = entity.labels,
        updated_at = entity.updated_at,
        dedup_key = dedup_key,
        source = "gh",
        -- Durable-delivery: stable pointer so a reliable consumer can
        -- re-derive the current entity (also required by the engine when
        -- this event is routed to a reliable subscription).
        source_ref = core.entity_source_ref(repo, item.entity_type, entity.number),
      })
      if not item.level_replay then
        cache_set(item.key, entity.updated_at)
      end
    end
  end)
end

local function raise_changed(repo, fresh_changes, replay_changes, poll_token)
  for _, item in ipairs(fresh_changes or {}) do
    raise_changed_item(repo, item, poll_token)
  end
  for _, item in ipairs(replay_changes or {}) do
    raise_changed_item(repo, item, poll_token)
  end
end

local function poll_entities(repo, event, fresh_changes, replay_candidates, poll_label_prefixes, owner)
  for _, entity_type in ipairs(entity_types) do
    local ok, result_or_err = core.gh_exec_result(function(timeout)
      return entity_type.read(repo, timeout)
    end, 30, "GitHub " .. entity_type.type .. " list")
    if not ok then
      core.log_error_fact("warn", "github_poll", "FAILURE", result_or_err.class, event and event.queue, result_or_err.message, {
        source_ref = event and event.source_ref,
        attempt = event and event.attempt,
        terminal = false,
      })
      if core.is_gh_rate_limit_error(result_or_err) then
        error(result_or_err.message)
      end
    else
      collect_changed(repo, entity_type.type, core.parse_entity_list(result_or_err.stdout, entity_type.type), fresh_changes, replay_candidates, poll_label_prefixes, owner)
    end
  end
end

local function act(event)
  local repo = core.read_env("FKST_GITHUB_REPO")
  if repo == nil then
    log.warn("github-proxy: FKST_GITHUB_REPO missing; skipping poll")
    return
  end

  local replay_budget = core.github_proxy_replay_budget()
  local poll_label_prefixes = core.github_proxy_poll_label_prefixes()
  local owner = poll_claim_owner()
  local fresh_changes = {}
  local replay_candidates = {}
  poll_entities(repo, event, fresh_changes, replay_candidates, poll_label_prefixes, owner)
  raise_changed(repo, fresh_changes, replay_allowance(replay_candidates, replay_budget), event and event.ts)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "github_poll",
})
