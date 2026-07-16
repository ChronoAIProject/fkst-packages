-- github-devloop-dev-intake: the minimal composed-core surface the label-scoped dev
-- intake reuses.
--
-- It installs ONLY the two pieces the reused shared claim + intake-view parse + skip
-- guard actually read off the ambient core M:
--   * M.invalidate_entity_after_write -- devloop.claims label-mode claim re-reads
--     ownership through this after add-label (same binding github-devloop-intake/core.lua
--     uses).
--   * M.should_skip_known_intake_issue -- the intake skip guard, copied VERBATIM from
--     github-devloop-intake/core/admission.lua's install.
--
-- It deliberately does NOT `require("devloop.<mod>").install(M)` (that would grow the
-- shrink-only G-DEVLOOP-GODLIB / G-DEVLOOP-AMBIENT-SURFACE ratchets) and does NOT install
-- core.admission / core.replay_authorization: parse_issue_view_intake_judge never indexes
-- M, and label-mode claim needs only invalidate_entity_after_write.
local devloop_base = require("devloop.base")
local operator_commands = require("devloop.operator_commands")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")

local M = {}

M.invalidate_entity_after_write = github_proxy_entity_view.invalidate_entity_after_write

function M.should_skip_known_intake_issue(labels)
  return devloop_base.is_intake_held(labels)
    or devloop_base.is_opted_in(labels)
    or operator_commands.reintake_has_active_devloop_state(labels, nil, nil)
end

return M
