#!/usr/bin/env bash
# Lua coverage collection and its ratchets, for `scripts/run.sh test`.
#
# Extracted from run.sh unchanged: these three functions are the only ones that deal with
# coverage artifacts and the test-file coverage gate, they are called from cmd_test and
# nowhere else, and run.sh had grown past the 900-line warning threshold. Behaviour is
# identical -- run.sh sources this file, so every function is defined exactly as before at
# the point cmd_test calls it, and fixtures that redefine them after sourcing still win.

run_self_test_with_optional_lua_coverage() {
  local coverage_dir="$FKST_RUNTIME_ROOT/lua-coverage" coverage_json out rc
  rm -rf "$coverage_dir"
  mkdir -p "$coverage_dir"
  set +e
  out="$(cd "$ROOT" && "$BIN" --self-test --coverage "$coverage_dir" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    coverage_json="$coverage_dir/coverage.json"
    if [ ! -f "$coverage_json" ]; then
      echo "error: fkst-framework --self-test --coverage did not write coverage.json in $coverage_dir" >&2
      return 1
    fi
    return $?
  fi
  if printf '%s\n' "$out" | grep -Eq "(unknown|unrecognized).*--coverage"; then
    echo "warning: fkst-framework does not expose --self-test --coverage; skipping Lua coverage ratchet artifact collection" >&2
    "$BIN" --self-test
    return $?
  fi
  printf '%s\n' "$out" >&2
  return "$rc"
}

enforce_lua_coverage_ratchet() {
  local output="${FKST_LUA_COVERAGE_OUTPUT:-$FKST_RUNTIME_ROOT/lua-coverage/coverage.json}" inputs=() artifact package_name
  shift || true
  if [ "$#" -eq 0 ]; then
    echo "error: Lua coverage ratchet has no package coverage artifacts" >&2
    return 1
  fi
  for artifact in "$@"; do
    package_name="$(basename "$(dirname "$artifact")")"
    inputs+=("$package_name=$artifact")
  done
  FKST_LUA_COVERAGE_MERGED_OUTPUT="$output" python3 -B - "$ROOT" "${inputs[@]}" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("check_repo_coverage", root / "scripts" / "check_repo_coverage.py")
if spec is None or spec.loader is None:
    raise SystemExit("error: could not load scripts/check_repo_coverage.py")
coverage = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = coverage
spec.loader.exec_module(coverage)
artifacts = [coverage.parse_covered_json_arg(value) for value in sys.argv[2:]]
count = coverage.write_canonical_coverage_json(
    coverage.merge_covered_sets(artifacts),
    Path(os.environ["FKST_LUA_COVERAGE_MERGED_OUTPUT"]),
    root,
)
print(f"wrote {count} file(s) to {os.environ['FKST_LUA_COVERAGE_MERGED_OUTPUT']}")
PY
  if [ ! -f "$output" ]; then
    echo "error: Lua coverage ratchet did not write coverage artifact: $output" >&2
    return 1
  fi
  FKST_LUA_COVERAGE_JSON="$output" python3 -B "$ROOT/scripts/check_repo.py"
}

check_test_file_coverage() {
  local report_dir="$1" expected actual missing
  expected="$(mktemp "${TMPDIR:-/tmp}/fkst-test-files-expected.XXXXXX")"
  actual="$(mktemp "${TMPDIR:-/tmp}/fkst-test-files-actual.XXXXXX")"
  missing="$(mktemp "${TMPDIR:-/tmp}/fkst-test-files-missing.XXXXXX")"

  (
    cd "$ROOT"
    find "$SOURCE_PACKAGES_ROOT" \( -path '*/tests/*_test.lua' -o -path '*/departments/*/*_test.lua' \) -type f -print \
      | while IFS= read -r path; do printf 'packages/%s\n' "${path#"$SOURCE_PACKAGES_ROOT"/}"; done \
      | LC_ALL=C sort -u
  ) > "$expected"

  python3 - "$report_dir" <<'PY' | LC_ALL=C sort -u > "$actual"
import json
import sys
from pathlib import Path

report_dir = Path(sys.argv[1])
for report_path in sorted(report_dir.glob("*.json")):
    with report_path.open(encoding="utf-8") as handle:
        report = json.load(handle)
    if report.get("schema") != "fkst.test.report.v1":
        raise SystemExit(f"bad test report schema in {report_path}: {report.get('schema')!r}")
    summary = report.get("summary")
    if not isinstance(summary, dict):
        raise SystemExit(f"missing test report summary in {report_path}")
    if int(summary.get("failed", 0)) != 0:
        raise SystemExit(f"test report contains failures in {report_path}")
    for test in report.get("tests", []):
        if not isinstance(test, dict) or test.get("status") != "pass":
            continue
        owner = test.get("owner_namespace")
        file_name = test.get("file")
        if not isinstance(owner, str) or not isinstance(file_name, str):
            continue
        if not (file_name.startswith("tests/") or file_name.startswith("departments/")) or not file_name.endswith("_test.lua"):
            continue
        print(f"packages/{owner}/{file_name}")
PY

  comm -23 "$expected" "$actual" > "$missing"
  if [ -s "$missing" ]; then
    local_iteration_result_fail "SEMANTIC"
    echo "error: G5 engine test coverage failed; these *_test.lua files produced zero report-json pass results:" >&2
    sed 's/^/  /' "$missing" >&2
    echo "  Each *_test.lua must contribute at least one real engine-enumerated top-level test." >&2
    rm -f "$expected" "$actual" "$missing"
    return 1
  fi

  rm -f "$expected" "$actual" "$missing"
  echo "OK: G5 every *_test.lua produced an engine report-json pass"
}
