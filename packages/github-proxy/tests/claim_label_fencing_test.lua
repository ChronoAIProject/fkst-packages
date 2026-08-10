local core = require("core")
local claim_carriers = require("devloop.claim_carriers")
local author_policy = require("testkit_internal.github_author_policy")
local t = fkst.test

local repo = "owner/x"
local issue_number = 42
local active_spec = claim_carriers.active_label_spec(false, "fkst-test-bot")
local active_label = active_spec.name
local foreign_spec = claim_carriers.active_label_spec(false, "peer-bot")
local foreign_label = foreign_spec.name

local function claim_payload(label, number)
  return {
    claim = {
      owner = "fkst-test-bot",
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
    local name = type(label) == "table" and label.name or label
    local description = type(label) == "table" and label.description or ""
    table.insert(rendered, '{"name":"' .. tostring(name) .. '","description":"'
      .. tostring(description) .. '"}')
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function mock_identity(exclusive, times)
  author_policy.mock_env(t)
  for _ = 1, times or 4 do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_labels(labels, exclusive)
  mock_identity(exclusive)
  t.mock_command("gh api repos/owner/x/issues/42", {
    stdout = '{"labels":' .. label_json(labels) .. "}\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_live_claim_verification_accepts_exact_active_label = function()
    mock_labels({ active_spec })
    t.is_true(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"))
  end,

  test_in_memory_claim_verification_accepts_exact_active_label = function()
    mock_identity()
    local issue = { labels = { active_spec } }
    t.is_true(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"))
  end,

  test_live_claim_verification_refuses_missing_active_label = function()
    mock_labels({})
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_foreign_family_label = function()
    local issue = { labels = { foreign_spec } }
    mock_labels({ foreign_spec })
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_foreign_wins_when_active_and_foreign_labels_coexist = function()
    local labels = { active_spec, foreign_spec }
    local issue = { labels = labels }
    mock_labels(labels)
    t.eq(core.verify_issue_claim_before_write(
      claim_payload(active_label), repo, issue_number, "claim_test"), false)
    t.eq(core.verify_issue_claim_in_issue(
      issue, claim_payload(active_label), repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_refuses_source_ref_mismatch = function()
    mock_identity()
    t.eq(core.verify_issue_claim_in_issue(
      { labels = { active_spec } },
      claim_payload(active_label, 99),
      repo,
      issue_number,
      "claim_test"
    ), false)
  end,

  test_claim_verification_refuses_present_claim_without_label = function()
    mock_identity()
    t.eq(core.verify_issue_claim_in_issue(
      { labels = { active_spec } },
      {
        claim = {
          owner = "fkst-test-bot",
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

  test_claim_verification_refuses_owner_not_matching_authenticated_principal = function()
    mock_identity()
    local payload = claim_payload(active_label)
    payload.claim.owner = "peer-bot"
    t.eq(core.verify_issue_claim_in_issue(
      { labels = { active_spec } }, payload, repo, issue_number, "claim_test"), false)
  end,

  test_claim_verification_fails_closed_on_owner_binding_collision = function()
    mock_identity()
    local collision = {
      name = active_label,
      description = "fkst-dev-label-mode-ownership-claim owner=peer-bot",
    }
    local ok, err = pcall(
      core.verify_issue_claim_in_issue,
      { labels = { collision } },
      claim_payload(active_label),
      repo,
      issue_number,
      "claim_test"
    )
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(err))
  end,
}
