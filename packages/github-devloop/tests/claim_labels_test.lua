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
  test_claim_label_derivation_and_length_limit = function()
    local labels = claim_carriers()
    t.eq(labels.bare_label, "fkst-dev:claimed")
    t.eq(labels.derived_label("ElonSG"), "fkst-dev:claimed:ElonSG")
    t.eq(#labels.derived_label(string.rep("x", 33)), 50)

    local ok, err = pcall(labels.derived_label, string.rep("x", 34))
    t.eq(ok, false)
    t.is_true(tostring(err):find("claim-label-too-long", 1, true) ~= nil, tostring(err))
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
