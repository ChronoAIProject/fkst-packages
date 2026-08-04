local base_ids = require("devloop.base_ids")
local child_status = require("core.materialize.child_status")
local core = require("core")
local devloop_marker_builders = require("devloop.markers.builders")
local marker = require("core.marker")
local t = fkst.test

local repo = "owner/repo"
local origin = base_ids.proposal_id(repo, 42)
local blueprint_digest = "d-1234567890"
local slot = "first"

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-05T00:00:00Z",
  }
end

local function child_ref(issue_number)
  return {
    kind = "issue",
    repo = repo,
    issue_number = tostring(issue_number),
    proposal_id = base_ids.proposal_id(repo, issue_number),
    source_ref = base_ids.issue_source_ref(repo, issue_number),
    workflow_lineage = {
      origin = origin,
      blueprint_digest = blueprint_digest,
      slot = slot,
    },
  }
end

local function disposition_comment(issue_number, disposition, fields)
  local extra = fields or {}
  local built, err = marker.build_child_disposition_marker({
    origin = origin,
    blueprint_digest = blueprint_digest,
    slot = slot,
    child_issue = tostring(issue_number),
    disposition = disposition,
    successor_source_ref = extra.successor_source_ref,
    reason_code = extra.reason_code,
  })
  t.is_nil(err)
  return trusted_comment(built)
end

local function entity(issue_number, state, comments)
  return {
    number = issue_number,
    state = state,
    body = "Workflow child.",
    author_login = "fkst-test-bot",
    comments = comments or {},
  }
end

local function append_late_merge(comments, issue_number, pr_number)
  local proposal = base_ids.proposal_id(repo, issue_number)
  local version = "ready/late-merge-v1"
  comments[#comments + 1] = trusted_comment(devloop_marker_builders.pr_link_marker(
    proposal,
    pr_number,
    "devloop-owner-repo-" .. tostring(issue_number),
    version,
    "dev"
  ))
  comments[#comments + 1] = trusted_comment(devloop_marker_builders.merged_marker(
    core,
    proposal,
    pr_number,
    version,
    "0123456789abcdef0123456789abcdef01234567"
  ))
end

local function reader(entities)
  return child_status.reader(core, {
    read_child_issue = function(_core, read_repo, issue_number)
      t.eq(read_repo, repo)
      return entities[tonumber(issue_number)]
    end,
  }, repo)
end

local tests = {
  test_production_reader_treats_satisfied_closed_child_as_ready = function()
    local entities = {
      [108] = entity(108, "CLOSED", {
        disposition_comment(108, "satisfied"),
      }),
    }
    local status = reader(entities)(child_ref(108))
    t.eq(status, "result_ready")
  end,

  test_production_reader_follows_transferred_successor_until_it_is_satisfied = function()
    local entities = {
      [108] = entity(108, "CLOSED", {
        disposition_comment(108, "transferred", {
          successor_source_ref = base_ids.issue_source_ref(repo, 109),
        }),
      }),
      [109] = entity(109, "OPEN"),
    }
    t.eq(reader(entities)(child_ref(108)), "running")

    append_late_merge(entities[108].comments, 108, 111)
    t.eq(reader(entities)(child_ref(108)), "running")

    local successor_proposal = base_ids.proposal_id(repo, 109)
    local successor_version = "ready/consensus-successor-v1"
    entities[109] = entity(109, "CLOSED", {
      trusted_comment(devloop_marker_builders.pr_link_marker(
        successor_proposal,
        110,
        "devloop-owner-repo-109",
        successor_version,
        "dev"
      )),
      trusted_comment(devloop_marker_builders.merged_marker(
        core,
        successor_proposal,
        110,
        successor_version,
        "0123456789abcdef0123456789abcdef01234567"
      )),
    })
    t.eq(reader(entities)(child_ref(108)), "result_ready")
  end,

  test_production_reader_preserves_undeliverable_why = function()
    local entities = {
      [108] = entity(108, "CLOSED", {
        disposition_comment(108, "undeliverable", {
          reason_code = "premise-refuted",
        }),
      }),
    }
    local status, detail = reader(entities)(child_ref(108))
    t.eq(status, "fatal")
    t.eq(detail.fatal_reason, "premise-refuted")

    append_late_merge(entities[108].comments, 108, 111)
    status, detail = reader(entities)(child_ref(108))
    t.eq(status, "fatal")
    t.eq(detail.fatal_reason, "premise-refuted")
  end,

  test_production_reader_keeps_raw_or_untrusted_closure_fatal = function()
    local raw_entities = {
      [108] = entity(108, "CLOSED"),
    }
    t.eq(reader(raw_entities)(child_ref(108)), "fatal")

    local forged = disposition_comment(108, "satisfied")
    forged.author_login = "human"
    local forged_entities = {
      [108] = entity(108, "CLOSED", { forged }),
    }
    t.eq(reader(forged_entities)(child_ref(108)), "fatal")
  end,
}

return tests
