local core = require("core")
local default_intake = require("devloop.intake.default_intake")
local parsers_misc = require("devloop.parsers.misc")

local M = {}

local function has_existing_blueprint(ctx)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(core, ctx.current and ctx.current.comments or {})) do
    if core.marker.parse_blueprint_marker(parsers_misc.comment_body(core, comment), ctx.candidate.proposal_id) ~= nil then
      return true
    end
  end
  return false
end

local function has_workflow_lineage_header(_ctx)
  -- TODO(2b-2b-ii/increment-3): detect the trusted child-of-workflow-step lineage marker once
  -- materialization owns writing it. Descendants remain ordinary default-intake issues here.
  return false
end

local function workflow_prefilter(ctx)
  if has_existing_blueprint(ctx) then
    return true
  end
  if has_workflow_lineage_header(ctx) then
    return false
  end
  return false
end

M.workflow_prefilter = workflow_prefilter

function M.handlers()
  return {
    done = function(_event) return false end,
    act = function(event)
      return default_intake.act(core, event, {
        dept = "workflow_select",
        before_codex = workflow_prefilter,
      })
    end,
    wrap = core.wrap_pipeline_failure,
    name = "workflow_select",
  }
end

return M
