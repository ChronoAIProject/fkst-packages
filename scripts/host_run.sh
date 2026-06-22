#!/usr/bin/env bash
# Host-run contract helpers for scripts/run.sh supervise.

HOST_RUN_PROJECT_ROOT=""
HOST_RUN_PLATFORM_ROOT=""
HOST_RUN_PLATFORM_PACKAGES=""
HOST_RUN_HOST_PACKAGES=""
HOST_RUN_DURABLE_ROOT=""
HOST_RUN_RUNTIME_ROOT=""
HOST_RUN_RUNTIME_IS_TEMP=0
HOST_RUN_RESTART=0
HOST_RUN_PACKAGE_ROOTS=()

host_run_usage() {
  cat >&2 <<'EOF'
usage: scripts/run.sh supervise --project-root <HOST> --platform-root <PKGSRC> --platform-packages "<names>" [--host-packages "<names>"] --durable-root <path> [--runtime-root <path>] [--restart]
   or: scripts/run.sh supervise <package>
EOF
}

host_run_abs_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$path" ;;
  esac
}

host_run_same_path() {
  local left="$1" right="$2" left_phys right_phys
  left_phys="$(cd "$left" 2>/dev/null && pwd -P)" || return 1
  right_phys="$(cd "$right" 2>/dev/null && pwd -P)" || return 1
  [ "$left_phys" = "$right_phys" ]
}

host_run_parse_supervise_args() {
  HOST_RUN_PROJECT_ROOT=""
  HOST_RUN_PLATFORM_ROOT=""
  HOST_RUN_PLATFORM_PACKAGES=""
  HOST_RUN_HOST_PACKAGES=""
  HOST_RUN_DURABLE_ROOT=""
  HOST_RUN_RUNTIME_ROOT=""
  HOST_RUN_RUNTIME_IS_TEMP=0
  HOST_RUN_RESTART=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-root)
        [ "$#" -ge 2 ] || { echo "error: --project-root requires a path" >&2; return 2; }
        HOST_RUN_PROJECT_ROOT="$2"; shift 2 ;;
      --platform-root)
        [ "$#" -ge 2 ] || { echo "error: --platform-root requires a path" >&2; return 2; }
        HOST_RUN_PLATFORM_ROOT="$2"; shift 2 ;;
      --platform-packages)
        [ "$#" -ge 2 ] || { echo "error: --platform-packages requires a package list" >&2; return 2; }
        HOST_RUN_PLATFORM_PACKAGES="$2"; shift 2 ;;
      --host-packages)
        [ "$#" -ge 2 ] || { echo "error: --host-packages requires a package list" >&2; return 2; }
        HOST_RUN_HOST_PACKAGES="$2"; shift 2 ;;
      --durable-root)
        [ "$#" -ge 2 ] || { echo "error: --durable-root requires a path" >&2; return 2; }
        HOST_RUN_DURABLE_ROOT="$2"; shift 2 ;;
      --runtime-root)
        [ "$#" -ge 2 ] || { echo "error: --runtime-root requires a path" >&2; return 2; }
        HOST_RUN_RUNTIME_ROOT="$2"; shift 2 ;;
      --restart)
        HOST_RUN_RESTART=1; shift ;;
      -h|--help)
        host_run_usage; return 2 ;;
      *)
        echo "error: unknown supervise option: $1" >&2
        host_run_usage
        return 2 ;;
    esac
  done

  [ -n "$HOST_RUN_PROJECT_ROOT" ] || { echo "error: --project-root is required" >&2; return 2; }
  [ -n "$HOST_RUN_PLATFORM_ROOT" ] || { echo "error: --platform-root is required" >&2; return 2; }
  [ -n "$HOST_RUN_PLATFORM_PACKAGES" ] || { echo "error: --platform-packages is required" >&2; return 2; }
  [ -n "$HOST_RUN_DURABLE_ROOT" ] || { echo "error: --durable-root is required for explicit supervise" >&2; return 2; }

  HOST_RUN_PROJECT_ROOT="$(host_run_abs_path "$HOST_RUN_PROJECT_ROOT")"
  HOST_RUN_PLATFORM_ROOT="$(host_run_abs_path "$HOST_RUN_PLATFORM_ROOT")"
  HOST_RUN_DURABLE_ROOT="$(host_run_abs_path "$HOST_RUN_DURABLE_ROOT")"
  if [ -n "$HOST_RUN_RUNTIME_ROOT" ]; then
    HOST_RUN_RUNTIME_ROOT="$(host_run_abs_path "$HOST_RUN_RUNTIME_ROOT")"
  else
    HOST_RUN_RUNTIME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fkst-host-run-rt.XXXXXX")"
    HOST_RUN_RUNTIME_IS_TEMP=1
  fi
}

host_run_validate_shape() {
  [ -d "$HOST_RUN_PROJECT_ROOT" ] || { echo "error: project root does not exist: $HOST_RUN_PROJECT_ROOT" >&2; return 1; }
  [ -d "$HOST_RUN_PLATFORM_ROOT" ] || { echo "error: platform root does not exist: $HOST_RUN_PLATFORM_ROOT" >&2; return 1; }
  [ -d "$HOST_RUN_PLATFORM_ROOT/packages" ] || { echo "error: platform root has no packages directory: $HOST_RUN_PLATFORM_ROOT/packages" >&2; return 1; }
  mkdir -p "$HOST_RUN_RUNTIME_ROOT" "$HOST_RUN_DURABLE_ROOT"
  if [ "$HOST_RUN_RUNTIME_ROOT" = "$HOST_RUN_DURABLE_ROOT" ]; then
    echo "error: --runtime-root and --durable-root resolved to the same directory" >&2
    return 1
  fi
}

