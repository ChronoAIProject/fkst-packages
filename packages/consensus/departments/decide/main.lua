local core = require("core")
local judged_repo = require("core.judged_repo")
local rebuttal = require("departments.decide.rebuttal")
local synthesis = require("departments.decide.synthesis")
local git_adapter = require("forge.git")
local saga = require("workflow.saga")

local aggregate = core.aggregate
local build_reached_payload = core.build_reached_payload
local judged_repo_worktree = core.judged_repo_worktree
local judgment_scratch_worktree = core.judgment_scratch_worktree
local parse_angle_output = core.parse_angle_output
local reached_cache_key = core.reached_cache_key

local spec = {
  consumes = { "proposal" },
  published_seam = { "proposal" },
  produces = { "consensus_reached", "consensus_converge" },
  stall_window = "2m",
}

local function read_runtime_root()
  local result = exec_sync({ cmd = core.read_runtime_root_cmd(), timeout = 30 })
  if result.exit_code ~= 0 then
    error("consensus: runtime-root-read-failed: FKST_RUNTIME_ROOT read failed: " .. tostring(result.stderr))
  end
  return result.stdout
end

local function prepare_judgment_worktree(path)
  local result = exec_sync({ cmd = core.judgment_mkdir_p_cmd(path), timeout = 30 })
  if result.exit_code ~= 0 then
    error("consensus: scratch-directory-setup-failed: judgment scratch directory setup failed: " .. tostring(result.stderr))
  end
  return path
end

local function git()
  return git_adapter.new(function(...)
    return exec_argv(...)
  end)
end

local function prepare_judged_repo_worktree(path, judged)
  if judged.repo_path ~= nil then
    local head = git().git_head_sha(judged.repo_path, 30)
    if head.exit_code ~= 0 then
      error("consensus: judged-repo-checkout-invalid: judged repo checkout head read failed: " .. tostring(head.stderr))
    end
    local actual = tostring(head.stdout or ""):gsub("%s+$", ""):lower()
    if judged.head_sha ~= nil and actual ~= judged.head_sha then
      error("consensus: judged-repo-head-mismatch: judged repo checkout is not pinned to head_sha")
    end
    return judged.repo_path
  end
  if judged.head_sha == nil then
    error("consensus: judged-repo-head-missing: judged repo head_sha is required")
  end
  local existing = git().git_head_sha(path, 30)
  if existing.exit_code == 0 then
    local actual = tostring(existing.stdout or ""):gsub("%s+$", ""):lower()
    if actual ~= judged.head_sha then
      error("consensus: judged-repo-head-mismatch: judged repo checkout is not pinned to head_sha")
    end
    return path
  end
  local mkdir = exec_sync({ cmd = core.judgment_mkdir_p_cmd(path:match("^(.*)/[^/]+$") or path), timeout = 30 })
  if mkdir.exit_code ~= 0 then
    error("consensus: judged-repo-parent-setup-failed: judged repo checkout parent setup failed: " .. tostring(mkdir.stderr))
  end
  local add = git().git_worktree_add_detached(path, judged.head_sha, 60)
  if add.exit_code ~= 0 then
    error("consensus: judged-repo-worktree-setup-failed: judged repo checkout setup failed: " .. tostring(add.stderr))
  end
  local head = git().git_head_sha(path, 30)
  if head.exit_code ~= 0 then
    error("consensus: judged-repo-checkout-invalid: judged repo checkout head read failed: " .. tostring(head.stderr))
  end
  local actual = tostring(head.stdout or ""):gsub("%s+$", ""):lower()
  if actual ~= judged.head_sha then
    error("consensus: judged-repo-head-mismatch: judged repo checkout is not pinned to head_sha")
  end
  return path
end

local function judgment_workspace(ctx, kind)
  local judged = ctx.judged_repo
  if judged ~= nil then
    if ctx.judged_worktree == nil then
      ctx.judged_worktree = prepare_judged_repo_worktree(
        judged_repo_worktree(ctx.runtime_root, judged, ctx.proposal.dedup_key),
        judged
      )
    end
    return ctx.judged_worktree
  end
  return prepare_judgment_worktree(
    judgment_scratch_worktree(ctx.runtime_root, kind, ctx.proposal.dedup_key)
  )
end

local function reached_provenance(ctx, provenance, ...)
  local output = provenance or {}
  if ctx.judged_worktree ~= nil and judged_repo.repo_consulted_from_outputs(ctx.judged_worktree, ...) then
    output.repo_consulted = true
  end
  return output
end

local function codex_opts(proposal, prompt, worktree, role)
  local opts = core.judgment_codex_opts(prompt, worktree)
  opts.role = role or "consensus"
  opts.proposal_id = proposal.proposal_id
  opts.dedup_key = proposal.dedup_key
  return opts
end

local function spawn_angle(ctx, angle)
  local proposal = ctx.proposal
  local prompt = core.build_angle_prompt(proposal, angle)
  local worktree = judgment_workspace(ctx, "angle-" .. tostring(angle))
  return spawn_codex(codex_opts(proposal, prompt, worktree, "consensus"))
end

local function raise_converge(proposal, angle_results, narrowed_question)
  raise(
    "consensus_converge",
    core.build_converge_payload(proposal, narrowed_question, angle_results)
  )
end

