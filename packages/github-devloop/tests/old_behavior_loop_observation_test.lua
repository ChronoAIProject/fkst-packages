local h = require("tests.devloop_helpers")

local t = h.t
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local SITE_PATH = "packages/github-devloop/departments/loop/main.lua"
local OBSERVATION_PREFIX = "writer:github-devloop:loop-thinking-blocked/"

return {
  test_loop_baseline_is_pinned_by_the_protected_observation_artifact = function()
    local inventory = json.decode(file.read(INVENTORY_PATH))
    local records = {}
    for _, record in ipairs(inventory.old_behavior_observations or {}) do
      local site = type(record) == "table" and record.site or nil
      if type(site) == "table"
        and site.path == SITE_PATH
        and type(record.observation_id) == "string"
        and record.observation_id:sub(1, #OBSERVATION_PREFIX) == OBSERVATION_PREFIX then
        records[#records + 1] = record
      end
    end

    t.eq(#records, 11, "complete protected loop baseline")
    for _, record in ipairs(records) do
      t.eq(record.schema, "restart-old-behavior-observation.v2")
      t.eq(record.owner, "github-devloop")
      t.eq(record.boundary, "writer")
      t.eq(type(record.old_inputs), "table")
      t.eq(type(record.old_outcome), "table")
    end
  end,
}
