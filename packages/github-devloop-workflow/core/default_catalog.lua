local blueprint = require("core.blueprint")

local M = {}

function M.records()
  return {
    {
      path = "builtin:software-dev-flow",
      blueprint = {
        schema = blueprint.SCHEMA,
        id = "software-dev-flow",
        version = "1",
        summary = "Implement a software feature in bounded, result-driven code increments: scaffold, logic, then tests.",
        applies_when = "The origin issue asks for an implementable software feature or support task that can be delivered as code.",
        selector = {
          title_contains_any = {
            "Add",
            "Build",
            "Implement",
            "feature",
            "support",
            "page",
          },
        },
        steps = {
          {
            id = "scaffold",
            title = "Implement the feature scaffold",
            content = {
              kind = "generated",
              generator = "Implement the minimal scaffold/skeleton of the feature described in the origin issue: the files/module structure, interfaces, and a stub that renders or compiles, plus a smoke test. This is a concrete code task. Read the MERGED result of the previous step; for this first step, read the origin issue as that starting result.",
            },
          },
          {
            id = "implement",
            title = "Implement the feature logic",
            content = {
              kind = "generated",
              generator = "Implement the full feature logic on top of the scaffold. Read the MERGED result of the previous step, especially its PR diff, before writing this issue.",
            },
          },
          {
            id = "test",
            title = "Implement behavior and edge-case tests",
            content = {
              kind = "generated",
              generator = "Implement real tests covering the behavior and edge cases of the feature. Read the MERGED result of the previous step, especially its PR diff, before writing this issue.",
            },
          },
        },
      },
    },
  }
end

function M.install(target)
  target.default_catalog = M
end

return M
