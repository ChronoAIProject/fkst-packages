local core = require("core")
local author_policy = require("testkit_internal.github_author_policy")
local t = fkst.test

local repo = "owner/x"
local issue_number = 42
local active_label = "fkst-dev:claimed:elonsg"
local foreign_label = "fkst-dev:claimed:peer-bot"

local function claim_payload(label, number)
  return {
    claim = {
      label = label,
      source_ref = {
        kind = "external",
        ref = repo .. "#issue/" .. tostring(number or issue_number),
      },
    },
  }
end

local function label_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, '{"name":"' .. tostring(label) .. '"}')
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function mock_labels(labels)
  author_policy.mock_env(t)
  t.mock_command("gh api repos/owner/x/issues/42", {
    stdout = '{"labels":' .. label_json(labels) .. "}\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_live_claim_verification_accepts_exact_active_label = function()
    mock_labels({ active_label })
    t.is_true(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_accepts_exact_active_label = function()
    local issue = { labels = { { name = active_label } } }
    t.is_true(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_refuses_missing_active_label = function()
    mock_labels({})
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_foreign_family_label = function()
    local issue = { labels = { { name = foreign_label } } }
    mock_labels({ foreign_label })
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_foreign_wins_when_active_and_foreign_labels_coexist = function()
    local labels = { active_label, foreign_label }
    local issue = { labels = { { name = active_label }, { name = foreign_label } } }
    mock_labels(labels)
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_source_ref_mismatch = function()
    t.eq(core.verify_issue_claim_in_issue(
      { labels = { { name = active_label } } },
      claim_payload(active_label, 99),
      repo,
      issue_number,
      "claim_test"
    ), false)
  end,

  test_claim_verification_refuses_present_claim_without_label = function()
    t.eq(core.verify_issue_claim_in_issue(
      { labels = { { name = active_label } } },
      {
        claim = {
          source_ref = {
            kind = "external",
            ref = repo .. "#issue/" .. tostring(issue_number),
          },
        },
      },
      repo,
      issue_number,
      "claim_test"
    ), false)
  end,
}
