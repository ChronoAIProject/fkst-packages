local M = {}

-- Built-in catalogs are authored in the SAME JSON shape a host provides an
-- external catalog under FKST_WORKFLOW_CATALOG_ROOT/*.json -- ONE writing style
-- for host and non-host. Embedded as JSON strings (not bundled files) because
-- core cannot locate its own package root at runtime (debug is forbidden, file
-- is runtime-relative). Each entry decodes LAZILY via json.decode in records();
-- decoded records flow through the SAME catalog.validate_records as file
-- catalogs -- no "trusted because ours" bypass.
--
-- The built-in COUNT is structural (known without decoding), so module load and
-- the engine graph_scan pure-primitives spec-eval context -- which has no json
-- -- never force a decode. json.decode happens only at real pipeline runtime.
local SOURCES = {
  {
    path = "builtin:software-dev-flow",
    json = [==[
{
  "schema": "fkst.workflow.v1",
  "id": "software-dev-flow",
  "version": "1",
  "summary": "Implement a software feature in bounded, result-driven code increments: scaffold, logic, then tests.",
  "applies_when": "The origin issue asks for an implementable software feature or support task that can be delivered as code.",
  "selector": {
    "title_contains_any": [
      "Add",
      "Build",
      "Implement",
      "feature",
      "support",
      "page"
    ]
  },
  "steps": [
    {
      "id": "scaffold",
      "title": "Implement the feature scaffold",
      "content": {
        "kind": "generated",
        "generator": "Implement the minimal scaffold/skeleton of the feature described in the origin issue: the files/module structure, interfaces, and a stub that renders or compiles, plus a smoke test. This is a concrete code task. Read the MERGED result of the previous step; for this first step, read the origin issue as that starting result."
      }
    },
    {
      "id": "implement",
      "title": "Implement the feature logic",
      "content": {
        "kind": "generated",
        "generator": "Implement the full feature logic on top of the scaffold. Read the MERGED result of the previous step, especially its PR diff, before writing this issue."
      }
    },
    {
      "id": "test",
      "title": "Implement behavior and edge-case tests",
      "content": {
        "kind": "generated",
        "generator": "Implement real tests covering the behavior and edge cases of the feature. Read the MERGED result of the previous step, especially its PR diff, before writing this issue."
      }
    }
  ]
}
]==],
  },
}

-- Structural count of built-in catalogs: no json.decode, safe at module load.
M.count = #SOURCES

-- Raw records (path + decoded blueprint), NOT validated here -- validation is
-- singular in catalog.validate_records over both built-in and file records.
function M.records()
  local out = {}
  for _, src in ipairs(SOURCES) do
    local ok, decoded = pcall(json.decode, src.json)
    if ok then
      out[#out + 1] = { path = src.path, blueprint = decoded }
    else
      out[#out + 1] = { path = src.path }
    end
  end
  return out
end

function M.install(target)
  target.default_catalog = M
end

return M
