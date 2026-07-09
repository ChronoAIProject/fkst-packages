#!/usr/bin/env bash
# launchd authority helpers for dogfood.sh. This file is sourced by dogfood.sh
# after the core dogfood topology helpers are defined.

launchd_label_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

launchd_label() { # $1 name
  printf 'com.fkst.dogfood.%s.%s\n' "$(launchd_label_component "$GH_ORG")" "$(launchd_label_component "$1")"
}

launchd_agents_dir() {
  printf '%s\n' "${DOGFOOD_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
}

launchd_domain() {
  if [ -n "${DOGFOOD_LAUNCHD_DOMAIN:-}" ]; then
    printf '%s\n' "$DOGFOOD_LAUNCHD_DOMAIN"
  else
    printf 'gui/%s\n' "$(id -u)"
  fi
}

launchctl_cmd() {
  "${DOGFOOD_LAUNCHCTL:-launchctl}" "$@"
}

dogfood_kill_cmd() {
  "${DOGFOOD_KILL_CMD:-kill}" "$@"
}

launchd_plist_path() { # $1 name
  printf '%s/%s.plist\n' "$(launchd_agents_dir)" "$(launchd_label "$1")"
}

render_launchd_plist() { # $1 name
  local name="$1" label stdout_path
  cfg "$name" || return 1
  build_supervise_args "$name" "" 1 || return 1
  build_supervise_env
  label="$(launchd_label "$name")"
  stdout_path="$LOGDIR/${name}-sv.log"

  python3 - "$label" "$stdout_path" "${#SUPERVISE_ARGS[@]}" "${SUPERVISE_ARGS[@]}" "${SUPERVISE_ENV[@]}" <<'PY'
import plistlib
import sys

label = sys.argv[1]
stdout_path = sys.argv[2]
argc = int(sys.argv[3])
program_arguments = sys.argv[4 : 4 + argc]
env_entries = sys.argv[4 + argc :]
environment = dict(entry.split("=", 1) for entry in env_entries)
payload = {
    "Label": label,
    "ProgramArguments": program_arguments,
    "EnvironmentVariables": environment,
    "KeepAlive": True,
    "AbandonProcessGroup": True,
    "StandardOutPath": stdout_path,
    "StandardErrorPath": stdout_path,
}
sys.stdout.buffer.write(plistlib.dumps(payload, sort_keys=False))
PY
}

cmd_render_launchd() { # $1 name
  local name="${1:-packages}"
  case "$name" in
    all|"") echo "usage: $0 render-launchd {packages|substrate|website}" >&2; return 2 ;;
  esac
  render_launchd_plist "$name"
}

