#!/usr/bin/env python3
"""Behavior tests for scripts/host_run.sh."""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class HostRunHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.packages_host = self.root / "packages-host"
        self.substrate_host = self.root / "substrate-host"
        self.website_host = self.root / "website-host"
        self.platform = self.root / "platform"
        self.durable = self.root / "durable"
        self.runtime = self.root / "runtime"
        for pkg in ("github-proxy", "consensus"):
            (self.platform / "packages" / pkg).mkdir(parents=True, exist_ok=True)
            (self.packages_host / "packages" / pkg).mkdir(parents=True, exist_ok=True)
        (self.packages_host / "packages" / "autochrono").mkdir(parents=True)
        (self.website_host / ".fkst" / "local-packages" / "site-board").mkdir(parents=True)
        self.substrate_host.mkdir()

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

    def package_roots(self, command_args: list[str]) -> subprocess.CompletedProcess[str]:
        quoted = " ".join(shell_quote(arg) for arg in command_args)
        return self.run_helper(
            textwrap.dedent(
                f"""\
                set -euo pipefail
                source scripts/host_run.sh
                host_run_parse_supervise_args {quoted}
                host_run_validate_shape
                host_run_build_package_roots
                host_run_print_package_roots
                """
            )
        )


def shell_quote(value: str | Path) -> str:
    text = str(value)
    return "'" + text.replace("'", "'\\''") + "'"


class HostRunTest(unittest.TestCase):
    def test_packages_host_uses_project_packages_for_host_packages(self) -> None:
        h = HostRunHarness()
        try:
            result = h.package_roots(
                [
                    "--project-root",
                    str(h.packages_host),
                    "--platform-root",
                    str(h.packages_host),
                    "--platform-packages",
                    "github-proxy consensus",
                    "--host-packages",
                    "autochrono",
                    "--durable-root",
                    str(h.durable),
                    "--runtime-root",
                    str(h.runtime),
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    str(h.packages_host / "packages" / "github-proxy"),
                    str(h.packages_host / "packages" / "consensus"),
                    str(h.packages_host / "packages" / "autochrono"),
                ],
            )
        finally:
            h.close()

    def test_substrate_host_has_only_platform_packages(self) -> None:
        h = HostRunHarness()
        try:
            result = h.package_roots(
                [
                    "--project-root",
                    str(h.substrate_host),
                    "--platform-root",
                    str(h.platform),
                    "--platform-packages",
                    "github-proxy consensus",
                    "--durable-root",
                    str(h.durable),
                    "--runtime-root",
                    str(h.runtime),
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    str(h.platform / "packages" / "github-proxy"),
                    str(h.platform / "packages" / "consensus"),
                ],
            )
        finally:
            h.close()

    def test_website_host_uses_fkst_local_packages_for_host_packages(self) -> None:
        h = HostRunHarness()
        try:
            result = h.package_roots(
                [
                    "--project-root",
                    str(h.website_host),
                    "--platform-root",
                    str(h.platform),
                    "--platform-packages",
                    "github-proxy consensus",
                    "--host-packages",
                    "site-board",
                    "--durable-root",
                    str(h.durable),
                    "--runtime-root",
                    str(h.runtime),
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    str(h.platform / "packages" / "github-proxy"),
                    str(h.platform / "packages" / "consensus"),
                    str(h.website_host / ".fkst" / "local-packages" / "site-board"),
                ],
            )
        finally:
            h.close()

    def test_missing_durable_root_fails_closed(self) -> None:
        h = HostRunHarness()
        try:
            result = h.package_roots(
                [
                    "--project-root",
                    str(h.substrate_host),
                    "--platform-root",
                    str(h.platform),
                    "--platform-packages",
                    "github-proxy",
                    "--runtime-root",
                    str(h.runtime),
                ]
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--durable-root is required", result.stderr)
        finally:
            h.close()

    def test_restart_kills_pid_file_supervise_process_for_same_project(self) -> None:
        h = HostRunHarness()
        sleeper = subprocess.Popen(
            [
                "/bin/sh",
                "-c",
                "exec -a 'fkst-framework supervise --project-root "
                + str(h.substrate_host)
                + " --package-root x' sleep 60",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            h.durable.mkdir()
            (h.durable / ".fkst-supervise.pid").write_text(str(sleeper.pid) + "\n", encoding="utf-8")
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/host_run.sh
                    host_run_parse_supervise_args --project-root {shell_quote(h.substrate_host)} --platform-root {shell_quote(h.platform)} --platform-packages 'github-proxy' --durable-root {shell_quote(h.durable)} --runtime-root {shell_quote(h.runtime)} --restart
                    host_run_validate_shape
                    host_run_restart_prior
                    """
                )
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            for _ in range(20):
                if sleeper.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertIsNotNone(sleeper.poll())
            self.assertIn("killing prior supervise pid", result.stderr)
        finally:
            if sleeper.poll() is None:
                sleeper.send_signal(signal.SIGKILL)
                sleeper.wait(timeout=5)
            h.close()


if __name__ == "__main__":
    unittest.main()
