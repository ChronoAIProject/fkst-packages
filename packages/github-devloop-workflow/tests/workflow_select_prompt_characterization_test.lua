local devloop_prompts = require("devloop.prompts")
local workflow_select = require("workflow_select")
local core = require("core")
local t = fkst.test

local source_phrase = "Judge only from the issue data and offered workflow catalog entries provided in this prompt."

local expected_boundary = [[Execution boundary:
- You are running in a read-only checkout of the repository.
- Do not clone, checkout, fetch with git, create branches, or modify any repository.
- Judge only from the issue data and offered workflow catalog entries provided in this prompt.]]

local decision_paragraph = "Decide whether this GitHub issue matches exactly one offered workflow template. Choose a workflow only when the issue clearly fits that template's summary and applies_when text. If none fit, if more than one fit equally, or if the answer is uncertain, choose none."

local function count_literal(haystack, needle)
  local count = 0
  local offset = 1
  while true do
    local start_at = haystack:find(needle, offset, true)
    if start_at == nil then
      return count
    end
    count = count + 1
    offset = start_at + #needle
  end
end

return {
  test_workflow_select_prompt_pins_execution_boundary_and_placement = function()
    local prompt = workflow_select.build_workflow_select_prompt({
      candidate = {
        proposal_id = "github-devloop/issue/owner/repo/42",
      },
      current = {
        title = "Select a workflow",
        body = "Choose the matching workflow.",
        comments = {},
      },
    }, {
      {
        id = "workflow-one",
        blueprint = {
          summary = "A deterministic workflow fixture.",
          applies_when = "The issue requests this workflow.",
        },
      },
    })

    local expected_opening = "You are the github-devloop workflow selector."
      .. "\n\n" .. expected_boundary
      .. "\n\n" .. decision_paragraph

    t.is_true(type(prompt) == "string")
    t.eq(prompt:sub(1, #expected_opening), expected_opening)
    t.eq(count_literal(prompt, expected_boundary), 1)
  end,

  test_shared_execution_boundary_clause_matches_literal = function()
    t.eq(devloop_prompts.execution_boundary_clause(source_phrase), expected_boundary)
  end,

  test_workflow_intake_prompt_bytes = function()
    local prompt = core.build_intake_prompt("github-devloop/issue/owner/repo/42", {
      title = "Select a workflow",
      body = "Choose the matching workflow.",
      comments = {},
    })
    t.eq(require("contract.sha256").hex(prompt), "63c005d7a03be403c0e192819b35e79afe3c1f47a8135ad66a401ee484df4ad5")
  end,
}