local function decide(proposal)
  local runtime_root = read_runtime_root()
  local ctx = {
    proposal = proposal,
    runtime_root = runtime_root,
    judged_repo = core.judged_repo(proposal),
  }

  local angle_results = {}
  local handles = {}
  local angles = core.angles(proposal)
  local verdict_mode = core.verdict_mode(proposal)
  for _, angle in ipairs(angles) do
    table.insert(handles, spawn_angle(ctx, angle))
  end

  local results = await_all(handles)
  for index, angle in ipairs(angles) do
    local parsed = nil
    local result = results[index]
    if type(result) == "table" and result.exit_code == 0 then
      parsed = parse_angle_output(result.stdout, verdict_mode)
    end
    table.insert(angle_results, {
      angle = angle,
      verdict = parsed and parsed.verdict or nil,
      reply = parsed and parsed.reply or nil,
      blocking_gap = parsed and parsed.blocking_gap or nil,
      stdout = type(result) == "table" and result.stdout or nil,
      exit_code = type(result) == "table" and result.exit_code or nil,
    })
  end

  local decision = aggregate(angle_results, verdict_mode)
  if decision ~= nil then
    return {
      queue = "consensus_reached",
      payload = build_reached_payload(proposal, decision, angle_results, nil, reached_provenance(ctx, nil, angle_results)),
      cache = true,
    }
  end

  local rebuttal_results = angle_results
  if rebuttal.can_run(angle_results) then
    local rebuttal_handles = rebuttal.spawn_all({
      proposal = proposal,
      angle_results = angle_results,
      runtime_root = runtime_root,
      prepare_judgment_worktree = function(path, kind)
        if ctx.judged_repo ~= nil then
          return judgment_workspace(ctx, kind or "rebuttal")
        end
        return prepare_judgment_worktree(path)
      end,
      codex_opts = codex_opts,
      build_rebuttal_prompt = function(target_proposal, own_result, peer_results)
        return core.build_rebuttal_prompt(target_proposal, own_result, peer_results)
      end,
      judgment_scratch_worktree = function(root, kind, identity)
        return judgment_scratch_worktree(root, kind, identity)
      end,
      spawn_codex = spawn_codex,
    })
    local rebuttal_outputs = await_all(rebuttal_handles)
    rebuttal_results = rebuttal.collect(angle_results, rebuttal_outputs, verdict_mode, {
      parse_angle_output = function(stdout, mode)
        return parse_angle_output(stdout, mode)
      end,
    })
    local rebuttal_reached = rebuttal.post_rebuttal_reached(proposal, angle_results, rebuttal_results, verdict_mode, {
      aggregate = function(items, mode)
        return aggregate(items, mode)
      end,
      build_reached_payload = function(target_proposal, decision, results, framing, provenance)
        return build_reached_payload(target_proposal, decision, results, framing, reached_provenance(ctx, provenance, angle_results, results))
      end,
    })
    if rebuttal_reached ~= nil then
      return rebuttal_reached
    end
  end

  local parsed = synthesis.parse_or_retry({
    verdict_mode = verdict_mode,
    p1_results = angle_results,
    p2_results = rebuttal_results,
    build_prompt = function(repair, prior_result)
      return core.build_synthesis_prompt(proposal, angle_results, rebuttal_results, {
        repair = repair,
        prior_result = prior_result,
      })
    end,
    spawn_sync = function(_kind, prompt)
      local repair = _kind == "synthesis-repair"
      local worktree = judgment_workspace(ctx, repair and "synthesis-repair" or "synthesis")
      return spawn_codex_sync(codex_opts(proposal, prompt, worktree, "consensus"))
    end,
  })
  return synthesis.to_decision_result(proposal, angle_results, rebuttal_results, parsed, {
    all_angles_succeeded = function(results)
      return core.all_angles_succeeded(results)
    end,
    build_reached_payload = function(target_proposal, decision, results, framing, provenance)
      return build_reached_payload(target_proposal, decision, results, framing, reached_provenance(ctx, provenance, angle_results, rebuttal_results, results))
    end,
  })
end

local function decision_done(event)
  local proposal = event.payload or {}
  if proposal.schema ~= "consensus.proposal.v1" then
    log.warn("consensus: unsupported proposal schema")
    return true
  end
  if not core.is_eligible(proposal) then
    return true
  end

  local cache_key = reached_cache_key(proposal.dedup_key)
  local already_reached = false
  with_lock(cache_key, function()
    already_reached = cache_get(cache_key) ~= nil
  end)
  return already_reached
end

local function act_decide(event)
  local proposal = event.payload or {}
  local cache_key = reached_cache_key(proposal.dedup_key)

  local ok, result = pcall(decide, proposal)
  if not ok then
    if core.is_stale_generation_context_error(result) then
      log.warn(
        "consensus dept=decide tag=STALE_GENERATION_CONTEXT"
          .. " proposal_id=" .. tostring(proposal.proposal_id)
          .. " dedup_key=" .. tostring(proposal.dedup_key)
          .. " error_class=" .. core.stale_generation_context_error_class()
      )
      return
    end
    error(result)
  end

  with_lock(cache_key, function()
    if cache_get(cache_key) then
      return
    end
    if result.queue == "consensus_reached" then
      raise("consensus_reached", result.payload)
      if result.cache then
        cache_set(cache_key, proposal.dedup_key)
      end
      return
    end
    if result.queue == "consensus_converge" then
      raise_converge(proposal, result.angle_results, result.narrowed_question)
      return
    end
    error("consensus: decision-result-invalid: unknown decision result")
  end)
end

return saga.department(spec, {
  done = decision_done,
  act = act_decide,
  wrap = core.wrap_pipeline_failure,
  name = "decide",
})
