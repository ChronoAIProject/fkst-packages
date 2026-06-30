#!/usr/bin/env bash
# Global host-profile helpers for scripts/run.sh.

HOST_PROFILE_PATH=""
HOST_PROFILE_HOST_ROOT=""
HOST_PROFILE_PLATFORM_ROOT=""
HOST_PROFILE_LOCAL_PACKAGES=""

host_profile_usage() {
  cat >&2 <<'EOF'
usage: scripts/run.sh host-profile <name> -- <check|test|supervise [args]>
   or: scripts/run.sh host-profile --file <path> -- <check|test|supervise [args]>
   or: scripts/run.sh host-profile init <name> [--force]

Profiles are dotenv-style KEY=VALUE files under FKST_HOST_PROFILE_DIR, or
$XDG_CONFIG_HOME/fkst/host-profiles, or $HOME/.config/fkst/host-profiles.
EOF
}

host_profile_die() {
  echo "error: $*" >&2
  return 1
}

host_profile_config_dir() {
  if [ -n "${FKST_HOST_PROFILE_DIR:-}" ]; then
    printf '%s\n' "$FKST_HOST_PROFILE_DIR"
    return 0
  fi
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/fkst/host-profiles\n' "$XDG_CONFIG_HOME"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    printf '%s/.config/fkst/host-profiles\n' "$HOME"
    return 0
  fi
  host_profile_die "cannot locate host profile directory; set FKST_HOST_PROFILE_DIR or HOME"
}

host_profile_abs_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$path" ;;
  esac
}

