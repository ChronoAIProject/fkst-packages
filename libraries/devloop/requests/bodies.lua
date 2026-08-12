local C = {}
local autonomy_ledger = require("devloop.autonomy_ledger")
local comment_strings = require("devloop.strings")
local m_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")

function C.build_merging_comment_body(output_language, merge_ready)
  return comment_strings.comment_string(output_language, "is_merging_pr_prefix") .. tostring(merge_ready.pr_number)
    .. "\n\n" .. devloop_state.state_marker(merge_ready.proposal_id, "merging", merge_ready.version)
    .. "\n" .. m_builders.merging_marker(merge_ready.proposal_id, merge_ready.pr_number, merge_ready.version, merge_ready.reviewed_head_sha)
end

function C.build_merged_comment_body(output_language, merge_ready, autonomy_record)
  local autonomy_marker = ""
  if autonomy_record ~= nil then
    autonomy_marker = "\n" .. autonomy_ledger.autonomy_result_marker(autonomy_record)
  end
  return comment_strings.comment_string(output_language, "merged_pr_prefix") .. tostring(merge_ready.pr_number)
    .. "\n\n" .. devloop_state.state_marker(merge_ready.proposal_id, "merging", merge_ready.version)
    .. "\n" .. m_builders.merging_marker(merge_ready.proposal_id, merge_ready.pr_number, merge_ready.version, merge_ready.reviewed_head_sha)
    .. "\n" .. devloop_state.state_marker(merge_ready.proposal_id, "merged", merge_ready.version)
    .. "\n" .. m_builders.merged_marker(merge_ready.proposal_id, merge_ready.pr_number, merge_ready.version, merge_ready.reviewed_head_sha, autonomy_record)
    .. autonomy_marker
end

return C
