-- Unit coverage for the label-scoped dev intake reuse points and orchestration, exercised
-- with the REAL shared library functions (github-issue.scopes, the real core skip guard,
-- the shared candidate builder + validator) and injected collaborators for the ambient
-- runtime seams (gh view read / claim / raise). No framework run -- the fire_raiser test
-- covers the real department routing.
local dev_intake = require("dev_intake")
local core = require("core")
local scopes = require("github-issue.scopes")
local intake_candidate = require("devloop.validators.intake_candidate")
local base_ids = require("devloop.base_ids")
local t = fkst.test

local REPO = "owner/repo"

-- A fake github port for github-issue.scopes.list: issue_search returns the label search
-- result (a gh_result-shaped { exit_code, stdout }); issue_view returns the per-issue full
-- view keyed by number.
local function fake_github(search_json, views)
  return {
    issue_search = function(_repo, _query, _fields, _limit)
      return { exit_code = 0, stdout = search_json }
    end,
    issue_view = function(_repo, number, _fields, _timeout)
      return { exit_code = 0, stdout = views[tostring(number)] or "{}" }
    end,
  }
end

local function search_item(number, state)
  return string.format(
    '{"number":%d,"title":"Issue %d","state":"%s","author":{"login":"alice"},"body":"body %d","url":"https://gh/%d"}',
    number, number, state, number, number
  )
end

local function view_json(number, state)
  return string.format(
    '{"number":%d,"title":"Issue %d","state":"%s","body":"body %d","comments":[],"author":{"login":"alice"},"url":"https://gh/%d"}',
    number, number, state, number, number
  )
end

-- A parsed intake-judge `current` view (the shape parse_issue_view_intake_judge returns).
local function current_view(fields)
  local f = fields or {}
  return {
    title = f.title or "Add a feature",
    body = f.body or "Please add the feature.",
    updated_at = f.updated_at or "2026-06-03T01:02:03Z",
    state = f.state or "OPEN",
    labels = f.labels or {},
    comments = f.comments or {},
    author_login = f.author_login or "alice",
    number = f.number,
  }
end

-- claim/emit doubles.
local function always_claim()
  return true, function(_core, _dept, _repo, _number, _current, _proposal_id)
    return true
  end
end

local function capture_emit()
  local raised = {}
  return raised, function(_dept, proposal_id, queue, payload)
    table.insert(raised, { proposal_id = proposal_id, queue = queue, payload = payload })
  end
end

