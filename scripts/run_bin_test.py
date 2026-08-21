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
        self.package_root = self.root / "fkst-packages"
        (self.package_root / ".fkst").mkdir(parents=True)
        (self.package_root / ".fkst" / "substrate-ref").write_text(
            "fixture-pin\n", encoding="utf-8"
        )
        self.init_git(self.package_root, ".fkst/substrate-ref", "fixture package pin")
        self.substrate = self.root / "fkst-substrate"
        (self.substrate / "target" / "debug").mkdir(parents=True)
        (self.substrate / "Cargo.toml").write_text("[workspace]\n", encoding="utf-8")
        (self.substrate / ".gitignore").write_text("target/\n", encoding="utf-8")
        self.init_git(self.substrate, "Cargo.toml", ".gitignore", "fixture engine source")
        subprocess.run(["git", "branch", "fixture-pin"], cwd=self.substrate, check=True)
        self.framework = self.substrate / "target" / "debug" / "fkst-framework"
        write_executable(self.framework, "#!/bin/sh\n")
        self.log = self.root / "cargo.log"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @staticmethod
    def init_git(root: Path, *tracked_and_message: str) -> None:
        *tracked, message = tracked_and_message
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Test User"], cwd=root, check=True)
        subprocess.run(["git", "add", *tracked], cwd=root, check=True)
        subprocess.run(["git", "commit", "--quiet", "-m", message], cwd=root, check=True)

    def write_cargo(self, directory: Path) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        cargo = directory / "cargo"
        write_executable(
            cargo,
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\n' "$*" > "$FKST_TEST_CARGO_LOG"
                manifest=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "--manifest-path" ]; then manifest="$2"; break; fi
                  shift
                done
                checkout="${manifest%/Cargo.toml}"
                target="${CARGO_TARGET_DIR:-$checkout/target}"
                mkdir -p "$target/debug"
                cp "$FKST_TEST_FRAMEWORK_SOURCE" "$target/debug/fkst-framework"
                chmod +x "$target/debug/fkst-framework"
                """
            ),
        )
        return cargo

    def run_resolution(self, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        script = textwrap.dedent(
            f"""\
            set -euo pipefail
            ROOT={shlex.quote(str(self.package_root))}
            source {shlex.quote(str(BIN_BOOTSTRAP))}
            source {shlex.quote(str(RUN_BIN))}
            local_iteration_result_fail() {{ :; }}
            BIN={shlex.quote(str(self.framework))}
            resolve_bin
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
        env["FKST_TEST_FRAMEWORK_SOURCE"] = str(self.framework)
        return env

    def test_resolution_build_uses_carried_cargo_with_launchd_path(self) -> None:
        carried_cargo = self.write_cargo(self.root / "carried-tools")
        env = self.base_env()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["FKST_CARGO"] = str(carried_cargo)

        result = self.run_resolution(env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8").strip(),
            f"build --manifest-path {self.substrate.resolve()}/Cargo.toml -p fkst-framework",
        )
        self.assertNotIn("falling back to cargo from PATH", result.stderr)

    def test_resolution_build_uses_cargo_from_path_without_carried_cargo(self) -> None:
        ambient_dir = self.root / "ambient-tools"
        self.write_cargo(ambient_dir)
        env = self.base_env()
        env["PATH"] = f"{ambient_dir}:/usr/bin:/bin:/usr/sbin:/sbin"

        result = self.run_resolution(env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.log.exists())
        self.assertNotIn("freshness build", result.stderr)


if __name__ == "__main__":
    unittest.main()
