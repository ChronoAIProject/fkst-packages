local scan = require("scan_logic")
local core = require("core")
local t = fkst.test

local function one_finding_json()
  return '[{"file":"src/app.lua","line":12,"severity":"high",'
    .. '"title":"unbounded input reaches shell","remediation":"validate and quote the argument"}]'
end

return {
  test_parse_findings_accepts_a_dense_valid_array = function()
    local findings = scan.parse_findings(one_finding_json())
    t.eq(#findings, 1)
    t.eq(findings[1].file, "src/app.lua")
    t.eq(findings[1].line, 12)
    t.eq(findings[1].severity, "high")
    t.eq(findings[1].title, "unbounded input reaches shell")
    t.eq(findings[1].remediation, "validate and quote the argument")
  end,

  test_parse_findings_rejects_non_array_and_bad_shape = function()
    t.raises(function()
      scan.parse_findings('{"file":"x"}')
    end)
    t.raises(function()
      scan.parse_findings('[{"file":"x","line":0,"severity":"high","title":"a","remediation":"b"}]')
    end)
    t.raises(function()
      scan.parse_findings('[{"file":"x","line":1,"severity":"nope","title":"a","remediation":"b"}]')
    end)
  end,

  test_issue_create_request_maps_to_github_proxy_seam_with_both_labels = function()
    local finding = scan.parse_findings(one_finding_json())[1]
    local request = scan.issue_create_request("owner/repo", finding)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.repo, "owner/repo")
    t.is_true(request.title:find("src/app.lua:12", 1, true) ~= nil)
    t.is_true(request.body:find("unbounded input reaches shell", 1, true) ~= nil)
    t.eq(request.source_ref.kind, "repo-site")

    local labels = {}
    for _, label in ipairs(request.labels) do
      labels[label] = true
    end
    t.is_true(labels["fkst-company"])
    t.is_true(labels["fkst-security"])
  end,

  test_dedup_key_is_stable_for_the_same_finding = function()
    local finding = scan.parse_findings(one_finding_json())[1]
    t.eq(scan.dedup_key("owner/repo", finding), scan.dedup_key("owner/repo", finding))
  end,

  test_issue_create_request_rejects_invalid_repo_or_finding = function()
    local finding = scan.parse_findings(one_finding_json())[1]
    t.raises(function()
      scan.issue_create_request("", finding)
    end)
    t.raises(function()
      scan.issue_create_request("owner/repo", { file = "x" })
    end)
  end,

  test_conformance_errors_is_empty = function()
    t.eq(#core.conformance_errors(), 0)
  end,
}