launchd_conflicts() { # $1 name
  local name="$1" dir canonical label target_component argc
  cfg "$name" || return 1
  build_supervise_args "$name" "" 1 || return 1
  build_supervise_env
  dir="$(launchd_agents_dir)"
  canonical="$(launchd_plist_path "$name")"
  label="$(launchd_label "$name")"
  target_component="$(launchd_label_component "$name")"
  argc="${#SUPERVISE_ARGS[@]}"

  python3 - "$dir" "$canonical" "$label" "$HOST" "$DUR" "$target_component" "$argc" "${SUPERVISE_ARGS[@]}" "${SUPERVISE_ENV[@]}" <<'PY'
from pathlib import Path
import plistlib
import sys

directory = Path(sys.argv[1])
canonical = str(Path(sys.argv[2]))
expected_label = sys.argv[3]
expected_host = sys.argv[4]
expected_durable = sys.argv[5]
target_component = sys.argv[6]
argc = int(sys.argv[7])
expected_args = sys.argv[8 : 8 + argc]
expected_env = dict(entry.split("=", 1) for entry in sys.argv[8 + argc :])

def option_value(argv: object, option: str) -> str:
    if not isinstance(argv, list):
        return ""
    for index, value in enumerate(argv):
        if value == option and index + 1 < len(argv):
            return str(argv[index + 1])
    return ""

def reason_text(payload: dict, argv: object, env: object, label: str) -> list[str]:
    reasons: list[str] = []
    if label != expected_label:
        reasons.append("stale-label")
    if argv != expected_args:
        reasons.append("noncanonical-argv")
    if not isinstance(argv, list) or not argv or not Path(str(argv[0])).exists():
        reasons.append("deleted-program")
    if env != expected_env:
        reasons.append("noncanonical-env")
    if payload.get("AbandonProcessGroup") is not True:
        reasons.append("missing-abandonprocessgroup")
    if payload.get("KeepAlive") is not True:
        reasons.append("missing-keepalive")
    if "RunAtLoad" in payload:
        reasons.append("unexpected-runatload")
    return reasons

if not directory.exists():
    raise SystemExit(0)

for path in sorted(directory.glob("com.fkst.dogfood.*.plist")):
    path_text = str(path)
    try:
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
    except Exception:
        print(f"{path_text}\t\tmalformed-plist")
        continue
    if not isinstance(payload, dict):
        print(f"{path_text}\t\tmalformed-plist")
        continue

    label = str(payload.get("Label", ""))
    argv = payload.get("ProgramArguments")
    env = payload.get("EnvironmentVariables")
    label_tail = label.rsplit(".", 1)[-1]
    same_target_label = (
        label.startswith("com.fkst.dogfood.")
        and (label_tail == target_component or label_tail.startswith(target_component + "-"))
    )
    same_project = option_value(argv, "--project-root") == expected_host
    same_durable = option_value(argv, "--durable-root") == expected_durable
    is_canonical = path_text == canonical
    if not (is_canonical or same_target_label or same_project or same_durable):
        continue

    reasons = reason_text(payload, argv, env, label)
    if is_canonical:
        if reasons:
            print(f"{path_text}\t{label}\t{','.join(reasons)}")
    else:
        print(f"{path_text}\t{label}\t{','.join(reasons) if reasons else 'conflicting-same-target'}")
PY
}

launchd_remove_conflicts() { # $1 name
  local name="$1" domain path label reason failed=0
  domain="$(launchd_domain)"
  while IFS=$'\t' read -r path label reason; do
    [ -n "$path" ] || continue
    echo "[$name] removing stale launchd unit ${label:-unknown} (${reason:-conflict}) at $path"
    launchctl_cmd bootout "$domain" "$path" >/dev/null 2>&1 || true
    rm -f "$path" || failed=1
  done < <(launchd_conflicts "$name")
  return "$failed"
}

launchd_write_canonical_plist() { # $1 name
  local name="$1" dir path tmp
  dir="$(launchd_agents_dir)"
  path="$(launchd_plist_path "$name")"
  mkdir -p "$dir" || return 1
  tmp="${path}.$$"
  render_launchd_plist "$name" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$path"
  fi
  printf '%s\n' "$path"
}

launchd_reconcile_one() { # $1 name
  local name="$1" domain label plist
  cfg "$name" || return 1
  launchd_remove_conflicts "$name" || return 1
  plist="$(launchd_write_canonical_plist "$name")" || return 1
  domain="$(launchd_domain)"
  label="$(launchd_label "$name")"
  launchctl_cmd bootout "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl_cmd bootstrap "$domain" "$plist" || return 1
  launchctl_cmd kickstart -k "$domain/$label" || return 1
  echo "[$name] launchd authority active label=$label plist=$plist"
}

launchd_uninstall_one() { # $1 name
  local name="$1" domain plist
  cfg "$name" || return 1
  domain="$(launchd_domain)"
  launchd_remove_conflicts "$name" || return 1
  plist="$(launchd_plist_path "$name")"
  if [ -f "$plist" ]; then
    launchctl_cmd bootout "$domain" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist" || return 1
    echo "[$name] removed launchd authority plist=$plist"
  else
    echo "[$name] no launchd authority installed"
  fi
}

cmd_install_launchd() {
  local rc=0 n
  for n in $(expand "${1:-all}"); do launchd_reconcile_one "$n" || rc=1; done
  return "$rc"
}

