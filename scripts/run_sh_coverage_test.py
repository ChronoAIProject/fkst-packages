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
    def test_self_test_runs_without_coverage_flag(self) -> None:
        h = RunShCoverageHarness(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\\n' "$*" >> "$RUN_SH_COVERAGE_ARGV_LOG"
                if [ "$1" = "--self-test" ] && [ "$#" -eq 1 ]; then
                  exit 0
                fi
                echo "unexpected argv: $*" >&2
                exit 64
                """
            )
        )
        try:
            result = h.run_shell("run_self_test")
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(len(h.argv_lines()), 1)
            argv = h.argv_lines()[0].split()
            self.assertEqual(argv, ["--self-test"])
        finally:
            h.close()

    def test_coverage_artifact_merges_package_paths_and_checks_canonical_env(self) -> None:
        h = RunShCoverageHarness(
            textwrap.dedent(
                """\
                #!/bin/sh
                echo "framework must not run" >&2
                exit 64
                """
            )
        )
        try:
            (h.mini_repo / "packages" / "example").mkdir(parents=True)
            (h.mini_repo / "packages" / "example" / "core.lua").write_text("return {}\n", encoding="utf-8")
            (h.mini_repo / "packages" / "example" / "unused.lua").write_text("return {}\n", encoding="utf-8")
            (h.mini_repo / "std").mkdir()
            (h.mini_repo / "std" / "shared.lua").write_text("return {}\n", encoding="utf-8")
            first = h.root / "first.json"
            second = h.root / "second.json"
            output = h.root / "merged" / "coverage.json"
            first.write_text(
                '{"core.lua":{"covered_lines":[2,1]},"std/shared.lua":{"covered_lines":[3]}}',
                encoding="utf-8",
            )
            second.write_text(
                '{"core.lua":{"covered_lines":[3]},"packages/other/core.lua":{"covered_lines":[4]}}',
                encoding="utf-8",
            )

            result = h.run_shell(
                f'write_lua_coverage_artifact "{output}" "example={first}" "example={second}"; '
                f'check_lua_coverage_artifact "{output}"'
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            lines = h.argv_lines()
            self.assertEqual(lines[0], f"CHECK_REPO={output}")
            merged = "\n".join(lines[1:])
            self.assertIn('"packages/example/core.lua"', merged)
            self.assertIn('"covered_lines": [', merged)
            self.assertIn('"packages/example/unused.lua"', merged)
            self.assertIn('"covered_lines": []', merged)
            self.assertIn('"std/shared.lua"', merged)
            self.assertIn('"packages/other/core.lua"', merged)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
