local run_fake = require("std.testing").run_fake
local gh_fake = require("std.github_fake")

local function make_test_department(ports)
  local function pipeline(event)
    local issue = ports.github.read_issue(event.payload.source_ref)
    if issue.state == "OPEN" then
      raise("demo.request", { dedup_key = "d:" .. issue.number })
    end
  end
  return { spec = { consumes = { "demo" } }, pipeline = pipeline }
end

return {
  test_run_fake_captures_raises_and_reads = function()
    local model = gh_fake.model({
      issues = {
        ["owner/repo#issue/42"] = { number = 42, state = "OPEN" },
      },
    })
    local dept = make_test_department({ github = gh_fake.new(model), git = nil })
    local _result, effects = run_fake(dept, {
      payload = {
        source_ref = { kind = "external", ref = "owner/repo#issue/42" },
      },
    })
    assert(#effects.raises == 1, "must capture the S2 raise")
    assert(effects.raises[1].queue == "demo.request")
    assert(effects.raises[1].payload.dedup_key == "d:42")
  end,
}
