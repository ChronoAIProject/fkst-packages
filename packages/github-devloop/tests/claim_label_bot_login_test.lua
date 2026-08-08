local devloop_base = require("devloop.base")
local m_claims = require("devloop.claims")
local parsers_misc = require("devloop.parsers.misc")
local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

local bare_label = "fkst-dev:claimed"
local derived_label = "fkst-dev:claimed:fkst-test-bot"
local peer_label = "fkst-dev:claimed:peer-bot"

local function mock_identity(login, exclusive, reads)
  for _ = 1, reads or 8 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = login or "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE"', {
      stdout = exclusive or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

return {
  test_strip_bot_login_suffix_is_nil_safe_and_no_op_for_users = function()
    t.eq(devloop_base.strip_bot_login_suffix("octocat"), "octocat")
    t.eq(devloop_base.strip_bot_login_suffix("chronoai-bot[bot]"), "chronoai-bot")
    t.eq(devloop_base.strip_bot_login_suffix(nil), nil)
    t.eq(devloop_base.strip_bot_login_suffix("user[bot]name"), "user[bot]name")
  end,

  test_configure_trusted_bot_login_normalizes_bracket_bot_suffix = function()
    t.eq(devloop_base.configure_trusted_bot_login("chronoai-bot[bot]"), "chronoai-bot")
    t.eq(devloop_base.trusted_bot_login(), "chronoai-bot")
    t.eq(devloop_base.configure_trusted_bot_login("plain-bot"), "plain-bot")
    t.eq(devloop_base.trusted_bot_login(), "plain-bot")
    devloop_base.configure_trusted_bot_login(nil)
  end,

  test_comment_author_login_normalizes_bracket_bot_suffix = function()
    t.eq(parsers_misc.comment_author_login({ author_login = "chronoai-bot[bot]" }), "chronoai-bot")
    t.eq(parsers_misc.comment_author_login({ author = { login = "chronoai-bot[bot]" } }), "chronoai-bot")
    t.eq(parsers_misc.comment_author_login({ user = { login = "chronoai-bot[bot]" } }), "chronoai-bot")
    t.eq(parsers_misc.comment_author_login({ author_login = "octocat" }), "octocat")
  end,

  test_authorless_comment_is_not_trusted = function()
    devloop_base.configure_trusted_bot_login(nil)
    t.is_nil(parsers_misc.comment_author_login({ body = "authorless" }))
    t.eq(parsers_misc._is_trusted_comment({ body = "authorless" }), false)
  end,

  test_claimed_label_uses_derived_and_exclusive_postures = function()
    mock_identity("fkst-test-bot", "", 1)
    t.eq(m_claims.claimed_label(), derived_label)

    mock_identity("fkst-test-bot", "1", 1)
    t.eq(m_claims.claimed_label(), bare_label)
  end,

  test_exclusive_posture_treats_every_derived_label_as_foreign = function()
    mock_identity("fkst-test-bot", "1")
    t.eq(m_claims.issue_claim_state({}), "unassigned")
    t.eq(m_claims.issue_claim_state({ bare_label }), "self")
    t.eq(m_claims.issue_claim_state({ peer_label }), "other")
    t.eq(m_claims.issue_claim_state({ bare_label, peer_label }), "other")
  end,

  test_claim_owner_returns_bare_slug_for_bracket_bot_config = function()
    mock_identity("chronoai-bot[bot]", "", 1)
    t.eq(m_claims.claim_owner(), "chronoai-bot")
    devloop_base.configure_trusted_bot_login(nil)
  end,

  test_derived_posture_treats_bare_label_as_foreign = function()
    mock_identity("fkst-test-bot", "")
    t.eq(m_claims.issue_claim_state({ bare_label }), "other")
    t.eq(m_claims.issue_claim_state({ derived_label }), "self")
  end,

  test_attach_issue_claim_always_adds_the_active_label = function()
    mock_identity("fkst-test-bot", "")
    local payload = m_claims.attach_issue_claim({
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    })
    t.eq(payload.claim.label, derived_label)
    t.eq(payload.claim.owner, nil)
  end,

  test_bracket_bot_author_is_trusted_after_normalization = function()
    devloop_base.configure_trusted_bot_login("chronoai-bot")
    t.eq(parsers_misc._is_trusted_comment({
      author_login = "chronoai-bot[bot]",
      body = "x",
    }), true)
    devloop_base.configure_trusted_bot_login(nil)
  end,
}