host_profile_validate_name() {
  local name="$1"
  case "$name" in
    ""|"."|".."|*/*|*[!A-Za-z0-9._-]*)
      host_profile_die "invalid host profile name: $name"
      return 1
      ;;
  esac
}

host_profile_path_for_name() {
  local name="$1" dir
  host_profile_validate_name "$name" || return 1
  dir="$(host_profile_config_dir)" || return 1
  printf '%s/%s.env\n' "$dir" "$name"
}

host_profile_trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s\n' "$text"
}

host_profile_key_allowed() {
  local key="$1"
  case "$key" in
    BIN|FKST_*) return 0 ;;
    *) return 1 ;;
  esac
}

host_profile_unquote_value() {
  local value="$1" path="$2" line_no="$3"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
    \"*|*\"|\'*|*\')
      host_profile_die "$path:$line_no has mismatched quotes"
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

host_profile_apply_value() {
  local key="$1" value="$2"
  export "$key=$value"
  case "$key" in
    FKST_HOST_ROOT) HOST_PROFILE_HOST_ROOT="$value" ;;
    FKST_PLATFORM_ROOT) HOST_PROFILE_PLATFORM_ROOT="$value" ;;
    FKST_LOCAL_PACKAGES) HOST_PROFILE_LOCAL_PACKAGES="$value" ;;
  esac
}

host_profile_load_file() {
  local path="$1" raw line key value line_no=0
  [ -f "$path" ] || { host_profile_die "host profile not found: $path"; return 1; }
  HOST_PROFILE_HOST_ROOT=""
  HOST_PROFILE_PLATFORM_ROOT=""
  HOST_PROFILE_LOCAL_PACKAGES=""
  while IFS= read -r raw || [ -n "$raw" ]; do
    line_no=$((line_no + 1))
    line="$(host_profile_trim "$raw")"
    case "$line" in
      ""|\#*) continue ;;
      export\ *) line="$(host_profile_trim "${line#export }")" ;;
    esac
    case "$line" in
      *=*) ;;
      *) host_profile_die "$path:$line_no expected KEY=VALUE"; return 1 ;;
    esac
    key="$(host_profile_trim "${line%%=*}")"
    value="$(host_profile_trim "${line#*=}")"
    case "$key" in
      ""|[0-9]*|*[!A-Za-z0-9_]*)
        host_profile_die "$path:$line_no invalid key: $key"
        return 1
        ;;
    esac
    if ! host_profile_key_allowed "$key"; then
      host_profile_die "$path:$line_no key is outside the host-profile contract: $key"
      return 1
    fi
    value="$(host_profile_unquote_value "$value" "$path" "$line_no")" || return 1
    host_profile_apply_value "$key" "$value"
  done < "$path"
}

host_profile_has_option() {
  local wanted="$1"
  shift
  while [ "$#" -gt 0 ]; do
    [ "$1" = "$wanted" ] && return 0
    shift
  done
  return 1
}

host_profile_command_with_defaults() {
  local command="$1"
  shift
  if [ "$command" != "supervise" ]; then
    printf '%s\0' "$command" "$@"
    return 0
  fi

  printf '%s\0' "$command"
  if ! host_profile_has_option "--durable-root" "$@" && [ -n "${FKST_DURABLE_ROOT:-}" ]; then
    printf '%s\0' "--durable-root" "$FKST_DURABLE_ROOT"
  fi
  if ! host_profile_has_option "--runtime-root" "$@" && [ -n "${FKST_RUNTIME_ROOT:-}" ]; then
    printf '%s\0' "--runtime-root" "$FKST_RUNTIME_ROOT"
  fi
  printf '%s\0' "$@"
}

host_profile_run() {
  local profile_name="" profile_file="" profile_dir="" host_args=() command_args=() final_command=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file)
        [ "$#" -ge 2 ] || { host_profile_die "--file requires a path"; return 2; }
        profile_file="$2"; shift 2 ;;
      --profile-dir)
        [ "$#" -ge 2 ] || { host_profile_die "--profile-dir requires a path"; return 2; }
        profile_dir="$2"; shift 2 ;;
      --)
        shift
        break ;;
      -h|--help)
        host_profile_usage
        return 0 ;;
      --*)
        host_profile_die "unknown host-profile option: $1"
        host_profile_usage
        return 2 ;;
      *)
        if [ -n "$profile_name" ]; then
          host_profile_die "host-profile accepts one profile name"
          return 2
        fi
        profile_name="$1"; shift ;;
    esac
  done

  [ "$#" -gt 0 ] || { host_profile_die "host command is required after --"; host_profile_usage; return 2; }
  if [ -n "$profile_dir" ]; then
    FKST_HOST_PROFILE_DIR="$profile_dir"
    export FKST_HOST_PROFILE_DIR
  fi
  if [ -z "$profile_file" ]; then
    [ -n "$profile_name" ] || { host_profile_die "profile name or --file is required"; return 2; }
    profile_file="$(host_profile_path_for_name "$profile_name")" || return 1
  fi
  HOST_PROFILE_PATH="$(host_profile_abs_path "$profile_file")"
  host_profile_load_file "$HOST_PROFILE_PATH" || return 1
  [ -n "$HOST_PROFILE_HOST_ROOT" ] || { host_profile_die "$HOST_PROFILE_PATH must set FKST_HOST_ROOT"; return 1; }

  host_args=(--host-root "$HOST_PROFILE_HOST_ROOT")
  if [ -n "$HOST_PROFILE_PLATFORM_ROOT" ]; then
    host_args+=(--platform-root "$HOST_PROFILE_PLATFORM_ROOT")
  fi
  if [ -n "$HOST_PROFILE_LOCAL_PACKAGES" ]; then
    host_args+=(--local-packages "$HOST_PROFILE_LOCAL_PACKAGES")
  fi

  command_args=("$@")
  while IFS= read -r -d '' item; do
    final_command+=("$item")
  done < <(host_profile_command_with_defaults "${command_args[@]}")

  echo "host_profile=$HOST_PROFILE_PATH"
  cmd_host "${host_args[@]}" -- "${final_command[@]}"
}

host_profile_write_template() {
  local path="$1" name="$2"
  cat > "$path" <<EOF
# FKST host profile: $name
# This file is data, not shell code. Only BIN and FKST_* keys are accepted.

# Required: the host repository to run against.
FKST_HOST_ROOT=/path/to/host-repo

# Optional: the fkst-packages checkout supplying shared scripts and platform packages.
# Defaults to the checkout containing scripts/run.sh when omitted.
FKST_PLATFORM_ROOT=/path/to/fkst-packages

# Optional: override the host package directory.
# FKST_LOCAL_PACKAGES=/path/to/host-repo/.fkst/local-packages

# Optional local engine binary. If omitted, scripts/run.sh uses its normal BIN resolution.
BIN=/path/to/fkst-substrate/target/debug/fkst-framework

# Optional real-run posture and host facts.
# FKST_GITHUB_REPO=owner/repo
# FKST_GITHUB_WRITE=1
# FKST_GITHUB_BOT_LOGIN=<bot-login>
# FKST_GITHUB_PROXY_POLL_LABEL_PREFIX=fkst-dev:
# FKST_DEVLOOP_UPSTREAM_BRANCH=dev
# FKST_DEVLOOP_INTEGRATION_BRANCH=integration-<device>
# FKST_DEVLOOP_ROLLUP_MERGE=auto

# Optional global state roots for no-repo-pollution supervise runs.
# FKST_RUNTIME_ROOT=/path/to/global/runtime-scratch
# FKST_DURABLE_ROOT=/path/to/global/durable-store
# FKST_RATE_POOL_ROOT=/path/to/global/rate-pools
# FKST_RATE_POOL_GH=50,50
EOF
}

host_profile_init() {
  local profile_name="" profile_dir="" force=0 path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile-dir)
        [ "$#" -ge 2 ] || { host_profile_die "--profile-dir requires a path"; return 2; }
        profile_dir="$2"; shift 2 ;;
      --force)
        force=1; shift ;;
      -h|--help)
        host_profile_usage
        return 0 ;;
      --*)
        host_profile_die "unknown host-profile init option: $1"
        return 2 ;;
      *)
        if [ -n "$profile_name" ]; then
          host_profile_die "host-profile init accepts one profile name"
          return 2
        fi
        profile_name="$1"; shift ;;
    esac
  done
  [ -n "$profile_name" ] || { host_profile_die "host-profile init requires a profile name"; return 2; }
  if [ -n "$profile_dir" ]; then
    FKST_HOST_PROFILE_DIR="$profile_dir"
    export FKST_HOST_PROFILE_DIR
  fi
  path="$(host_profile_path_for_name "$profile_name")" || return 1
  if [ -e "$path" ] && [ "$force" -ne 1 ]; then
    host_profile_die "host profile already exists: $path (use --force to overwrite)"
    return 1
  fi
  mkdir -p "$(dirname "$path")"
  host_profile_write_template "$path" "$profile_name"
  echo "wrote host profile scaffold: $path"
}

cmd_host_profile() {
  case "${1:-}" in
    ""|-h|--help|help)
      host_profile_usage
      return 0 ;;
    init)
      shift
      host_profile_init "$@" ;;
    *)
      host_profile_run "$@" ;;
  esac
}
