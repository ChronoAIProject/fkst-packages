local h = require("tests.devloop_core_helpers")
local transition_version = require("contract.transition_version")

local core = h.core
local t = h.t
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"

local function is_version_key(key)
  local text = tostring(key or "")
  return text == "version" or text:match("_version$") ~= nil
end

local function add_version(set, value)
  if type(value) == "string" then
    set[value] = true
  end
end

local function collect_version_fields(value, set)
  if type(value) ~= "table" then
    return
  end
  for key, field in pairs(value) do
    if is_version_key(key) then
      add_version(set, field)
    end
    collect_version_fields(field, set)
  end
end

local function collect_marker_versions(value, set)
  if type(value) == "string" then
    for attribute, version in value:gmatch('([%w_]+)="([^"]+)"') do
      if is_version_key(attribute) then
        add_version(set, version)
      end
    end
    return
  end
  if type(value) ~= "table" then
    return
  end
  for _, field in pairs(value) do
    collect_marker_versions(field, set)
  end
end

local function observed_versions()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local set = {}
  for _, observation in ipairs(inventory.old_behavior_observations or {}) do
    collect_version_fields(observation.old_inputs, set)
    collect_version_fields(observation.typed_intent and observation.typed_intent.generation_epoch, set)
    collect_version_fields(observation.old_outcome and observation.old_outcome.observable_writes, set)
    collect_marker_versions(observation.old_outcome and observation.old_outcome.observable_writes, set)
  end
  local versions = {}
  for version in pairs(set) do
    table.insert(versions, version)
  end
  table.sort(versions)
  return versions
end