cmd_uninstall_launchd() {
  local rc=0 n
  for n in $(expand "${1:-all}"); do launchd_uninstall_one "$n" || rc=1; done
  return "$rc"
}

launchd_main_pid() { # $1 name
  local name="$1" label domain
  label="$(launchd_label "$name")"
  domain="$(launchd_domain)"
  launchctl_cmd print "$domain/$label" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*"?[Pp][Ii][Dd]"?[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
    | head -1
}

launchd_canonical_command() { # $1 name
  cfg "$1" || return 1
  build_supervise_args "$1" "" 1 || return 1
  printf '%s' "${SUPERVISE_ARGS[*]}"
}

launchd_pid_argv_is_canonical() { # $1 name, $2 pid
  local name="$1" pid="$2" actual expected
  expected="$(launchd_canonical_command "$name")" || return 1
  actual="$(ps -ww -o command= -p "$pid" 2>/dev/null | sed -n '1p')"
  [ "$actual" = "$expected" ] || [[ "$actual" == *" $expected" ]]
}

launchd_authority_problem() { # $1 name, $2 running pids
  local name="$1" running_pids="$2" plist main_pid path label reason
  plist="$(launchd_plist_path "$name")"
  if [ ! -f "$plist" ]; then
    echo "NO-RESTART-AUTHORITY(no installed LaunchAgent)"
    return 0
  fi
  if IFS=$'\t' read -r path label reason < <(launchd_conflicts "$name") && [ -n "${path:-}" ]; then
    echo "NO-RESTART-AUTHORITY(stale LaunchAgent: ${reason:-conflict})"
    return 0
  fi
  main_pid="$(launchd_main_pid "$name")"
  if [ -z "$main_pid" ]; then
    echo "NO-RESTART-AUTHORITY(launchd job not loaded)"
    return 0
  fi
  if ! printf '%s\n' "$running_pids" | grep -qxF "$main_pid"; then
    echo "NO-RESTART-AUTHORITY(launchd pid $main_pid differs from supervise pid ${running_pids//$'\n'/,})"
    return 0
  fi
}

cmd_launchd_kill_test_one() { # $1 name
  local name="$1" budget deadline old_pid new_pid conflict_path conflict_label conflict_reason
  cfg "$name" || return 1
  if IFS=$'\t' read -r conflict_path conflict_label conflict_reason < <(launchd_conflicts "$name") && [ -n "${conflict_path:-}" ]; then
    echo "[$name] kill-test failed: stale launchd unit ${conflict_label:-unknown} (${conflict_reason:-conflict}) at $conflict_path"
    return 1
  fi
  old_pid="$(launchd_main_pid "$name")"
  if [ -z "$old_pid" ] || [ "$old_pid" = "0" ]; then
    echo "[$name] kill-test failed: no launchd main pid"
    return 1
  fi
  dogfood_kill_cmd -TERM "$old_pid" || return 1
  budget="${DOGFOOD_LAUNCHD_RESTART_BUDGET_SECONDS:-30}"
  deadline=$((SECONDS + budget))
  while [ "$SECONDS" -le "$deadline" ]; do
    new_pid="$(launchd_main_pid "$name")"
    if [ -n "$new_pid" ] && [ "$new_pid" != "0" ] && [ "$new_pid" != "$old_pid" ]; then
      if launchd_pid_argv_is_canonical "$name" "$new_pid"; then
        echo "[$name] kill-test ok old_pid=$old_pid new_pid=$new_pid"
        return 0
      fi
      echo "[$name] kill-test failed: redriven pid $new_pid has noncanonical argv"
      return 1
    fi
    sleep 0.2
  done
  echo "[$name] kill-test failed: restart budget expired after killing pid $old_pid"
  return 1
}

cmd_launchd_kill_test() {
  local rc=0 n
  for n in $(expand "${1:-all}"); do cmd_launchd_kill_test_one "$n" || rc=1; done
  return "$rc"
}
