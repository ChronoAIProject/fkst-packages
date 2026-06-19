#!/usr/bin/env python3
"""Behavior tests for scripts/run.sh Lua coverage self-test wiring."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunShCoverageHarness:
    def __init__(self, bin_body: str) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.runtime = self.root / "runtime"
        self.mini_repo = self.root / "mini-repo"
        self.mini_repo_scripts = self.mini_repo / "scripts"
        self.mini_repo_scripts.mkdir(parents=True)
        self.argv_log = self.root / "argv.log"
        self.framework = self.root / "fkst-framework"
        write_executable(
            self.mini_repo_scripts / "check_repo.py",
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import os
                from pathlib import Path

                with open(os.environ["RUN_SH_COVERAGE_ARGV_LOG"], "a", encoding="utf-8") as handle:
                    handle.write("CHECK_REPO=" + os.environ.get("FKST_LUA_COVERAGE_JSON", "") + "\\n")
                    coverage = os.environ.get("FKST_LUA_COVERAGE_JSON")
                    if coverage:
                        handle.write(Path(coverage).read_text(encoding="utf-8"))
                raise SystemExit(0)
                """
            ),
        )
        write_executable(self.framework, bin_body)

    def close(self) -> None:
        self.tmp.cleanup()

    def run_shell(self, script: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["BIN"] = str(self.framework)
        env["FKST_RUNTIME_ROOT"] = str(self.runtime)
        env["RUN_SH_COVERAGE_ARGV_LOG"] = str(self.argv_log)
        env["RUN_SH_COVERAGE_MINI_REPO"] = str(self.mini_repo)
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                textwrap.dedent(
                    f"""\
                    source scripts/run.sh
                    ROOT="$RUN_SH_COVERAGE_MINI_REPO"
                    {script}
                    """
                ),
            ],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def argv_lines(self) -> list[str]:
        if not self.argv_log.exists():
            return []
        return self.argv_log.read_text(encoding="utf-8").splitlines()


class RunShCoverageSelfTest(unittest.TestCase):
    def test_self_test_passes_coverage_flag_with_directory_value(self) -> None:
        h = RunShCoverageHarness(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\\n' "$*" >> "$RUN_SH_COVERAGE_ARGV_LOG"
                if [ "$1" = "--self-test" ] && [ "$2" = "--coverage" ] && [ -n "${3:-}" ]; then
                  printf '{"files":[{"file":"packages/example/core.lua","missing_lines":[]}]}\\n' > "$3/coverage.json"
                  exit 0
                fi
                echo "unexpected argv: $*" >&2
                exit 64
                """
            )
        )
        try:
            (h.mini_repo / "packages" / "example").mkdir(parents=True)
            (h.mini_repo / "packages" / "example" / "core.lua").write_text("return {}\n", encoding="utf-8")
            result = h.run_shell("run_self_test_with_optional_lua_coverage")
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            lines = h.argv_lines()
            self.assertGreaterEqual(len(lines), 2)
            argv = lines[0].split()
            self.assertEqual(argv[0:2], ["--self-test", "--coverage"])
            self.assertEqual(argv[2], str(h.runtime / "lua-coverage"))
            self.assertEqual(lines[1], f"CHECK_REPO={h.runtime / 'lua-coverage' / 'coverage.json'}")
        finally:
            h.close()

    def test_empty_self_test_artifact_requests_package_fallback_without_check_repo(self) -> None:
        h = RunShCoverageHarness(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\\n' "$*" >> "$RUN_SH_COVERAGE_ARGV_LOG"
                if [ "$1" = "--self-test" ] && [ "$2" = "--coverage" ] && [ -n "${3:-}" ]; then
                  printf '{}\\n' > "$3/coverage.json"
                  exit 0
                fi
                echo "unexpected argv: $*" >&2
                exit 64
                """
            )
        )
        try:
            result = h.run_shell(
                "run_self_test_with_optional_lua_coverage; "
                'test "${LUA_COVERAGE_NEEDS_PACKAGE_FALLBACK:-0}" = "1"'
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.argv_lines(), [f"--self-test --coverage {h.runtime / 'lua-coverage'}"])
            self.assertIn("wrote no Lua line metadata", result.stderr)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
