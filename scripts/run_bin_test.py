#!/usr/bin/env python3
"""Behavior tests for scripts/run_bin.sh."""

from __future__ import annotations

import os
import shlex
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BIN_BOOTSTRAP = REPO_ROOT / "scripts" / "bin_bootstrap.sh"
RUN_BIN = REPO_ROOT / "scripts" / "run_bin.sh"


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class RunBinTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.substrate = self.root / "fkst-substrate"
        (self.substrate / ".git").mkdir(parents=True)
        (self.substrate / "target" / "debug").mkdir(parents=True)
        (self.substrate / "Cargo.toml").write_text("[workspace]\n", encoding="utf-8")
        self.framework = self.substrate / "target" / "debug" / "fkst-framework"
        write_executable(self.framework, "#!/bin/sh\n")
        self.log = self.root / "cargo.log"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write_cargo(self, directory: Path) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        cargo = directory / "cargo"
        write_executable(
            cargo,
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\n' "$*" > "$FKST_TEST_CARGO_LOG"
                """
            ),
        )
        return cargo

    def run_freshness_build(self, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        script = textwrap.dedent(
            f"""\
            set -euo pipefail
            ROOT={shlex.quote(str(REPO_ROOT))}
            source {shlex.quote(str(BIN_BOOTSTRAP))}
            source {shlex.quote(str(RUN_BIN))}
            local_iteration_result_fail() {{ :; }}
            BIN={shlex.quote(str(self.framework))}
            ensure_fresh_bin
            """
        )
        return subprocess.run(
            ["/bin/bash", "-c", script],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def base_env(self) -> dict[str, str]:
        env = os.environ.copy()
        for name in ("CI", "GITHUB_ACTIONS", "FKST_CARGO", "FKST_NO_AUTOBUILD"):
            env.pop(name, None)
        env["FKST_TEST_CARGO_LOG"] = str(self.log)
        return env

    def test_freshness_build_uses_carried_cargo_with_launchd_path(self) -> None:
        carried_cargo = self.write_cargo(self.root / "carried-tools")
        env = self.base_env()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["FKST_CARGO"] = str(carried_cargo)

        result = self.run_freshness_build(env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8").strip(),
            f"build --manifest-path {self.substrate.resolve()}/Cargo.toml -p fkst-framework",
        )
        self.assertNotIn("falling back to cargo from PATH", result.stderr)

    def test_missing_carried_cargo_warns_before_path_fallback(self) -> None:
        ambient_dir = self.root / "ambient-tools"
        self.write_cargo(ambient_dir)
        env = self.base_env()
        env["PATH"] = f"{ambient_dir}:/usr/bin:/bin:/usr/sbin:/sbin"

        result = self.run_freshness_build(env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.log.exists())
        self.assertIn("FKST_CARGO is not set; falling back to cargo from PATH", result.stderr)


if __name__ == "__main__":
    unittest.main()
