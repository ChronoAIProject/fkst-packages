# dogfood_board.sh - GitHub board classification and rendering for dogfood.sh.

# Parse an ISO-8601 UTC timestamp (trailing Z) to epoch. TZ=UTC is REQUIRED: BSD `date -j -f`
# ignores the Z and parses in the local zone, so on a +HH machine every computed age is inflated by
# the local UTC offset (e.g. +0800 -> board recency reads 8h too old -> healthy issues mislabelled
# "STUCK 8h"). now=`date +%s` is already zone-independent, so only the parse side needed fixing.
epoch_utc() { [ -z "${1:-}" ] && { echo 0; return; }; TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }

issue_author_ownership() { # $1 issue author login -> "peer" | "other" | "" (self/unknown)
  local author="$1"
  [ -n "$author" ] || return 1
  [ "$author" = "$BOT" ] && return 1
  case ",$MANAGED_BOT_LOGINS," in
    *",$author,"*) echo peer; return 0 ;;
  esac
  # A managed peer often files under an app login absent from this host's MANAGED list. The two
  # GitHub surfaces spell the same app differently — REST returns `<login>[bot]`, GraphQL returns
  # `app/<login>` — so both spellings have to be recognised or the row warns on one surface only.
  case "$author" in
    app/*|*\[bot\]|*-bot) echo peer; return 0 ;;
  esac
  echo other
}

issue_label_has() { # $1 comma-separated labels, $2 label
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

issue_primary_state() { # $1 comma-separated fkst-dev labels
  local labels="$1" label state fallback="" old_ifs="$IFS"
  IFS=,
  for label in $labels; do
    [ -n "$label" ] || continue
    state="${label#fkst-dev:}"
    [ -n "$fallback" ] || fallback="$state"
    case "$state" in
      enabled|blocked-on-dependency) continue ;;
      *) IFS="$old_ifs"; echo "$state"; return 0 ;;
    esac
  done
  IFS="$old_ifs"
  echo "$fallback"
}

issue_recency_class() { # $1 issue-number, $2 labels, $3 state, $4 age-hours, $5 stale-hours, $6 open-pr-issue-numbers
  local num="$1" labels="$2" st="$3" age="$4" stale="$5" openpr="$6"
  case "$st" in
    tracking|pr-open) echo "tracking/umbrella" ;;
    blocked|impl-failed|merged|declined) echo "parked($st)" ;;
    thinking|ready|implementing|stalled-thinking)
      if [ "$st" = "ready" ] && issue_label_has "$labels" "fkst-dev:blocked-on-dependency"; then
        echo "parked(dependency-wait)"
      elif [ "$age" -ge "$stale" ]; then
        echo "⚠ STUCK $st ${age}h"
      else
        echo "✓ flowing $st ${age}h"
      fi
      ;;
    reviewing|fixing|review-meta|merge-ready|merging)
      if echo "$openpr" | grep -qx "$num"; then echo "$st →see PR (active)"; else echo "⚠ STRANDED $st (no open PR)"; fi
      ;;
    awaiting-pr)
      echo "✓ waiting child-cascade ${age}h"
      ;;
    # unknown state: render it visibly instead of silently dropping the row (expose, don't swallow)
    *) echo "⚠ UNRENDERED-STATE $st ${age}h" ;;
  esac
}

workflow_board_fact_tool() {
  local tool="$PKGSRC/packages/github-devloop-workflow/tools/workflow_board_fact.py"
  if [ -f "$tool" ]; then
    printf '%s\n' "$tool"
    return 0
  fi
  tool="$_repo_root/packages/github-devloop-workflow/tools/workflow_board_fact.py"
  [ -f "$tool" ] && printf '%s\n' "$tool"
}

workflow_board_fact() { # $1 issue-number
  local num="$1" origin comments fact tool
  origin="github-devloop/issue/$REPO/$num"
  tool="$(workflow_board_fact_tool)" || return 1
  [ -n "$tool" ] || return 1
  comments=$(fetch_entity_comments "$num") || return 1
  fact=$(printf '%s' "$comments" | python3 "$tool" \
    --origin "$origin" \
    --bot-login "$BOT" \
    --managed-bot-logins "$MANAGED_BOT_LOGINS" 2>/dev/null) || return 1
  [ -n "$fact" ] || return 1
  printf '%s\n' "$fact"
}

lifecycle_board_fact_tool() {
  local tool="$PKGSRC/packages/github-devloop/tools/lifecycle_board_fact.py"
  if [ -f "$tool" ]; then
    printf '%s\n' "$tool"
    return 0
  fi
  tool="$_repo_root/packages/github-devloop/tools/lifecycle_board_fact.py"
  [ -f "$tool" ] && printf '%s\n' "$tool"
}

lifecycle_board_fact() { # $1 issue-number
  local num="$1" origin comments fact tool
  origin="github-devloop/issue/$REPO/$num"
  tool="$(lifecycle_board_fact_tool)" || return 1
  [ -n "$tool" ] || return 1
  comments=$(fetch_entity_comments "$num") || return 1
  fact=$(printf '%s' "$comments" | python3 "$tool" \
    --origin "$origin" \
    --bot-login "$BOT" \
    --managed-bot-logins "$MANAGED_BOT_LOGINS" 2>/dev/null) || return 1
  [ -n "$fact" ] || return 1
  printf '%s\n' "$fact"
}

lifecycle_board_condition() { # $1 fact-json
  printf '%s' "$1" | jq -er '
    select((.state | type) == "string" and (.state | length) > 0)
    | select((.condition_started_at | type) == "string" and (.condition_started_at | length) > 0)
    | [.state, .condition_started_at]
    | @tsv
  '
}

# Fetch comments as a REST-shaped JSON array. GitHub applies separate secondary
# limits to REST and GraphQL, so a REST failure falls back to the GraphQL surfaces.
fetch_entity_comments() { # $1 issue-or-pr number
  local num="$1" out
  out=$(gh api --paginate "repos/$REPO/issues/$num/comments?per_page=100" 2>/dev/null) && {
    printf '%s' "$out"; return 0; }
  gh issue view "$num" --repo "$REPO" --json comments \
    -q '[.comments[]|{body:.body,user:{login:.author.login},created_at:.createdAt}]' 2>/dev/null \
  || gh pr view "$num" --repo "$REPO" --json comments \
    -q '[.comments[]|{body:.body,user:{login:.author.login},created_at:.createdAt}]' 2>/dev/null
}

# Project a PR's OWN authoritative github-devloop state:v1 markers into a board fact,
# symmetric with lifecycle_board_fact (issues). A PR's markers are keyed to the PARENT
# issue's proposal, so the origin is SELF-DISCOVERED from the PR's trusted pr-origin:v1
# or state:v1 `proposal="..."` field rather than derived from the PR number. This lets the PR
# classifier distinguish a genuinely-stuck PR from one that has reached a correct
# terminal (blocked/merged/closed_unmerged) — the CI+age-only classifier cannot.
# Exit 0 = lifecycle fact, 1 = authoritatively unmanaged, 2 = fact unavailable.
pr_lifecycle_board_fact() { # $1 pr-number
  local num="$1" comments fact fact_rc tool
  tool="$(lifecycle_board_fact_tool)" || return 2
  [ -n "$tool" ] || return 2
  comments=$(fetch_entity_comments "$num") || return 2
  fact=$(printf '%s' "$comments" | python3 "$tool" \
    --discover-pr-origin \
    --bot-login "$BOT" \
    --managed-bot-logins "$MANAGED_BOT_LOGINS" 2>/dev/null); fact_rc=$?
  [ "$fact_rc" -eq 0 ] || return "$fact_rc"
  [ -n "$fact" ] || return 2
  printf '%s\n' "$fact"
}

lifecycle_board_reclassify() { # $1 fact-json, $2 age-hours
  FACT_JSON="$1" AGE_H="$2" python3 - <<'PY'
import json
import os
import sys

try:
    fact = json.loads(os.environ.get("FACT_JSON", ""))
except json.JSONDecodeError:
    raise SystemExit(1)
state = str(fact.get("state") or "")
age = str(os.environ.get("AGE_H") or "0")
if fact.get("pipeline_stuck") is True:
    why = str(fact.get("why") or f"{state} pipeline-stuck")
    print(f"{state}\t⚠ {why}")
elif fact.get("terminal") is True:
    print(f"{state}\tparked({state})")
elif state == "awaiting-pr":
    print(f"{state}\t✓ waiting child-cascade {age}h")
else:
    raise SystemExit(1)
PY
}

board_one() { # $1 name, $2 stale_hours
  cfg "$1" || return 1
  local stale="$2" now; now=$(date +%s)
  echo "════════════════════════════════════════ $REPO"
  local p; p=$(pidof_df)
  echo "supervise: $([ -n "$p" ] && echo "pid $p up $(fmt_uptime "$(ps -o etime= -p $p 2>/dev/null|tr -d ' ')")" || echo 'NOT RUNNING locally') | graphql $(graphql_rate_limit)"
  local openpr; openpr=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[]|.head.ref' 2>/dev/null | grep -oE '/[0-9]+/' | tr -d '/' | sort -u)
  echo "── PRs (active work · CI · recency) ──"
  # Capture + check gh's exit status so a REST failure (e.g. the HTML 503 page GitHub serves
  # during an outage, which makes `--jq` error and gh exit non-zero) FAILS LOUD instead of the
  # old `2>/dev/null | while` swallowing it into a silently-EMPTY section — an empty board is
  # indistinguishable from "all resolved" (real blind spot hit during the 2026-07-17 REST outage).
  local pr_rows pr_rc
  pr_rows=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[]|"\(.number)\t\(.head.sha[0:8])\t\(.updated_at)\t\(.base.ref)\t\(.title[0:42])"' 2>/dev/null); pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    pr_rows=$(gh pr list --repo "$REPO" --state open --limit 100 \
      --json number,headRefOid,updatedAt,baseRefName,title \
      -q '.[]|"\(.number)\t\(.headRefOid[0:8])\t\(.updatedAt)\t\(.baseRefName)\t\(.title[0:42])"' 2>/dev/null); pr_rc=$?
  fi
  if [ "$pr_rc" -ne 0 ]; then
    echo "  ⚠ BOARD FETCH FAILED (pulls: REST and GraphQL both failed) — cross-check: gh pr list --repo $REPO --state open"
  else
  printf '%s\n' "$pr_rows" | while IFS=$'\t' read -r num sha upd base title; do
    [ -z "$num" ] && continue
    local chk a flow pr_fact="" pr_fact_rc pr_condition condition_started_at pr_state pr_override onset_missing=0
    chk=$(gh api "repos/$REPO/commits/$sha/check-runs" --jq '[.check_runs[]|select(.name|test("CodeQL")|not)|.conclusion//.status]|join(",")' 2>/dev/null)
    a=$(( (now - $(epoch_utc "$upd")) / 3600 ))
    pr_fact=$(pr_lifecycle_board_fact "$num"); pr_fact_rc=$?
    if [ "$pr_fact_rc" -eq 0 ]; then
      if pr_condition=$(lifecycle_board_condition "$pr_fact"); then
        pr_state="${pr_condition%%$'\t'*}"
        condition_started_at="${pr_condition#*$'\t'}"
        a=$(( (now - $(epoch_utc "$condition_started_at")) / 3600 ))
      else
        onset_missing=1
        pr_state=$(printf '%s' "$pr_fact" | jq -er '.state') || pr_state="unknown"
      fi
    elif [ "$pr_fact_rc" -ne 1 ]; then
      onset_missing=1
      pr_state="unknown"
    fi
    if   echo "$chk"|grep -qE 'failure|cancelled'; then flow="⚠ CI-RED"
    elif [ -z "$chk" ];                              then flow="⚠ NO-CI"
    elif [ "$onset_missing" -eq 1 ];                 then flow="⚠ CONDITION-ONSET-UNAVAILABLE $pr_state"
    elif [ "$a" -ge $((stale*2)) ];                  then flow="⚠ STUCK ${a}h"
    else flow="✓ flowing ${a}h"; fi
    # CI remains independent. The trusted marker supplies condition dwell and can also
    # reclassify terminal/pipeline-stuck states; it is not execution-liveness evidence.
    if [ -n "$pr_fact" ] && pr_override=$(lifecycle_board_reclassify "$pr_fact" "$a"); then
      flow="${pr_override#*$'\t'}"
    fi
    printf "  PR#%-4s →%-12s %-12s %s\n" "$num" "$base" "$flow" "$title"
  done
  fi
  echo "── issues (by fkst-dev state) ──"
  local issue_rows issue_rc
  issue_rows=$(gh api "repos/$REPO/issues?state=open&per_page=100" --jq '.[]|select(.pull_request==null)|([.labels[].name]|map(select(startswith("fkst-dev:")and .!="fkst-dev:enabled"))) as $labels|(([.labels[].name]|index("fkst-dashboard"))!=null) as $dash|"\(.number)\t\(.created_at)\t\(if ($labels|length)>0 then ($labels|join(",")) elif $dash then "__fkst_dashboard__" else "__fkst_stateless__" end)\t\(.user.login)\t\(.title[0:38])"' 2>/dev/null); issue_rc=$?
  if [ "$issue_rc" -ne 0 ]; then
    issue_rows=$(gh issue list --repo "$REPO" --state open --limit 200 \
      --json number,updatedAt,labels,title,author \
      -q '.[]|([.labels[].name]|map(select(startswith("fkst-dev:")and .!="fkst-dev:enabled"))) as $labels|(([.labels[].name]|index("fkst-dashboard"))!=null) as $dash|"\(.number)\t\(.updatedAt)\t\(if ($labels|length)>0 then ($labels[0]|sub("^fkst-dev:";"")) elif $dash then "dashboard" else "stateless" end)\t\(.author.login)\t\(.title[0:42])"' 2>/dev/null); issue_rc=$?
  fi
  if [ "$issue_rc" -ne 0 ]; then
    echo "  ⚠ BOARD FETCH FAILED (issues: REST and GraphQL both failed) — cross-check: gh issue list --repo $REPO --state open"
  else
  printf '%s\n' "$issue_rows" | while IFS=$'\t' read -r num created label author title; do
    [ -z "$num" ] && continue
    local a st cls workflow_fact lifecycle_fact lifecycle_override; a=$(( (now - $(epoch_utc "$created")) / 3600 )); st="$(issue_primary_state "$label")"
    if [ "$label" = "__fkst_dashboard__" ]; then
      # fkst-dashboard is an intentionally long-lived tracked surface (intake decision=track), not pipeline work — never STRANDED
      st="dashboard"; cls="✓ dashboard (tracked)"
    elif [ -z "$label" ] || [ "$label" = "__fkst_stateless__" ]; then
      if workflow_fact=$(workflow_board_fact "$num"); then
        st="${workflow_fact%%$'\t'*}"
        cls="${workflow_fact#*$'\t'}"
      else
        st="stateless"
        if [ "$a" -ge "$stale" ]; then cls="⚠ STRANDED stateless ${a}h"; else cls="✓ waiting intake ${a}h"; fi
      fi
    else
      cls="$(issue_recency_class "$num" "$label" "$st" "$a" "$stale" "$openpr")"
      case "$st:$cls" in
        awaiting-pr:*|*:⚠*)
          if lifecycle_fact=$(lifecycle_board_fact "$num"); then
            local condition condition_started_at
            if condition=$(lifecycle_board_condition "$lifecycle_fact"); then
              st="${condition%%$'\t'*}"
              condition_started_at="${condition#*$'\t'}"
              a=$(( (now - $(epoch_utc "$condition_started_at")) / 3600 ))
              if lifecycle_override=$(lifecycle_board_reclassify "$lifecycle_fact" "$a"); then
                st="${lifecycle_override%%$'\t'*}"
                cls="${lifecycle_override#*$'\t'}"
              else
                cls="$(issue_recency_class "$num" "$label" "$st" "$a" "$stale" "$openpr")"
              fi
            elif lifecycle_override=$(lifecycle_board_reclassify "$lifecycle_fact" "$a"); then
              st="${lifecycle_override%%$'\t'*}"
              cls="${lifecycle_override#*$'\t'}"
            elif [ "$st" != "awaiting-pr" ]; then
              cls="⚠ CONDITION-ONSET-UNAVAILABLE $st"
            fi
          elif [ "$st" != "awaiting-pr" ]; then
            cls="⚠ CONDITION-ONSET-UNAVAILABLE $st"
          fi
          ;;
      esac
    fi
    # Ownership is decided by the issue author, exactly as claims.lua does: an issue authored by
    # another managed bot is skipped here by design (`skip-fork-peer-bot`), so flagging it as this
    # host's problem sends the operator to investigate work that is not theirs.
    local ownership
    if ownership=$(issue_author_ownership "$author"); then
      # Ownership only downgrades a warning. A row that already classified as something informative
      # — a tracked dashboard, a parked terminal — keeps that classification, which says more than
      # who owns it.
      case "$ownership:$cls" in
        peer:⚠*) cls="peer-owned($author)" ;;
        other:⚠*) cls="$cls author=$author" ;;
      esac
    fi
    printf "  #%-4s [%-12s] %s\n" "$num" "$st" "$cls"
  done
  fi
  echo ""
}

cmd_board() {
  local target="${1:-}" stale="${2:-6}"
  # accept `board <stale_hours>` (numeric first arg) as well as `board [name] [stale_hours]`
  if [ -n "$target" ] && [ -z "${target//[0-9]/}" ]; then stale="$target"; target=""; fi
  [ -z "$target" ] && target="$DOGFOOD_REPOS" || target=$(expand "$target")
  for n in $target; do board_one "$n" "$stale"; done
  echo "✓ flowing / tracking / parked = ok   ·   ⚠ STUCK/STRANDED/CI-RED/NO-CI = needs attention (stale=${stale}h)"
  echo "(label/marker-based fast view; for authoritative state cross-check the issue's state:v1 marker / workflow marker / linked PR)"
}
