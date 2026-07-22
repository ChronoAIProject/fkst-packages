#!/usr/bin/env bash
# `scripts/run.sh run <package> <department> [event-json|--event-file <path>]` — invoke one department
# handler once against a single event and dump the decoded RAISED events + the <RT> tree. Sourced by
# run.sh; extracted from it to keep run.sh under the per-file line limit. This is the operator "run once"
# path (dogfood diagnosis), not part of the test/CI hot path. It relies on globals/helpers defined in
# run.sh (BIN, ROOT, DEFAULT_RUNTIME_ROOT, LOCAL_PACKAGES_ROOT, EXTERNAL_PACKAGES_ROOT, ensure_package_view,
# package_root_for_name, default_board_cmd), all in scope by the time main() dispatches `run`.

cmd_run() {
  local pkg="${1:-}" dept="${2:-}"
  if [ -z "$pkg" ] || [ -z "$dept" ]; then
    echo "usage: scripts/run.sh run <package> <department> [event-json]" >&2
    echo "   or: scripts/run.sh run <package> <department> --event-file <path>" >&2
    exit 1
  fi
  shift 2

  local event="{\"payload\":{}}" event_file="" inline_event=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event-file)
        if [ -n "$event_file" ]; then
          echo "error: --event-file can only be provided once" >&2
          exit 1
        fi
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "error: --event-file requires a readable path" >&2
          exit 1
        fi
        event_file="$2"
        shift 2
        ;;
      --event-file=*)
        if [ -n "$event_file" ]; then
          echo "error: --event-file can only be provided once" >&2
          exit 1
        fi
        event_file="${1#--event-file=}"
        if [ -z "$event_file" ]; then
          echo "error: --event-file requires a readable path" >&2
          exit 1
        fi
        shift
        ;;
      --*)
        echo "error: unknown run option: $1" >&2
        exit 1
        ;;
      *)
        if [ -n "$inline_event" ]; then
          echo "error: run accepts only one inline event JSON argument" >&2
          exit 1
        fi
        inline_event="$1"
        shift
        ;;
    esac
  done

  if [ -n "$event_file" ] && [ -n "$inline_event" ]; then
    echo "error: use either inline event JSON or --event-file, not both" >&2
    exit 1
  fi
  if [ -n "$event_file" ]; then
    [ -f "$event_file" ] || { echo "error: event file does not exist: $event_file" >&2; exit 1; }
    [ -r "$event_file" ] || { echo "error: event file is not readable: $event_file" >&2; exit 1; }
    event="$(< "$event_file")"
  elif [ -n "$inline_event" ]; then
    event="$inline_event"
  fi

  ensure_package_view
  local pkgdir lua args rootdir
  pkgdir="$(package_root_for_name "$pkg")" || { echo "error: no package named $pkg" >&2; exit 1; }
  lua="$pkgdir/departments/$dept/main.lua"
  [ -f "$lua" ] || { echo "error: no department at $lua" >&2; exit 1; }

  local rt fresh=0
  if [ -n "${FKST_RUNTIME_ROOT:-}" ]; then
    rt="$FKST_RUNTIME_ROOT"
  else
    rt="$DEFAULT_RUNTIME_ROOT"; fresh=1
    mkdir -p "$rt"
  fi
  export FKST_RUNTIME_ROOT="$rt"
  export FKST_DEVLOOP_BOARD_CMD="${FKST_DEVLOOP_BOARD_CMD:-$(default_board_cmd)}"

  echo "BIN=$BIN"
  echo "run $pkg/$dept  FKST_RUNTIME_ROOT=$rt${fresh:+ (fresh)}"
  if [ -n "${FKST_GITHUB_REPO:-}" ]; then echo "FKST_GITHUB_REPO=$FKST_GITHUB_REPO"; fi

  # Capture rc without set -e aborting at the assignment, so failure logs and
  # any partial RAISED/<RT> still print; propagate rc as the run's exit.
  local out rc=0
  args=("$BIN" run "$lua" --project-root "$ROOT")
  for rootdir in "$LOCAL_PACKAGES_ROOT"/*/ "$EXTERNAL_PACKAGES_ROOT"/*/; do
    [ -d "$rootdir" ] || continue
    args+=(--package-root "${rootdir%/}")
  done
  args+=(--owner-namespace "$pkg" --event "$event")
  out="$("${args[@]}" 2>&1)" || rc=$?

  echo "--- logs ---"
  printf '%s\n' "$out" | grep -vE '^RAISED:' || true
  echo "--- raised events (decoded) ---"
  local b64
  b64="$(printf '%s\n' "$out" | grep '^RAISED:' | sed 's/^RAISED: //' | tail -1 || true)"
  if [ -n "$b64" ]; then
    printf '%s' "$b64" | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null \
      || { echo "(raw)"; printf '%s' "$b64" | base64 -d 2>/dev/null; }
  else
    echo "  (no events raised)"
  fi
  echo "--- <RT> tree ---"
  find "$rt" -type f 2>/dev/null | sort | while read -r f; do
    echo "  ${f#"$rt"/} = $(cat "$f" 2>/dev/null | head -c 120)"
  done
  [ "$rc" -eq 0 ] || echo "--- run exited $rc ---" >&2
  return "$rc"
}
