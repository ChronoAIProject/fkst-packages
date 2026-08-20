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

local function env_values(values)
  return function(command)
    for name, value in pairs(values or {}) do
      if command == 'printf %s "$' .. name .. '"' then
        return { stdout = value, stderr = "", exit_code = 0 }
      end
    end
    return { stdout = "", stderr = "", exit_code = 0 }
  end
end

return {
  test_claim_label_derivation_defaults_are_fixed_width_and_canonical = function()
    local labels = claim_carriers()
    t.eq(labels.bare_label, "fkst-dev:claimed")
    local expected = "fkst-dev:claimed:d39deb1f090c9c42f9f67a4f4ca4ae30"
    t.eq(labels.derived_label("ElonSG", 32), expected)
    t.eq(labels.derived_label("ELONSG[bot]", 32), expected)

    local long_owner = "fkst-loning-s-chrono-macbook-pro-extra"
    t.eq(
      labels.derived_label(long_owner, 32),
      "fkst-dev:claimed:ab1bac99f4ac1ae521f6635fd8055357"
    )
    t.eq(#labels.derived_label(long_owner, 32), 49)
    t.eq(#labels.derived_label(string.rep("x", 1000), 32), 49)
    t.eq(config.claim_label_owner_digest_hex_length(env_values()), 32)
    t.eq(config.claim_label_owner_digest_hex_length(env_values({
      FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH = "",
    })), 32)
  end,

  test_claim_label_owner_digest_width_accepts_trimmed_decimal_integer = function()
    t.eq(config.claim_label_owner_digest_hex_length(env_values({
      FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH = " \n8\t ",
    })), 8)
    t.eq(
      claim_carriers().derived_label("elonsg", 8),
      "fkst-dev:claimed:d39deb1f"
    )
  end,

  test_claim_label_owner_digest_width_rejects_invalid_values = function()
    for _, value in ipairs({ "0", "33", "1.5", "eight" }) do
      local ok, err = pcall(config.claim_label_owner_digest_hex_length, env_values({
        FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH = value,
      }))
      t.eq(ok, false)
      t.is_true(
        tostring(err):find("claim-label-owner-digest-hex-length-invalid", 1, true) ~= nil,
        tostring(err)
      )
    end
  end,

  test_derived_claim_label_spec_binds_the_full_canonical_owner = function()
    local labels = claim_carriers()
    local spec = labels.active_label_spec({ kind = "derived" }, "ELONSG[bot]", 32)
    t.eq(spec.name, "fkst-dev:claimed:d39deb1f090c9c42f9f67a4f4ca4ae30")
    t.eq(spec.description, "fkst-dev-label-mode-ownership-claim owner=elonsg")
    t.eq(spec.owner, "elonsg")
  end,

  test_declared_claim_label_suffix_is_appended_verbatim = function()
    local labels = claim_carriers()
    local spec = labels.active_label_spec({
      kind = "declared_suffix",
      suffix = "MacStudio-4",
    }, "MACSTUDIO-4[bot]")
    t.eq(spec.name, "fkst-dev:claimed:MacStudio-4")
    t.eq(spec.description, "fkst-dev-label-mode-ownership-claim owner=macstudio-4")
    t.eq(spec.owner, "macstudio-4")
  end,

  test_declared_claim_label_suffix_honors_complete_name_length_boundary = function()
    local labels = claim_carriers()
    local boundary = labels.active_label_spec({
      kind = "declared_suffix",
      suffix = string.rep("x", 33),
    }, "fkst-test-bot")
    t.eq(#boundary.name, 50)

    local ok, err = pcall(labels.active_label_spec, {
      kind = "declared_suffix",
      suffix = string.rep("x", 34),
    }, "fkst-test-bot")
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-name-invalid", 1, true) ~= nil, tostring(err))
  end,

  test_derived_claim_label_binding_fails_closed_on_a_forced_collision = function()
    local labels = claim_carriers()
    local spec = labels.active_label_spec({ kind = "derived" }, "elonsg", 32)
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

  test_short_derived_claim_label_binding_rejects_a_shared_name_for_another_owner = function()
    local labels = claim_carriers()
    local alpha = labels.active_label_spec({ kind = "derived" }, "alpha", 1)
    local test_bot = labels.active_label_spec({ kind = "derived" }, "fkst-test-bot", 1)
    t.eq(alpha.name, "fkst-dev:claimed:8")
    t.eq(test_bot.name, alpha.name)

    local ok, err = pcall(labels.assert_owner_binding, {
      name = alpha.name,
      description = alpha.description,
    }, test_bot)
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-owner-collision", 1, true) ~= nil, tostring(err))
  end,

  test_label_claim_contract_is_versioned_canonical_and_source_bound = function()
    local labels = claim_carriers()
    local source_ref = {
      kind = "external",
      ref = "owner/repo#issue/42",
    }
    local contract = labels.new_label_contract({ kind = "derived" }, "APP/ElonSG", 8, source_ref)

    t.eq(contract.schema, "github-devloop.claim-label.v1")
    t.eq(contract.owner, "elonsg")
    t.eq(contract.label, labels.derived_label("elonsg", 8))
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
      naming = { kind = "derived" },
      owner_digest_hex_length = 8,
      source_ref = source_ref,
    }
    local valid = labels.new_label_contract({ kind = "derived" }, "elonsg", 8, source_ref)
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
          label = labels.derived_label("peer-bot", 8),
          source_ref = source_ref,
        },
        reason = "claim-owner-mismatch",
      },
      {
        claim = {
          schema = labels.label_contract_schema,
          owner = "elonsg",
          label = labels.derived_label("peer-bot", 8),
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
    local active = labels.derived_label("ElonSG", 32)
    t.eq(labels.classify_labels({}, active), "unassigned")
    t.eq(labels.classify_labels({ active }, active), "self")
    t.eq(labels.classify_labels({ "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ active, "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ "fkst-dev:claimedx", "fkst-dev:enabled" }, active), "unassigned")
  end,

  test_claim_label_classifier_covers_exclusive_posture_and_foreign_wins = function()
    local labels = claim_carriers()
    local active = labels.active_label({ kind = "exclusive" }, "ElonSG")
    t.eq(active, "fkst-dev:claimed")
    t.eq(labels.classify_labels({}, active), "unassigned")
    t.eq(labels.classify_labels({ active }, active), "self")
    t.eq(labels.classify_labels({ "fkst-dev:claimed:Peer" }, active), "other")
    t.eq(labels.classify_labels({ active, "fkst-dev:claimed:Peer" }, active), "other")
  end,

  test_claim_label_naming_config_represents_each_posture = function()
    local derived = config.claim_label_naming(env_values())
    t.eq(derived.kind, "derived")

    local exclusive = config.claim_label_naming(env_values({
      FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE = " 1 \n",
    }))
    t.eq(exclusive.kind, "exclusive")

    local declared = config.claim_label_naming(env_values({
      FKST_GITHUB_CLAIM_LABEL_SUFFIX = "MacStudio-4",
    }))
    t.eq(declared.kind, "declared_suffix")
    t.eq(declared.suffix, "MacStudio-4")
  end,

  test_claim_label_naming_config_rejects_suffix_with_exclusive = function()
    local ok, err = pcall(config.claim_label_naming, env_values({
      FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE = "1",
      FKST_GITHUB_CLAIM_LABEL_SUFFIX = "macstudio-4",
    }))
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-naming-conflict", 1, true) ~= nil, tostring(err))
  end,
}
