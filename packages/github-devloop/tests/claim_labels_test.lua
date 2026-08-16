local config = require("devloop.config")
local h = require("tests.devloop_core_helpers")

local t = h.t
local loaded, claim_carriers_or_error = pcall(require, "devloop.claim_carriers")

local function claim_carriers()
  if not loaded then
    error("devloop.claim_carriers unavailable: " .. tostring(claim_carriers_or_error), 0)
  end
  return claim_carriers_or_error
end

local function env_value(value)
  return function(command)
    t.eq(command, 'printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"')
    return { stdout = value, stderr = "", exit_code = 0 }
  end
end

return {
  test_claim_label_derivation_is_fixed_width_and_canonical = function()
    local labels = claim_carriers()
    t.eq(labels.bare_label, "fkst-dev:claimed")
    local expected = "fkst-dev:claimed:d39deb1f090c9c42f9f67a4f4ca4ae30"
    t.eq(labels.derived_label("ElonSG"), expected)
    t.eq(labels.derived_label("ELONSG[bot]"), expected)

    local long_owner = "fkst-loning-s-chrono-macbook-pro-extra"
    t.eq(
      labels.derived_label(long_owner),
      "fkst-dev:claimed:ab1bac99f4ac1ae521f6635fd8055357"
    )
    t.eq(#labels.derived_label(long_owner), 49)
    t.eq(#labels.derived_label(string.rep("x", 1000)), 49)
  end,

  test_derived_claim_label_spec_binds_the_full_canonical_owner = function()
    local labels = claim_carriers()
    local spec = labels.active_label_spec(false, "ELONSG[bot]")
    t.eq(spec.name, "fkst-dev:claimed:d39deb1f090c9c42f9f67a4f4ca4ae30")
    t.eq(spec.description, "fkst-dev-label-mode-ownership-claim owner=elonsg")
    t.eq(spec.owner, "elonsg")
  end,

  test_derived_claim_label_binding_fails_closed_on_a_forced_collision = function()
    local labels = claim_carriers()
    local spec = labels.active_label_spec(false, "elonsg")
    labels.assert_owner_binding(nil, spec)
    labels.assert_owner_binding({
      name = spec.name,
      description = spec.description,
    }, spec)

    local ok, err = pcall(labels.assert_owner_binding, {
      name = spec.name,
      description = "fkst-dev-label-mode-ownership-claim owner=peer-bot",
    }, spec)
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(err))
  end,

  test_label_claim_contract_is_versioned_canonical_and_source_bound = function()
    local labels = claim_carriers()
    local source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    }
    local contract = labels.new_label_contract(false, "APP/ElonSG", source_ref)

    t.eq(contract.schema, "github-devloop.claim-label.v1")
    t.eq(contract.owner, "elonsg")
    t.eq(contract.label, labels.derived_label("elonsg"))
    t.eq(contract.source_ref.kind, "external")
    t.eq(contract.source_ref.ref, "owner/repo#issue/42")
    t.is_true(contract.source_ref ~= source_ref)
  end,

  test_label_claim_contract_validator_returns_narrow_rejection_reasons = function()
    local labels = claim_carriers()
    local source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    }
    local expected = {
      owner = "elonsg",
      exclusive = false,
      source_ref = source_ref,
    }
    local valid = labels.new_label_contract(false, "elonsg", source_ref)
    local normalized, reason = labels.validate_label_contract(valid, expected)
    t.eq(reason, nil)
    t.eq(normalized.owner, "elonsg")

    local cases = {
      {
        claim = { schema = "github-devloop.claim-label.v2" },
        reason = "claim-contract-version-unknown",
      },
      {
        claim = { schema = labels.label_contract_schema },
        reason = "claim-contract-owner-missing",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "APP/ElonSG",
          label = valid.label,
          source_ref = source_ref,
        },
        reason = "claim-contract-owner-noncanonical",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "peer-bot",
          label = labels.derived_label("peer-bot"),
          source_ref = source_ref,
        },
        reason = "claim-owner-mismatch",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "elonsg",
          label = labels.derived_label("peer-bot"),
          source_ref = source_ref,
        },
        reason = "claim-label-mismatch",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "elonsg",
          label = valid.label,
        },
        reason = "claim-contract-source-ref-missing",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "elonsg",
          label = valid.label,
          source_ref = { kind = "external", ref = "owner/repo#issue/43" },
        },
        reason = "source-ref-mismatch",
      },
    }
    for _, case in ipairs(cases) do
      local rejected, rejection_reason = labels.validate_label_contract(case.claim, expected)
      t.eq(rejected, nil)
      t.eq(rejection_reason, case.reason)
    end
  end,

  test_claim_label_family_requires_exact_colon_boundary_and_suffix = function()
    local labels = claim_carriers()
    t.eq(labels.is_claim_family("fkst-dev:claimed"), true)
    t.eq(labels.is_claim_family("fkst-dev:claimed:x"), true)
    t.eq(labels.is_claim_family("fkst-dev:claimedx"), false)
    t.eq(labels.is_claim_family("fkst-dev:claimed:"), false)
    t.eq(labels.is_claim_family(nil), false)
  end,

  test_claim_label_classifier_covers_derived_posture_and_foreign_wins = function()
    local labels = claim_carriers()
    local active = labels.derived_label("ElonSG")
    t.eq(labels.classify_labels({}, active), "unassigned")
    t.eq(labels.classify_labels({ active }, active), "self")
    t.eq(labels.classify_labels({ "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ active, "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ "fkst-dev:claimedx", "fkst-dev:enabled" }, active), "unassigned")
  end,

  test_claim_label_classifier_covers_exclusive_posture_and_foreign_wins = function()
    local labels = claim_carriers()
    local active = labels.active_label(true, "ElonSG")
    t.eq(active, "fkst-dev:claimed")
    t.eq(labels.classify_labels({}, active), "unassigned")
    t.eq(labels.classify_labels({ active }, active), "self")
    t.eq(labels.classify_labels({ "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ active, "fkst-dev:claimed:Peer" }, active), "other")
  end,

  test_claim_label_exclusive_config_is_trimmed_strict_opt_in = function()
    t.eq(config.claim_label_exclusive(env_value(" 1 \n")), true)
    t.eq(config.claim_label_exclusive(env_value("true")), false)
    t.eq(config.claim_label_exclusive(env_value("")), false)
  end,
}
