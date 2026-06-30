#!/usr/bin/env python3
"""Behavior tests for scripts/host_profile.sh."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def shell_quote(value: str | Path) -> str:
    text = str(value)
    return "'" + text.replace("'", "'\\''") + "'"


class HostProfileHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.host = self.root / "host"
        self.platform = self.root / "platform"
        self.local_packages = self.host / ".fkst" / "local-packages"
        self.profile_dir = self.root / "profiles"
        self.profile_dir.mkdir()
        self.host.mkdir()
        self.platform.mkdir()
        self.local_packages.mkdir(parents=True)

    def close(self) -> None:
        self.tmp.cleanup()

    def run_helper(self, body: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", "-c", body],
            cwd=REPO_ROOT,
            env=os.environ.copy(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def write_profile(self, name: str, body: str) -> Path:
        path = self.profile_dir / f"{name}.env"
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        return path


class HostProfileTest(unittest.TestCase):
    def test_named_profile_delegates_to_host_entry(self) -> None:
        h = HostProfileHarness()
        try:
            h.write_profile(
                "dogfood",
                f"""\
                FKST_HOST_ROOT={h.host}
                FKST_PLATFORM_ROOT={h.platform}
                FKST_LOCAL_PACKAGES={h.local_packages}
                FKST_GITHUB_REPO=ChronoAIProject/fkst-packages
                """,
            )
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host() {{ printf '%s\\n' "$@"; }}
                    cmd_host_profile --profile-dir {shell_quote(h.profile_dir)} dogfood -- check
                    printf 'repo=%s\\n' "$FKST_GITHUB_REPO"
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    f"host_profile={h.profile_dir / 'dogfood.env'}",
                    "--host-root",
                    str(h.host),
                    "--platform-root",
                    str(h.platform),
                    "--local-packages",
                    str(h.local_packages),
                    "--",
                    "check",
                    "repo=ChronoAIProject/fkst-packages",
                ],
            )
        finally:
            h.close()

    def test_supervise_gets_runtime_and_durable_defaults_from_profile(self) -> None:
        h = HostProfileHarness()
        runtime = h.root / "runtime"
        durable = h.root / "durable"
        try:
            profile = h.write_profile(
                "dogfood",
                f"""\
                FKST_HOST_ROOT={h.host}
                FKST_PLATFORM_ROOT={h.platform}
                FKST_RUNTIME_ROOT={runtime}
                FKST_DURABLE_ROOT={durable}
                """,
            )
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host() {{ printf '%s\\n' "$@"; }}
                    cmd_host_profile --file {shell_quote(profile)} -- supervise --restart
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    f"host_profile={profile}",
                    "--host-root",
                    str(h.host),
                    "--platform-root",
                    str(h.platform),
                    "--",
                    "supervise",
                    "--durable-root",
                    str(durable),
                    "--runtime-root",
                    str(runtime),
                    "--restart",
                ],
            )
        finally:
            h.close()

    def test_explicit_supervise_roots_override_profile_defaults(self) -> None:
        h = HostProfileHarness()
        runtime = h.root / "profile-runtime"
        durable = h.root / "profile-durable"
        explicit_runtime = h.root / "explicit-runtime"
        explicit_durable = h.root / "explicit-durable"
        try:
            profile = h.write_profile(
                "dogfood",
                f"""\
                FKST_HOST_ROOT={h.host}
                FKST_RUNTIME_ROOT={runtime}
                FKST_DURABLE_ROOT={durable}
                """,
            )
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host() {{ printf '%s\\n' "$@"; }}
                    cmd_host_profile --file {shell_quote(profile)} -- supervise --durable-root {shell_quote(explicit_durable)} --runtime-root {shell_quote(explicit_runtime)}
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertIn(str(explicit_durable), lines)
            self.assertIn(str(explicit_runtime), lines)
            self.assertNotIn(str(durable), lines)
            self.assertNotIn(str(runtime), lines)
        finally:
            h.close()

    def test_profile_rejects_non_contract_keys(self) -> None:
        h = HostProfileHarness()
        try:
            profile = h.write_profile(
                "bad",
                f"""\
                FKST_HOST_ROOT={h.host}
                PATH=/tmp/unsafe
                """,
            )
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host_profile --file {shell_quote(profile)} -- check
                    """
                )
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("key is outside the host-profile contract: PATH", result.stderr)
        finally:
            h.close()

    def test_init_scaffolds_profile_in_config_dir(self) -> None:
        h = HostProfileHarness()
        try:
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host_profile init --profile-dir {shell_quote(h.profile_dir)} dogfood
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            profile = h.profile_dir / "dogfood.env"
            self.assertTrue(profile.is_file())
            text = profile.read_text(encoding="utf-8")
            self.assertIn("FKST_HOST_ROOT=/path/to/host-repo", text)
            self.assertIn("FKST_DURABLE_ROOT=/path/to/global/durable-store", text)
            self.assertIn(f"wrote host profile scaffold: {profile}", result.stdout)
        finally:
            h.close()

    def test_invalid_profile_name_fails_closed(self) -> None:
        h = HostProfileHarness()
        try:
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/run.sh
                    cmd_host_profile --profile-dir {shell_quote(h.profile_dir)} ../bad -- check
                    """
                )
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid host profile name", result.stderr)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
