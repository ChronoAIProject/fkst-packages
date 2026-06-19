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
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
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
                pwd >> "$RUN_SH_COVERAGE_ARGV_LOG"
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
            self.assertEqual(len(h.argv_lines()), 2)
            argv = h.argv_lines()[0].split()
            self.assertEqual(argv, ["--self-test"])
            self.assertEqual(h.argv_lines()[1], str(h.mini_repo))
        finally:
            h.close()

    def test_lua_coverage_ratchet_passes_covered_json_arguments(self) -> None:
        h = RunShCoverageHarness(
            textwrap.dedent(
                """\
                #!/bin/sh
                echo "framework must not run" >&2
                exit 64
                """
            )
        )
        check_repo = h.mini_repo_scripts / "check_repo_coverage.py"
        write_executable(
            check_repo,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import os
                import sys
                with open(os.environ["RUN_SH_COVERAGE_ARGV_LOG"], "a", encoding="utf-8") as handle:
                    handle.write(" ".join(sys.argv[1:]) + "\\n")
                    handle.write(os.environ.get("FKST_LUA_COVERAGE_JSON", "") + "\\n")
                raise SystemExit(0)
                """
            ),
        )
        try:
            result = h.run_shell('run_lua_coverage_ratchet --covered-json "pkg=/tmp/pkg-coverage.json"')
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.argv_lines(), ["--covered-json pkg=/tmp/pkg-coverage.json", "1"])
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