local golden_safe_segments = {
  ["2026-06-02T01-02-03Z"] = "2026-06-02T01-02-03Z",
  ["2026-06-03T01-02-03Z"] = "2026-06-03T01-02-03Z",
  ["2026-06-03T01-02-03Z-fix-1-fix-2"] = "2026-06-03T01-02-03Z-fix-1-fix-2",
  ["2026-06-03T01-02-03Z/fix/1"] = "2026-06-03T01-02-03Z-fix-1",
  ["2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "2026-06-03T01-02-03Z-fix-1-fix-2-fix-3",
  ["bad"] = "bad",
  ["consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "consensus-github-devloop-issu-1434626341",
  ["consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/ready-split/1"] = "consensus-github-devloop-issu-4197114511",
  ["consensus:foreign/review"] = "consensus-foreign-review",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"] = "consensus-github-devloop-issu-1107715284",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "consensus-github-devloop-issu-2626237947",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/declined"] = "consensus-github-devloop-issu-3180357160",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/0"] = "consensus-github-devloop-issu-3546198904",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/01"] = "consensus-github-devloop-issu-0976578073",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1"] = "consensus-github-devloop-issu-3546198905",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/2"] = "consensus-github-devloop-issu-3546198906",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/3"] = "consensus-github-devloop-issu-3546198907",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/4"] = "consensus-github-devloop-issu-3546198908",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/ready-split/1"] = "consensus-github-devloop-issu-0177853723",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/ready/1"] = "consensus-github-devloop-issu-0197631063",
  ["consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-04Z"] = "consensus-github-devloop-issu-2643015566",
  ["consensus:github-devloop/pr-review/not-round-trippable/review"] = "consensus-github-devloop-pr-r-1719064971",
  ["consensus:github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review"] = "consensus-github-devloop-pr-r-0437898954",
  ["consensus:github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2959575353/def456/review"] = "consensus-github-devloop-pr-r-0589857683",
  ["consensus:github-devloop/pr-review/owner-repo-2718475964/7/v-loop-1/def456/review"] = "consensus-github-devloop-pr-r-4031845546",
  ["decompose/github-devloop/issue/owner/repo/4301/ready/consensus-github-devloop/issue/owner/repo/4301/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "decompose-github-devloop-issu-3436488310",
  ["decompose/github-devloop/issue/owner/repo/4302/ready/consensus-github-devloop/issue/owner/repo/4302/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "decompose-github-devloop-issu-2103400350",
  ["decompose/replay/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7/1/0"] = "decompose-replay-github-devlo-0283677656",
  ["decompose/replay/github-devloop/issue/owner/repo/4201/ready/consensus-github-devloop/issue/owner/repo/4201/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7001/1/0"] = "decompose-replay-github-devlo-0925213532",
  ["decompose/replay/github-devloop/issue/owner/repo/4202/ready/consensus-github-devloop/issue/owner/repo/4202/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7002/2/0"] = "decompose-replay-github-devlo-3915786234",
  ["decompose/replay/github-devloop/issue/owner/repo/4203/ready/consensus-github-devloop/issue/owner/repo/4203/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7003/2/1"] = "decompose-replay-github-devlo-1973367334",
  ["decompose/replay/github-devloop/issue/owner/repo/4204/ready/consensus-github-devloop/issue/owner/repo/4204/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7004/3/0"] = "decompose-replay-github-devlo-0668972744",
  ["decompose/replay/github-devloop/issue/owner/repo/4205/ready/consensus-github-devloop/issue/owner/repo/4205/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7005/3/1"] = "decompose-replay-github-devlo-3021521135",
  ["decompose/replay/github-devloop/issue/owner/repo/4206/ready/consensus-github-devloop/issue/owner/repo/4206/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7006/3/2"] = "decompose-replay-github-devlo-1079102235",
  ["decompose/replay/github-devloop/issue/owner/repo/4207/ready/consensus-github-devloop/issue/owner/repo/4207/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7007/1/0"] = "decompose-replay-github-devlo-2155601999",
  ["decompose/replay/github-devloop/issue/owner/repo/4208/ready/consensus-github-devloop/issue/owner/repo/4208/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7008/2/0"] = "decompose-replay-github-devlo-0851207410",
  ["decompose/replay/github-devloop/issue/owner/repo/4209/ready/consensus-github-devloop/issue/owner/repo/4209/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7009/2/1"] = "decompose-replay-github-devlo-3203755801",
  ["decompose/replay/github-devloop/issue/owner/repo/4210/ready/consensus-github-devloop/issue/owner/repo/4210/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7010/3/0"] = "decompose-replay-github-devlo-3716393334",
  ["decompose/replay/github-devloop/issue/owner/repo/4211/ready/consensus-github-devloop/issue/owner/repo/4211/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7011/3/1"] = "decompose-replay-github-devlo-1773974434",
  ["decompose/replay/github-devloop/issue/owner/repo/4212/ready/consensus-github-devloop/issue/owner/repo/4212/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/7012/3/2"] = "decompose-replay-github-devlo-4126522825",
  ["empty"] = "empty",
  ["fix-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "fix-reconcile-ready-consensus-0990772722",
  ["fixing/ci-failure/github-devloop/issue/owner/repo/42/7/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1"] = "fixing-ci-failure-github-devl-4097908908",
  ["fixing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z/fix/1/7/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review/noci"] = "fixing-github-devloop-issue-o-0293779662",
  ["fixing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/7/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review/noci"] = "fixing-github-devloop-issue-o-3249896558",
  ["fixing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12/7/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0846832491/def456/review/noci"] = "fixing-github-devloop-issue-o-4175953800",
  ["fixing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/loop/1/7/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review/noci"] = "fixing-github-devloop-issue-o-0918042321",
  ["github-devloop.merge-gate-reconcile.v1/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix-loop-max-rounds"] = "github-devloop.merge-gate-rec-0578558446",
  ["github-devloop.own-ci-reconcile.v1/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix-loop-max-rounds"] = "github-devloop.own-ci-reconci-1530018327",
  ["github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "github-devloop-issue-owner-re-1391474564",
  ["github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1"] = "github-devloop-issue-owner-re-3306236848",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118403/def456/review"] = "github-devloop-pr-review-owne-2286247082",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118404/def456/review"] = "github-devloop-pr-review-owne-1697876604",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118405/def456/r/m/1783840000000/attempt/2"] = "github-devloop-pr-review-owne-3165195857",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118406/def456/review"] = "github-devloop-pr-review-owne-0521135648",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118407/def456/review"] = "github-devloop-pr-review-owne-4227732461",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118408/def456/r/m/1783840000000/attempt/2"] = "github-devloop-pr-review-owne-4110115879",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118409/def456/r/m/1783840000000/attempt/2"] = "github-devloop-pr-review-owne-2993433456",
  ["github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2455118410/def456/r/m/1783840000000/attempt/2"] = "github-devloop-pr-review-owne-2310149039",
  ["intake/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "intake-github-devloop-issue-o-0150137095",
  ["merge-ready/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/7/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review/def456"] = "merge-ready-github-devloop-is-0532901636",
  ["merge-ready/github-devloop/issue/owner/repo/4301/ready/consensus-github-devloop/issue/owner/repo/4301/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12/7101/consensus-github-devloop/pr-review/owner-repo-2718475964/7101/ready-consensus-github-devloo-1830734466/def456/review/def456"] = "merge-ready-github-devloop-is-2540406183",
  ["merge-ready/github-devloop/issue/owner/repo/4302/ready/consensus-github-devloop/issue/owner/repo/4302/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12/7102/consensus-github-devloop/pr-review/owner-repo-2718475964/7102/ready-consensus-github-devloo-3880360937/def456/review/def456"] = "merge-ready-github-devloop-is-0132190537",
  ["merge-ready/github-devloop/pr/owner/repo/7/7/def456"] = "merge-ready-github-devloop-pr-3834698285",
  ["merge-ready/github-devloop/pr/owner/repo/8/7/def456"] = "merge-ready-github-devloop-pr-2270143063",
  ["other/lineage/timeout/fixing/3"] = "other-lineage-timeout-fixing-3",
  ["owner/repo#issue#42001@2026-06-03T01:02:03Z"] = "owner-repo-issue-42001-2026-0-3673670487",
  ["owner/repo#issue#42002@2026-06-03T01:02:03Z"] = "owner-repo-issue-42002-2026-0-2782579537",
  ["owner/repo#issue#42003@2026-06-03T01:02:03Z"] = "owner-repo-issue-42003-2026-0-1891488587",
  ["owner/repo#issue#42004@2026-06-03T01:02:03Z"] = "owner-repo-issue-42004-2026-0-1000397637",
  ["owner/repo#issue#42@2026-06-02T01:02:03Z"] = "owner-repo-issue-42-2026-06-02T01-02-03Z",
  ["owner/repo#issue#42@2026-06-03T01:02:03Z"] = "owner-repo-issue-42-2026-06-03T01-02-03Z",
  ["owner/repo#pr#7001@2026-06-04T01:02:03Z/bound/expected-1/completed-0"] = "owner-repo-pr-7001-2026-06-04-2969946724",
  ["owner/repo#pr#7002@2026-06-04T01:02:03Z/bound/expected-2/completed-0"] = "owner-repo-pr-7002-2026-06-04-4160102696",
  ["owner/repo#pr#7003@2026-06-04T01:02:03Z/bound/expected-2/completed-1"] = "owner-repo-pr-7003-2026-06-04-3030157321",
  ["owner/repo#pr#7004@2026-06-04T01:02:03Z/bound/expected-3/completed-0"] = "owner-repo-pr-7004-2026-06-04-4220313292",
  ["owner/repo#pr#7005@2026-06-04T01:02:03Z/bound/expected-3/completed-1"] = "owner-repo-pr-7005-2026-06-04-3090367917",
  ["owner/repo#pr#7006@2026-06-04T01:02:03Z/bound/expected-3/completed-2"] = "owner-repo-pr-7006-2026-06-04-1960422542",
  ["owner/repo#pr#7007@2026-06-04T01:02:03Z/unbound/expected-1/completed-0"] = "owner-repo-pr-7007-2026-06-04-0068565543",
  ["owner/repo#pr#7008@2026-06-04T01:02:03Z/unbound/expected-2/completed-0"] = "owner-repo-pr-7008-2026-06-04-0662752525",
  ["owner/repo#pr#7009@2026-06-04T01:02:03Z/unbound/expected-2/completed-1"] = "owner-repo-pr-7009-2026-06-04-3231805451",
  ["owner/repo#pr#7010@2026-06-04T01:02:03Z/unbound/expected-3/completed-0"] = "owner-repo-pr-7010-2026-06-04-4146323739",
  ["owner/repo#pr#7011@2026-06-04T01:02:03Z/unbound/expected-3/completed-1"] = "owner-repo-pr-7011-2026-06-04-2420409374",
  ["owner/repo#pr#7012@2026-06-04T01:02:03Z/unbound/expected-3/completed-2"] = "owner-repo-pr-7012-2026-06-04-0694495009",
  ["owner/repo#pr#7@2026-06-03T02:03:04Z"] = "owner-repo-pr-7-2026-06-03T02-03-04Z",
  ["ready-split/canonicalized/github-devloop/issue/owner/repo/42/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/ready-split/1"] = "ready-split-canonicalized-git-1001780323",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"] = "ready-consensus-github-devloo-3438267448",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z/fix/1"] = "ready-consensus-github-devloo-3609162682",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-2435338907",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "ready-consensus-github-devloo-3513658906",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "ready-consensus-github-devloo-0661822820",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/blocked/child-pr-blocked"] = "ready-consensus-github-devloo-0800108593",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/blocked/pr-base-unmanaged"] = "ready-consensus-github-devloo-2112364274",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/blocked/replacement-budget-exhausted"] = "ready-consensus-github-devloo-0513988732",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/closed-unmerged"] = "ready-consensus-github-devloo-3210921550",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1"] = "ready-consensus-github-devloo-0994879708",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2"] = "ready-consensus-github-devloo-2372379689",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-3554227821",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/blocked"] = "ready-consensus-github-devloo-0071504819",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "ready-consensus-github-devloo-2959575353",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12/fix/13"] = "ready-consensus-github-devloo-1027699444",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/other"] = "ready-consensus-github-devloo-2343666730",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/fixing/3"] = "ready-consensus-github-devloo-2183103405",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/fixing/3/merged"] = "ready-consensus-github-devloo-1459797500",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/fixing/3/timeout-reconcile/fixing/3"] = "ready-consensus-github-devloo-1094990679",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merge-ready/3"] = "ready-consensus-github-devloo-4287448819",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merge-ready/3/merged"] = "ready-consensus-github-devloo-1026257623",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merge-ready/3/timeout-reconcile/merge-ready/3"] = "ready-consensus-github-devloo-0942679463",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merging/3"] = "ready-consensus-github-devloo-2914081340",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merging/3/merged"] = "ready-consensus-github-devloo-2708455591",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/merging/3/timeout-reconcile/merging/3"] = "ready-consensus-github-devloo-3844965508",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/pr-open/3"] = "ready-consensus-github-devloo-1130876857",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/pr-open/3/merged"] = "ready-consensus-github-devloo-2192165097",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/pr-open/3/timeout-reconcile/pr-open/3"] = "ready-consensus-github-devloo-2319200063",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/review-meta/3"] = "ready-consensus-github-devloo-3644787497",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/review-meta/3/merged"] = "ready-consensus-github-devloo-3347749860",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/review-meta/3/timeout-reconcile/review-meta/3"] = "ready-consensus-github-devloo-1167258347",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/reviewing/3"] = "ready-consensus-github-devloo-2972537337",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/reviewing/3/merged"] = "ready-consensus-github-devloo-1470104661",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/reviewing/3/timeout-reconcile/reviewing/3"] = "ready-consensus-github-devloo-0361734610",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/loop/01"] = "ready-consensus-github-devloo-1718982275",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/loop/1"] = "ready-consensus-github-devloo-0687810013",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/3/blocked"] = "ready-consensus-github-devloo-4257407388",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/01"] = "ready-consensus-github-devloo-2851966537",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1"] = "ready-consensus-github-devloo-2599093192",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1/fix/1"] = "ready-consensus-github-devloo-3803130070",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/merged"] = "ready-consensus-github-devloo-2913131345",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/redrive/ready/1"] = "ready-consensus-github-devloo-3859238224",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/reimplement/1"] = "ready-consensus-github-devloo-0898072474",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/reimplement/2"] = "ready-consensus-github-devloo-0898072475",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/1"] = "ready-consensus-github-devloo-1236905179",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/1/rereview/1/def456"] = "ready-consensus-github-devloo-1230756998",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/3"] = "ready-consensus-github-devloo-1236905181",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/701"] = "ready-consensus-github-devloo-2455118403",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/702"] = "ready-consensus-github-devloo-2455118404",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/703"] = "ready-consensus-github-devloo-2455118405",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/704"] = "ready-consensus-github-devloo-2455118406",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/705"] = "ready-consensus-github-devloo-2455118407",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/706"] = "ready-consensus-github-devloo-2455118408",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/707"] = "ready-consensus-github-devloo-2455118409",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/708"] = "ready-consensus-github-devloo-2455118410",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-meta-action/1"] = "ready-consensus-github-devloo-2094081627",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-meta/1"] = "ready-consensus-github-devloo-4014748486",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout-reconcile/implementing/3"] = "ready-consensus-github-devloo-0493337192",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/implementing/3"] = "ready-consensus-github-devloo-1185352037",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/ready/3"] = "ready-consensus-github-devloo-0835123754",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/ready/3/timeout-reconcile/ready/3"] = "ready-consensus-github-devloo-0594419753",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"] = "ready-consensus-github-devloo-2180345483",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/fixing/3"] = "ready-consensus-github-devloo-0356272640",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/merge-ready/3"] = "ready-consensus-github-devloo-0733501156",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/merging/3"] = "ready-consensus-github-devloo-2497518444",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/pr-open/3"] = "ready-consensus-github-devloo-0714313961",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/ready/3"] = "ready-consensus-github-devloo-0953690615",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/review-meta/3"] = "ready-consensus-github-devloo-0090839834",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/timeout/reviewing/3"] = "ready-consensus-github-devloo-1033869684",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/fixing/3"] = "ready-consensus-github-devloo-3544228998",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/fixing/3/timeout-reconcile/fixing/3"] = "ready-consensus-github-devloo-4107881342",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/merge-ready/3"] = "ready-consensus-github-devloo-2866388340",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/merge-ready/3/timeout-reconcile/merge-ready/3"] = "ready-consensus-github-devloo-1834635029",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/merging/3"] = "ready-consensus-github-devloo-1064155132",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/merging/3/timeout-reconcile/merging/3"] = "ready-consensus-github-devloo-3711142331",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/pr-open/3"] = "ready-consensus-github-devloo-3575917940",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/pr-open/3/timeout-reconcile/pr-open/3"] = "ready-consensus-github-devloo-2185376886",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/review-meta/3"] = "ready-consensus-github-devloo-2223727018",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/review-meta/3/timeout-reconcile/review-meta/3"] = "ready-consensus-github-devloo-2059213913",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/reviewing/3"] = "ready-consensus-github-devloo-2223011470",
  ["ready/consensus-github-devloop/issue/owner/repo/42/2026-07-14T16-59-00Z/timeout/reviewing/3/timeout-reconcile/reviewing/3"] = "ready-consensus-github-devloo-2537471911",
  ["ready/consensus-github-devloop/issue/owner/repo/4201/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-1717889925",
  ["ready/consensus-github-devloop/issue/owner/repo/4202/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-0653993155",
  ["ready/consensus-github-devloop/issue/owner/repo/4203/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-3885063676",
  ["ready/consensus-github-devloop/issue/owner/repo/4204/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-2821166906",
  ["ready/consensus-github-devloop/issue/owner/repo/4205/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-1757270136",
  ["ready/consensus-github-devloop/issue/owner/repo/4206/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-0693373366",
  ["ready/consensus-github-devloop/issue/owner/repo/4207/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-3924443887",
  ["ready/consensus-github-devloop/issue/owner/repo/4208/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-2860547117",
  ["ready/consensus-github-devloop/issue/owner/repo/4209/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-1796650347",
  ["ready/consensus-github-devloop/issue/owner/repo/4210/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-0252558351",
  ["ready/consensus-github-devloop/issue/owner/repo/4211/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-3483628872",
  ["ready/consensus-github-devloop/issue/owner/repo/4212/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"] = "ready-consensus-github-devloo-2419732102",
  ["ready/consensus-github-devloop/issue/owner/repo/4301/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "ready-consensus-github-devloo-1830734466",
  ["ready/consensus-github-devloop/issue/owner/repo/4302/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/fix/4/fix/5/fix/6/fix/7/fix/8/fix/9/fix/10/fix/11/fix/12"] = "ready-consensus-github-devloo-3880360937",
  ["ready/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"] = "ready-github-devloop-issue-ow-1143331309",
  ["ready/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/blocked"] = "ready-github-devloop-issue-ow-0605187658",
  ["ready/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/merged"] = "ready-github-devloop-issue-ow-1216977729",
  ["reconcile:consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/3"] = "reconcile-consensus-github-de-3167333084",
  ["review-meta/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/7/3/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-0661822820/def456/review/loop/2"] = "review-meta-github-devloop-is-2496896028",
  ["review-meta/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1/7/3/consensus-github-devloop/pr-review/owner-repo-2718475964/7/ready-consensus-github-devloo-2599093192/def456/review/loop/2"] = "review-meta-github-devloop-is-0626292749",
  ["review-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/3"] = "review-reconcile-ready-consen-2085686982",
  ["reviewing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/7"] = "reviewing-github-devloop-issu-2556213291",
  ["reviewing/github-devloop/issue/owner/repo/42/ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z/7"] = "reviewing-github-devloop-issu-0581347348",
  ["source-snapshot:v1"] = "source-snapshot-v1",
  ["timeout-reconcile:consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/3/timeout-reconcile/blocked/3"] = "timeout-reconcile-consensus-g-3989806579",
  ["timeout-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/blocked/timeout-reconcile/blocked/3"] = "timeout-reconcile-ready-conse-0417566524",
  ["timeout-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3/timeout/fixing/3/timeout-reconcile/fixing/3"] = "timeout-reconcile-ready-conse-0325360119",
  ["timeout-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/implementing/3/timeout-reconcile/implementing/3"] = "timeout-reconcile-ready-conse-3518560089",
  ["timeout-reconcile:ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/ready/3/timeout-reconcile/ready/3"] = "timeout-reconcile-ready-conse-4135508286",
  ["unrelated-lineage/fix/1"] = "unrelated-lineage-fix-1",
  ["v-loop-01"] = "v-loop-01",
  ["v-loop-1"] = "v-loop-1",
  ["v1"] = "v1",
}

local suffix_pair_goldens = {
  {
    name = "slash fix chain",
    base = "2026-06-03T01-02-03Z",
    derived = "2026-06-03T01-02-03Z/fix/1/fix/2/fix/3",
    compare = -1,
  },
  {
    name = "hyphen fix chain",
    base = "2026-06-03T01-02-03Z",
    derived = "2026-06-03T01-02-03Z-fix-1-fix-2",
    compare = -1,
  },
  {
    name = "loop zero",
    base = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/0",
    compare = 0,
  },
  {
    name = "loop one",
    base = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1",
    compare = -1,
  },
  {
    name = "ready split",
    base = "consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/ready-split/1",
    compare = -1,
  },
  {
    name = "review loop",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/1",
    compare = -1,
  },
  {
    name = "review meta action",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-meta-action/1",
    compare = -1,
  },
  {
    name = "review meta",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-meta/1",
    compare = 0,
  },
  {
    name = "reimplement",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/reimplement/1",
    compare = -1,
  },
  {
    name = "timeout",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout/ready/3",
    compare = -1,
  },
  {
    name = "timeout reconcile",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/timeout-reconcile/implementing/3",
    compare = 0,
  },
  {
    name = "rereview",
    base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/1",
    derived = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/1/rereview/1/def456",
    stripped_base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    compare = 0,
  },
}

local malformed_goldens = {
  {
    value = "bad",
    safe = "bad",
    parsed_base = "bad",
  },
  {
    value = "consensus:github-devloop/pr-review/not-round-trippable/review",
    safe = "consensus-github-devloop-pr-r-1719064971",
    parsed_base = "consensus:github-devloop/pr-review/not-round-trippable/review",
  },
}

local ordering_probe_by_version = {}

local function actual_versions_equivalent(left, right, versions)
  local probe = ordering_probe_by_version[left]
  if probe == nil then
    for _, candidate in ipairs(versions) do
      if transition_version.compare(candidate, left) ~= 0 then
        probe = candidate
        ordering_probe_by_version[left] = candidate
        break
      end
    end
  end
  if probe == nil then
    error("observed version corpus has no non-equal ordering probe for " .. tostring(left), 0)
  end
  local status = core.cyclic_transition_status(
    { state = "ready", version = left },
    { "thinking" },
    "ready",
    probe,
    right
  )
  return status == "idempotent", status
end

local function expected_versions_equivalent(left, right)
  return golden_safe_segments[left] == golden_safe_segments[right]
end

local function count_keys(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count
end

return {
  test_observed_version_corpus_matches_frozen_safe_segment_goldens = function()
    local versions = observed_versions()
    local seen = {}
    t.eq(#versions, 200)
    t.eq(count_keys(golden_safe_segments), 200)
    for _, version in ipairs(versions) do
      seen[version] = true
      t.eq(transition_version.safe_version_segment(version), golden_safe_segments[version], version)
    end
    for version in pairs(golden_safe_segments) do
      t.eq(seen[version], true, "golden no longer observed: " .. version)
    end
  end,

  test_versions_equivalent_properties_and_compare_relationship_are_frozen = function()
    local versions = observed_versions()
    local relationship_counts = {
      equivalent_compare_equal = 0,
      equivalent_compare_nonzero = 0,
      non_equivalent_compare_equal = 0,
      non_equivalent_compare_nonzero = 0,
    }
    for index, left in ipairs(versions) do
      local reflexive = actual_versions_equivalent(left, left, versions)
      t.eq(reflexive, true, "reflexivity: " .. left)

      local right = versions[(index % #versions) + 1]
      local expected = expected_versions_equivalent(left, right)
      local forward = actual_versions_equivalent(left, right, versions)
      local reverse = actual_versions_equivalent(right, left, versions)
      t.eq(forward, expected, "equivalence: " .. left .. " <> " .. right)
      t.eq(reverse, forward, "symmetry: " .. left .. " <> " .. right)

      for _, compared in ipairs(versions) do
        local pair_equivalent = expected_versions_equivalent(left, compared)
        local compare_equal = transition_version.compare(left, compared) == 0
        local key = (pair_equivalent and "equivalent" or "non_equivalent")
          .. (compare_equal and "_compare_equal" or "_compare_nonzero")
        relationship_counts[key] = relationship_counts[key] + 1
      end
    end
    -- Frozen over the observed corpus (200 distinct forms, 40000 ordered pairs):
    --  * equivalent => compare-equal (equivalent_compare_nonzero == 0): versions_equivalent
    --    never claims equivalence for forms that transition_version.compare orders apart.
    --  * compare-equal does NOT imply equivalent (non_equivalent_compare_equal == 4032):
    --    versions_equivalent is STRICTER than ordering-equality -- it distinguishes forms
    --    that compare() treats as order-equal (different base/suffix families).
    -- These frozen counts confirm versions_equivalent's domain semantics over the real
    -- corpus; any future change that alters this relationship fails here.
    t.eq(relationship_counts.equivalent_compare_equal, 200, "relationship counts not frozen (eq&compare-equal = self-diagonal)")
    t.eq(relationship_counts.equivalent_compare_nonzero, 0, "relationship counts not frozen (equivalent => compare-equal)")
    t.eq(relationship_counts.non_equivalent_compare_equal, 4032, "relationship counts not frozen (compare-equal !=> equivalent)")
    t.eq(relationship_counts.non_equivalent_compare_nonzero, 35768, "relationship counts not frozen")
  end,

  test_observed_suffix_families_freeze_base_stripping_and_equivalence = function()
    local versions = observed_versions()
    for _, case in ipairs(suffix_pair_goldens) do
      t.is_true(golden_safe_segments[case.base] ~= nil, case.name .. " base is observed")
      t.is_true(golden_safe_segments[case.derived] ~= nil, case.name .. " derived form is observed")
      t.eq(transition_version.strip_suffixes(case.derived), case.stripped_base or case.base, case.name .. " stripped base")
      t.eq(actual_versions_equivalent(case.base, case.derived, versions), false, case.name .. " equivalence")
      t.eq(transition_version.compare(case.base, case.derived), case.compare, case.name .. " compare")
    end
  end,

  test_malformed_observed_forms_freeze_actual_non_error_behavior = function()
    local versions = observed_versions()
    for _, case in ipairs(malformed_goldens) do
      local parsed = transition_version.parse(case.value)
      t.eq(golden_safe_segments[case.value], case.safe, case.value .. " observed")
      t.eq(parsed.base, case.parsed_base, case.value .. " parsed base")
      t.eq(transition_version.render(parsed), case.value, case.value .. " render")
      t.eq(transition_version.compare(case.value, case.value), 0, case.value .. " compare self")
      t.eq(actual_versions_equivalent(case.value, case.value, versions), true, case.value .. " equivalent self")
    end
  end,
}
