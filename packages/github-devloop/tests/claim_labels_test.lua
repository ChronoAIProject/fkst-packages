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