return {
  test_constants_pin_the_label_and_the_existing_candidate_seam = function()
    t.eq(dev_intake.LABEL, "fkst-dev")
    t.eq(dev_intake.CANDIDATE_QUEUE, "github-devloop-intake.devloop_intake_candidate")
  end,

  test_scopes_list_discovers_only_open_fkst_dev_issues = function()
    local search = "[" .. table.concat({
      search_item(41, "OPEN"),
      search_item(42, "CLOSED"),
      search_item(43, "OPEN"),
    }, ",") .. "]"
    local views = {
      ["41"] = view_json(41, "OPEN"),
      ["43"] = view_json(43, "OPEN"),
    }
    local discovered = scopes.list({
      github = fake_github(search, views),
      repo = REPO,
      label = dev_intake.LABEL,
      bot_login = "fkst-bot",
    })
    t.eq(#discovered, 2)
    t.eq(discovered[1].number, 41)
    t.eq(discovered[1].repo, REPO)
    t.eq(discovered[2].number, 43)
  end,

  test_scopes_list_requires_a_non_empty_label = function()
    t.raises(function()
      scopes.list({ github = fake_github("[]", {}), repo = REPO, label = "" })
    end)
  end,

  test_build_candidate_passes_the_shared_intake_candidate_validator = function()
    local payload = dev_intake.build_candidate(REPO, current_view({ number = 43 }), 43)
    t.is_true(intake_candidate.is_supported_intake_candidate(payload))
    t.eq(payload.schema, "github-devloop.intake-candidate.v1")
    t.eq(payload.repo, REPO)
    t.eq(payload.issue_number, "43")
    t.eq(payload.proposal_id, base_ids.proposal_id(REPO, "43"))
    t.eq(payload.source_ref.ref, "owner/repo#issue/43")
    t.is_true(payload.effect_id ~= nil and payload.dedup_key ~= nil)
    -- No reintake command on the poll path.
    t.eq(payload.reintake_command_created_at, nil)
    t.eq(payload.reintake_effect_updated_at, nil)
  end,

  test_build_candidate_dedup_key_is_content_stable_across_polls = function()
    local first = dev_intake.build_candidate(REPO, current_view({ number = 43, updated_at = "2026-06-03T01:02:03Z" }), 43)
    local second = dev_intake.build_candidate(REPO, current_view({ number = 43, updated_at = "2026-07-16T09:09:09Z" }), 43)
    -- updated_at differs but the poll dedup_key is content-based, so it stays stable.
    t.eq(first.dedup_key, second.dedup_key)
    t.eq(first.effect_id, second.effect_id)
  end,

  test_should_skip_honors_state_labels_and_intake_marker = function()
    local proposal_id = base_ids.proposal_id(REPO, "43")
    -- clean OPEN issue is admitted.
    t.is_true(not dev_intake.should_skip(core, current_view({ number = 43 }), proposal_id))
    -- non-OPEN is skipped.
    t.is_true(dev_intake.should_skip(core, current_view({ number = 43, state = "CLOSED" }), proposal_id))
    -- a known active devloop label is skipped (hold / opted-in).
    t.is_true(dev_intake.should_skip(core, current_view({ number = 43, labels = { "fkst-dev:hold" } }), proposal_id))
    t.is_true(dev_intake.should_skip(core, current_view({ number = 43, labels = { "fkst-dev:enabled" } }), proposal_id))
  end,

  test_admit_scopes_skips_non_open_and_admits_a_valid_candidate = function()
    local raised, emit = capture_emit()
    local _, claim = always_claim()
    local reads = {}
    dev_intake.admit_scopes({
      core = core,
      dept = "dev_select",
      repo = REPO,
      scopes = { { number = 41 }, { number = 43 } },
      read_current = function(number)
        reads[tostring(number)] = (reads[tostring(number)] or 0) + 1
        if number == 41 then
          return current_view({ number = 41, state = "CLOSED" })
        end
        return current_view({ number = 43, state = "OPEN" })
      end,
      claim = claim,
      emit = emit,
    })
    -- exactly one candidate raised, for the OPEN issue, on the existing seam.
    t.eq(#raised, 1)
    t.eq(raised[1].queue, "github-devloop-intake.devloop_intake_candidate")
    t.eq(raised[1].payload.issue_number, "43")
    t.eq(raised[1].proposal_id, base_ids.proposal_id(REPO, "43"))
    t.is_true(intake_candidate.is_supported_intake_candidate(raised[1].payload))
  end,

  test_admit_scopes_does_not_claim_a_skipped_issue = function()
    local raised, emit = capture_emit()
    local claim_calls = {}
    dev_intake.admit_scopes({
      core = core,
      dept = "dev_select",
      repo = REPO,
      scopes = { { number = 41 } },
      read_current = function(_number)
        return current_view({ number = 41, state = "CLOSED" })
      end,
      claim = function(_core, _dept, _repo, number, _current, _proposal_id)
        table.insert(claim_calls, number)
        return true
      end,
      emit = emit,
    })
    t.eq(#raised, 0)
    t.eq(#claim_calls, 0)
  end,

  test_admit_scopes_skips_when_claim_is_lost = function()
    local raised, emit = capture_emit()
    dev_intake.admit_scopes({
      core = core,
      dept = "dev_select",
      repo = REPO,
      scopes = { { number = 43 } },
      read_current = function(_number)
        return current_view({ number = 43, state = "OPEN" })
      end,
      claim = function(_core, _dept, _repo, _number, _current, _proposal_id)
        return false
      end,
      emit = emit,
    })
    t.eq(#raised, 0)
  end,
}
