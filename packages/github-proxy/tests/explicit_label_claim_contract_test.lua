local core = require("core")
local claim_carriers = require("devloop.claim_carriers")
local author_policy = require("testkit_internal.github_author_policy")
local t = fkst.test

local repo = "owner/x"
local issue_number = 42
local source_ref = {
  kind = "external",
  ref = repo .. "#issue/" .. tostring(issue_number),
}

local function explicit_payload(exclusive, owner)
  return {
    claim = claim_carriers.new_label_contract(
      { kind = exclusive == true and "exclusive" or "derived" },
      owner or "fkst-test-bot",
      32,
      source_ref
    ),
  }
end

local function mock_explicit_env(exclusive, times)
  local count = times or 16
  author_policy.mock_env(t, nil, { times = count })
  for _ = 1, count do
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive and "1" or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_SUFFIX"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command('printf %s "$FKST_GITHUB_CLAIM_MODE"', {
    stdout = "assignee",
    stderr = "",
    exit_code = 0,
  })
end

local function count_command_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function count_claim_mode_reads()
  return count_command_calls("FKST_GITHUB_CLAIM_MODE")
end

return {
  test_proxy_accepts_explicit_derived_contract_independently_of_claim_mode = function()
    mock_explicit_env(false)
    local payload = explicit_payload(false)
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    local issue = {
      assignees = { { login = "human" } },
      labels = { { name = spec.name, description = spec.description } },
    }

    local accepted, reason = core.verify_issue_claim_in_issue(
      issue,
      payload,
      repo,
      issue_number,
      "explicit_claim"
    )
    t.eq(accepted, true)
    t.eq(reason, nil)
    t.eq(count_claim_mode_reads(), 0)
  end,

  test_proxy_guarded_write_freshly_rereads_explicit_contract_claim = function()
    mock_explicit_env(false)
    local payload = explicit_payload(false)
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot", 32)
    t.mock_command("gh api repos/owner/x/issues/42", {
      stdout = '{"assignees":[{"login":"human"}],"labels":[{"name":"'
        .. spec.name .. '","description":"' .. spec.description .. '"}]}\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api repos/owner/x/issues/42", {
      stdout = '{"assignees":[{"login":"human"}],"labels":[]}\n',
      stderr = "",
      exit_code = 0,
    })

    local held, held_reason = core.verify_issue_claim_before_write(
      payload, repo, issue_number, "explicit_claim"
    )
    local lost, lost_reason = core.verify_issue_claim_before_write(
      payload, repo, issue_number, "explicit_claim"
    )

    t.eq(held, true)
    t.eq(held_reason, nil)
    t.eq(lost, false)
    t.eq(lost_reason, "ownership-claim-lost")
    t.eq(count_command_calls("gh api repos/owner/x/issues/42"), 2)
    t.eq(count_claim_mode_reads(), 0)
  end,

  test_proxy_accepts_explicit_exclusive_contract = function()
    mock_explicit_env(true)
    local payload = explicit_payload(true)
    local accepted, reason = core.verify_issue_claim_in_issue({
      assignees = { { login = "human" } },
      labels = { { name = claim_carriers.bare_label } },
    }, payload, repo, issue_number, "explicit_claim")

    t.eq(accepted, true)
    t.eq(reason, nil)
    t.eq(count_claim_mode_reads(), 0)
  end,

  test_proxy_rejects_malformed_explicit_contracts_with_typed_reasons = function()
    mock_explicit_env(false, 64)
    local valid = explicit_payload(false).claim
    local cases = {
      {
        claim = { schema = "github-devloop.claim-label.v2" },
        reason = "claim-contract-version-unknown",
      },
      {
        claim = { schema = claim_carriers.label_contract_schema },
        reason = "claim-contract-owner-missing",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = "APP/FKST-Test-Bot",
          label = valid.label,
          source_ref = source_ref,
        },
        reason = "claim-contract-owner-noncanonical",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = valid.owner,
          source_ref = source_ref,
        },
        reason = "claim-contract-label-missing",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = valid.owner,
          label = valid.label,
        },
        reason = "claim-contract-source-ref-missing",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = "peer-bot",
          label = claim_carriers.derived_label("peer-bot", 32),
          source_ref = source_ref,
        },
        reason = "claim-owner-mismatch",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = valid.owner,
          label = claim_carriers.derived_label("peer-bot", 32),
          source_ref = source_ref,
        },
        reason = "claim-label-mismatch",
      },
      {
        claim = {
          schema = claim_carriers.label_contract_schema,
          owner = valid.owner,
          label = valid.label,
          source_ref = { kind = "external", ref = repo .. "#issue/43" },
        },
        reason = "source-ref-mismatch",
      },
    }

    for _, case in ipairs(cases) do
      local accepted, reason = core.verify_issue_claim_in_issue(
        { assignees = {}, labels = {} },
        { claim = case.claim },
        repo,
        issue_number,
        "explicit_claim"
      )
      t.eq(accepted, false)
      t.eq(reason, case.reason)
    end
    t.eq(count_claim_mode_reads(), 0)
  end,

  test_proxy_explicit_contract_preserves_peer_and_foreign_label_exclusion = function()
    mock_explicit_env(false)
    local payload = explicit_payload(false)
    local own = payload.claim.label
    local peer = claim_carriers.derived_label("peer-bot", 32)

    local foreign_accepted, foreign_reason = core.verify_issue_claim_in_issue({
      assignees = {},
      labels = { { name = own }, { name = peer } },
    }, payload, repo, issue_number, "explicit_claim")
    local peer_accepted, peer_reason = core.verify_issue_claim_in_issue({
      assignees = { { login = "ElonSG" } },
      labels = { { name = own } },
    }, payload, repo, issue_number, "explicit_claim")

    t.eq(foreign_accepted, false)
    t.eq(foreign_reason, "ownership-claim-lost")
    t.eq(peer_accepted, false)
    t.eq(peer_reason, "ownership-claim-lost")
    t.eq(count_claim_mode_reads(), 0)
  end,

  test_proxy_explicit_contract_fails_closed_on_label_owner_collision = function()
    mock_explicit_env(false)
    local payload = explicit_payload(false)
    local ok, err = pcall(core.verify_issue_claim_in_issue, {
      assignees = { { login = "human" } },
      labels = {
        {
          name = payload.claim.label,
          description = "fkst-dev-label-mode-ownership-claim owner=peer-bot",
        },
      },
    }, payload, repo, issue_number, "explicit_claim")

    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(err))
    t.eq(count_claim_mode_reads(), 0)
  end,
}
