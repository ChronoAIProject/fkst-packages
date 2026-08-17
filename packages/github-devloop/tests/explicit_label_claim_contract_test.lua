local claim_carriers = require("devloop.claim_carriers")
local m_claims = require("devloop.claims")
local h = require("tests.devloop_core_helpers")
local t = h.t
local gh_argv = require("testkit_internal.gh_argv_mock")
<<<<<<< HEAD
local entity_lib = require("devloop.entity")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
=======
local github_shell = require("forge.github.shell")
>>>>>>> 8d37ecdfd200fc58580e86343e18cee34a0c292d

local repo = "owner/repo"
local issue_number = 42
local source_ref = {
  kind = "external",
  ref = repo .. "#issue/" .. tostring(issue_number),
}

local function mock_env(name, value, times)
  for _ = 1, times or 1 do
    t.mock_command('printf %s "$' .. name .. '"', {
      stdout = value or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_contract_env(exclusive, write_mode, managed)
  mock_env("FKST_GITHUB_BOT_LOGIN", "APP/FKST-Test-Bot", 64)
  mock_env("FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE", exclusive, 64)
  mock_env("FKST_GITHUB_CLAIM_LABEL_SUFFIX", "", 64)
  mock_env("FKST_DEVLOOP_MANAGED_BOT_LOGINS", managed, 64)
  mock_env("FKST_GITHUB_WRITE", write_mode, 64)
  mock_env("FKST_GITHUB_CLAIM_MODE", "assignee", 1)
end

local function count_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = gh_argv.call_rendered(call)
    if rendered:find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function ownership_json(assignees, labels)
  local rendered_assignees = {}
  for _, login in ipairs(assignees or {}) do
    table.insert(rendered_assignees, string.format('{"login":"%s"}', tostring(login)))
  end
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, string.format('{"name":"%s"}', tostring(label)))
  end
  return '{"assignees":[' .. table.concat(rendered_assignees, ",")
    .. '],"author":{"login":"fkst-test-bot"},"labels":['
    .. table.concat(rendered_labels, ",") .. "]}\n"
end

local function mock_binding(spec, description, times)
  for _ = 1, times or 1 do
    t.mock_command("gh api --method GET 'repos/owner/repo/labels/" .. github_shell.url_encode(spec.name) .. "'", {
      stdout = '{"name":"' .. spec.name .. '","description":"'
        .. tostring(description or spec.description) .. '"}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

return {
  test_real_issue_request_builders_emit_explicit_contract_without_claim_mode = function()
    mock_contract_env("", "", "")
    local proposal = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = "explicit-request-builders",
    }
    local issue = {
      repo = repo,
      number = issue_number,
      source_ref = source_ref,
    }
    local requests = {
      entity_lib.build_entity_comment_request(
        { kind = "issue", repo = repo, number = issue_number },
        "body",
        "explicit-request-builders/entity",
        source_ref
      ),
      requests_labels.build_label_request(
        repo,
        issue_number,
        { "fkst-dev:enabled" },
        {},
        "explicit-request-builders/label",
        source_ref
      ),
      requests_lifecycle.build_observe_comment_request("en", issue, proposal),
    }

    for _, request in ipairs(requests) do
      t.eq(request.claim.schema, claim_carriers.label_contract_schema)
      t.eq(request.claim.owner, "fkst-test-bot")
      t.eq(request.claim.source_ref.ref, source_ref.ref)
    end
    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
  end,

  test_explicit_contract_drives_complete_label_lifecycle_without_claim_mode = function()
    mock_contract_env("", "1", "peer-bot")
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    mock_binding(spec, nil, 8)
    t.mock_command("gh issue edit 42 --repo owner/repo --add-label '" .. spec.name .. "'", {
      stdout = "", stderr = "", exit_code = 0,
    })
    t.mock_command("gh issue view 42 --repo owner/repo --json assignees,author,labels", {
      stdout = ownership_json({}, { spec.name }), stderr = "", exit_code = 0,
    })
    t.mock_command("gh issue view 42 --repo owner/repo --json assignees,author,labels", {
      stdout = ownership_json({}, { spec.name }), stderr = "", exit_code = 0,
    })
    t.mock_command("gh issue view 42 --repo owner/repo --json assignees,author,labels", {
      stdout = ownership_json({}, { spec.name }), stderr = "", exit_code = 0,
    })
    t.mock_command("gh issue edit 42 --repo owner/repo --remove-label '" .. spec.name .. "'", {
      stdout = "", stderr = "", exit_code = 0,
    })

    local contract = m_claims.new_label_claim_contract(source_ref)
    local current = {
      assignees = {},
      labels = {},
      author_login = "fkst-test-bot",
      comments = {},
    }
    local inputs = m_claims.claim_admission_inputs(current, repo, nil, contract)
    local admission, detail = m_claims.claim_admission_precheck(current, inputs)
    t.eq(admission, "needs-claim")
    t.eq(m_claims.claim_issue_for_management(
      "explicit_claim",
      repo,
      issue_number,
      current,
      "github-devloop/issue/owner/repo/42",
      admission,
      detail,
      contract
    ), true)

    t.eq(m_claims.issue_claim_state({}, contract.owner, { contract.label }, contract), "self")
    t.eq(m_claims.verify_issue_claim(repo, issue_number, contract.owner, contract), true)
    local payload = m_claims.attach_issue_claim({}, source_ref, contract)
    t.eq(payload.claim.schema, claim_carriers.label_contract_schema)
    t.eq(payload.claim.owner, "fkst-test-bot")
    t.eq(payload.claim.label, spec.name)
    t.eq(m_claims.release_issue_claim_if_self(
      h.core,
      "explicit_claim",
      repo,
      issue_number,
      "github-devloop/issue/owner/repo/42",
      "explicit-contract-release",
      contract
    ), true)

    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
    t.eq(count_calls("--add-assignee"), 0)
    t.eq(count_calls("--remove-assignee"), 0)
    t.eq(count_calls("--add-label " .. spec.name), 1)
    t.eq(count_calls("--remove-label " .. spec.name), 1)
  end,

  test_explicit_contract_preserves_exclusive_and_foreign_wins_postures = function()
    mock_contract_env("1", "", "peer-bot")
    local contract = m_claims.new_label_claim_contract(source_ref)
    t.eq(contract.label, claim_carriers.bare_label)
    t.eq(m_claims.issue_claim_state({}, contract.owner, { contract.label }, contract), "self")
    t.eq(m_claims.issue_claim_state({}, contract.owner, {
      contract.label,
      claim_carriers.derived_label("peer-bot"),
    }, contract), "other")
    t.eq(m_claims.issue_claim_state({ { login = "peer-bot" } }, contract.owner, {
      contract.label,
    }, contract), "other")
    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
  end,

  test_explicit_contract_source_mismatch_fails_before_held_acquisition_returns = function()
    mock_contract_env("", "", "")
    local contract = m_claims.new_label_claim_contract(source_ref)
    local ok, err = pcall(
      m_claims.claim_issue_for_management,
      "explicit_claim",
      repo,
      issue_number + 1,
      { assignees = {}, labels = { contract.label } },
      "github-devloop/issue/owner/repo/43",
      "held",
      { claim_contract = contract },
      contract
    )

    t.eq(ok, false)
    t.is_true(tostring(err):find("source-ref-mismatch", 1, true) ~= nil, tostring(err))
    t.eq(count_calls("--add-label"), 0)
    t.eq(count_calls("--add-assignee"), 0)
    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
  end,

  test_explicit_contract_fails_closed_on_label_owner_collision_before_add = function()
    mock_contract_env("", "1", "")
    local spec = claim_carriers.active_label_spec({ kind = "derived" }, "fkst-test-bot")
    mock_binding(spec, "fkst-dev-label-mode-ownership-claim owner=peer-bot")
    local contract = m_claims.new_label_claim_contract(source_ref)
    local current = {
      assignees = {}, labels = {}, author_login = "fkst-test-bot", comments = {},
    }
    local admission, detail = m_claims.claim_admission_precheck(
      current,
      m_claims.claim_admission_inputs(current, repo, nil, contract)
    )

    local ok, err = pcall(
      m_claims.claim_issue_for_management,
      "explicit_claim",
      repo,
      issue_number,
      current,
      "github-devloop/issue/owner/repo/42",
      admission,
      detail,
      contract
    )
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(err))
    t.eq(count_calls("--add-label"), 0)
    t.eq(count_calls('printf %s "$FKST_GITHUB_CLAIM_MODE"'), 0)
  end,
}
