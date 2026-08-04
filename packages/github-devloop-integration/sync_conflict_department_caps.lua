local core = require("core")

local M = {}

function M.production()
  return {
    decode = core.decode_sync_conflict_attempt_ledger,
    encode = core.sync_conflict_attempt_ledger,
    lineage = core.sync_conflict_lineage,
    max_attempts = core.max_sync_conflict_attempts,
    parse_ref_sha = core.parse_sync_conflict_attempt_ref_sha,
    ref = core.sync_conflict_attempt_ref,
  }
end

return M
