#!/usr/bin/env bash
# Pure helpers for fkst-substrate source pins. These functions intentionally do
# not clone, build, or contact the network.

FKST_DEFAULT_SUBSTRATE_OWNER="ChronoAIProject"
FKST_DEFAULT_SUBSTRATE_REPO="fkst-substrate"

fkst_trim_substrate_pin() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

fkst_valid_substrate_owner() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

fkst_valid_substrate_repo() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$value" != "." ] && [ "$value" != ".." ]
}

fkst_parse_substrate_pin() {
  local pin owner repo ref repo_part
  pin="$(fkst_trim_substrate_pin "${1:-}")"
  if [ -z "$pin" ]; then
    pin="dev"
  fi

  owner="$FKST_DEFAULT_SUBSTRATE_OWNER"
  repo="$FKST_DEFAULT_SUBSTRATE_REPO"
  ref="$pin"

  if [[ "$pin" == *@* ]]; then
    repo_part="${pin%%@*}"
    ref="${pin#*@}"
    owner="${repo_part%%/*}"
    repo="${repo_part#*/}"
    if [ "$owner" = "$repo_part" ] || [[ "$repo" == */* ]] || [ -z "$ref" ] \
      || ! fkst_valid_substrate_owner "$owner" || ! fkst_valid_substrate_repo "$repo"; then
      echo "error: invalid fkst-substrate pin: $pin" >&2
      return 1
    fi
  fi

  printf '%s\t%s\t%s\n' "$owner" "$repo" "$ref"
}

fkst_encode_substrate_path_component() {
  local value="$1" out="" char hex i
  if [ -z "$value" ]; then
    printf '%%00\n'
    return 0
  fi

  LC_ALL=C
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [A-Za-z0-9._-])
        out+="$char"
        ;;
      *)
        hex="$(printf '%s' "$char" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
        out+="%${hex}"
        ;;
    esac
  done
  case "$out" in
    .) out="%2E" ;;
    ..) out="%2E%2E" ;;
  esac
  printf '%s\n' "$out"
}

fkst_sanitize_substrate_path_component() {
  fkst_encode_substrate_path_component "$1"
}

fkst_sanitize_substrate_ref() {
  fkst_encode_substrate_path_component "$1"
}

fkst_substrate_cache_path() {
  local owner="$1" repo="$2" ref="$3" encoded_owner encoded_repo encoded_ref
  encoded_owner="$(fkst_encode_substrate_path_component "$owner")"
  encoded_repo="$(fkst_encode_substrate_path_component "$repo")"
  encoded_ref="$(fkst_encode_substrate_path_component "$ref")"
  printf '%s/.cache/fkst/substrate/%s/%s/%s\n' "${HOME:?HOME is required}" "$encoded_owner" "$encoded_repo" "$encoded_ref"
}
