local testing = require("testkit_internal.testing")

local M = {}

-- TRANSITION SHIM. Delete this branch, and always emit JSONL, once `.fkst/substrate-ref`
-- pins an engine at or after fkst-substrate#376: that engine adapts mocked Codex output
-- through the same strict JSONL parser as live output, while the engine pinned today
-- (2a0e1e77) has no JSONL projection at all and passes mocked stdout through raw. A single
-- payload cannot satisfy both, so the fixture has to know which engine it is running on.
--
-- `env_read` is an imperfect witness: it arrived in fkst-substrate#388, which is inside the
-- same unpinned range as #376, but it says nothing about the Codex adapter. It is used here
-- only because no adapter-specific capability is exposed to Lua. The witness is snapshotted
-- at require time on purpose -- packages/consensus/tests/live_run_admission_test.lua installs
-- its own `_G.env_read` double, and reading the global lazily would let that double flip this
-- fixture onto the wrong branch mid-suite.
local ENGINE_ADAPTS_MOCKED_CODEX = type(env_read) == "function"

function M.final_message(message)
  if type(message) ~= "string" then
    error("testkit-internal: codex-final-message-invalid: message must be a string")
  end
  if not ENGINE_ADAPTS_MOCKED_CODEX then
    return message
  end
  local text = testing.escape_json_string(message, "\\u%04X")
  return '{"type":"item.completed","item":{"type":"agent_message","text":"' .. text .. '"}}\n'
end

return M
