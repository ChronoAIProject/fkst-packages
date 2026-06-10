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

fkst_sanitize_substrate_path_component() {
  local value="$1"
  value="$(printf '%s' "$value" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
  value="$(printf '%s' "$value" | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$value" ]; then
    value="component"
  fi
  printf '%s\n' "$value"
}

fkst_sanitize_substrate_ref() {
  local ref
  ref="$(fkst_sanitize_substrate_path_component "$1")"
  if [ "$ref" = "component" ]; then
    ref="ref"
  fi
  printf '%s\n' "$ref"
}

fkst_substrate_cache_path() {
  local owner="$1" repo="$2" ref="$3" sanitized_owner sanitized_repo sanitized_ref
  sanitized_owner="$(fkst_sanitize_substrate_path_component "$owner")"
  sanitized_repo="$(fkst_sanitize_substrate_path_component "$repo")"
  sanitized_ref="$(fkst_sanitize_substrate_ref "$ref")"
  printf '%s/.cache/fkst/substrate/%s-%s-%s\n' "${HOME:?HOME is required}" "$sanitized_owner" "$sanitized_repo" "$sanitized_ref"
}