host_run_host_package_base() {
  if host_run_same_path "$HOST_RUN_PROJECT_ROOT" "$HOST_RUN_PLATFORM_ROOT"; then
    printf '%s/packages\n' "$HOST_RUN_PROJECT_ROOT"
    return 0
  fi
  printf '%s/.fkst/local-packages\n' "$HOST_RUN_PROJECT_ROOT"
}

host_run_add_named_roots() {
  local base="$1" kind="$2" names="$3" name path
  for name in $names; do
    path="$base/$name"
    [ -d "$path" ] || { echo "error: missing $kind package '$name' at $path" >&2; return 1; }
    HOST_RUN_PACKAGE_ROOTS+=("$path")
  done
}

host_run_build_package_roots() {
  HOST_RUN_PACKAGE_ROOTS=()
  host_run_add_named_roots "$HOST_RUN_PLATFORM_ROOT/packages" "platform" "$HOST_RUN_PLATFORM_PACKAGES" || return 1
  if [ -n "$HOST_RUN_HOST_PACKAGES" ]; then
    host_run_add_named_roots "$(host_run_host_package_base)" "host" "$HOST_RUN_HOST_PACKAGES" || return 1
  fi
}

host_run_pid_file() {
  printf '%s/.fkst-supervise.pid\n' "$HOST_RUN_DURABLE_ROOT"
}

host_run_supervise_pid_matches() {
  local pid="$1" command_line expected
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  expected="supervise --project-root $HOST_RUN_PROJECT_ROOT"
  [ -n "$command_line" ] && [[ "$command_line" == *"$expected"* ]]
}

host_run_kill_supervise_pid() {
  local pid="$1" source="$2"
  kill -0 "$pid" 2>/dev/null || return 0
  if ! host_run_supervise_pid_matches "$pid"; then
    echo "restart: ignoring stale $source pid $pid for durable root $HOST_RUN_DURABLE_ROOT (process no longer matches project root)" >&2
    return 0
  fi
  echo "restart: killing prior supervise pid $pid for durable root $HOST_RUN_DURABLE_ROOT" >&2
  kill -9 "$pid" 2>/dev/null || true
}

host_run_restart_prior() {
  local pid_file pid pids=() delivery_db seen
  [ "$HOST_RUN_RESTART" -eq 1 ] || return 0
  pid_file="$(host_run_pid_file)"
  if [ -f "$pid_file" ]; then
    pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) pids+=("$pid:pid-file") ;;
    esac
  fi
  delivery_db="$HOST_RUN_DURABLE_ROOT/delivery.redb"
  if [ -f "$delivery_db" ] && command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      case "$pid" in
        ''|*[!0-9]*) ;;
        *) pids+=("$pid:lsof") ;;
      esac
    done < <(lsof -t "$delivery_db" 2>/dev/null || true)
  fi
  seen=""
  for pid in "${pids[@]}"; do
    local id="${pid%%:*}" source="${pid#*:}"
    case " $seen " in
      *" $id "*) continue ;;
    esac
    seen="$seen $id"
    host_run_kill_supervise_pid "$id" "$source"
  done
  if [ -n "$seen" ]; then
    sleep 1
  fi
  rm -f "$pid_file"
}

host_run_write_pid_file() {
  printf '%s\n' "$$" > "$(host_run_pid_file)"
}

host_run_print_package_roots() {
  local root
  for root in "${HOST_RUN_PACKAGE_ROOTS[@]}"; do
    printf '%s\n' "$root"
  done
}

host_run_supervise_contract() {
  host_run_parse_supervise_args "$@" || return $?
  host_run_validate_shape || return $?
  host_run_build_package_roots || return $?
  if [ -n "${FKST_RATE_POOL_ROOT:-}" ]; then
    case "$FKST_RATE_POOL_ROOT" in
      /*) ;;
      *)
        echo "error: FKST_RATE_POOL_ROOT must be an absolute host-stable directory path" >&2
        return 1
        ;;
    esac
  fi

  host_run_restart_prior
  export FKST_RUNTIME_ROOT="$HOST_RUN_RUNTIME_ROOT"
  export FKST_DURABLE_ROOT="$HOST_RUN_DURABLE_ROOT"
  export FKST_DEVLOOP_BOARD_CMD="${FKST_DEVLOOP_BOARD_CMD:-$(default_board_cmd)}"

  local args=() rootdir
  args=("$BIN" supervise --project-root "$HOST_RUN_PROJECT_ROOT")
  for rootdir in "${HOST_RUN_PACKAGE_ROOTS[@]}"; do
    args+=(--package-root "$rootdir")
  done
  args+=(--framework-bin "$BIN")

  echo "BIN=$BIN"
  echo "FKST_RUNTIME_ROOT=$FKST_RUNTIME_ROOT${HOST_RUN_RUNTIME_IS_TEMP:+ (fresh temp)}"
  echo "FKST_DURABLE_ROOT=$FKST_DURABLE_ROOT"
  if [ -n "${FKST_RATE_POOL_ROOT:-}" ]; then echo "FKST_RATE_POOL_ROOT=$FKST_RATE_POOL_ROOT"; fi
  if [ -n "${FKST_GITHUB_WRITE:-}" ]; then echo "FKST_GITHUB_WRITE=$FKST_GITHUB_WRITE"; else echo "FKST_GITHUB_WRITE=<unset> (dry-run)"; fi
  echo "project_root=$HOST_RUN_PROJECT_ROOT"
  echo "platform_root=$HOST_RUN_PLATFORM_ROOT"
  echo "package_roots:"
  host_run_print_package_roots | sed 's/^/  /'
  echo "This starts the real supervise event loop in the foreground. Press Ctrl-C to stop."
  echo "exec: ${args[*]}"
  host_run_write_pid_file
  exec "${args[@]}"
}
