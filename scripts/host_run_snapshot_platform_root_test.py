#!/usr/bin/env python3
"""A platform snapshot is a different tree of one repository, and must be admitted.

The operator launches supervise from an immutable snapshot of the captured platform
commit rather than from the mutable checkout, so `--platform-root` legitimately differs
from `--project-root` by path while being the same repository. Admitting only equal
paths rejects that and blocks every launch.
"""

from __future__ import annotations

import subprocess
import textwrap
import unittest

from host_run_fixture import HostRunHarness, shell_quote


def _clone(source, destination) -> None:
    subprocess.run(
        ["git", "clone", "--quiet", str(source), str(destination)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


class HostRunSnapshotPlatformRootTest(unittest.TestCase):
    def _build(self, harness: HostRunHarness, platform_root):
        return harness.run_helper(
            textwrap.dedent(
                f"""\
                set -euo pipefail
                source scripts/host_run.sh
                host_run_parse_supervise_args \
                  --project-root {shell_quote(harness.packages_host)} \
                  --platform-root {shell_quote(platform_root)} \
                  --platform-packages 'github-proxy' \
                  --durable-root {shell_quote(harness.durable)} \
                  --runtime-root {shell_quote(harness.runtime)}
                host_run_validate_shape
                host_run_build_package_roots
                """
            )
        )

    def test_a_snapshot_of_the_project_repository_is_admitted(self) -> None:
        h = HostRunHarness()
        try:
            h.write_workspace_manifest(root=h.packages_host, workspace_units=["packages/*"])
            snapshot = h.root / "platform-snapshot"
            _clone(h.packages_host, snapshot)
            result = self._build(h, snapshot)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("requires trusted --platform-root", result.stderr)
        finally:
            h.close()

    def test_an_unrelated_repository_is_still_refused(self) -> None:
        h = HostRunHarness()
        try:
            h.write_workspace_manifest(root=h.packages_host, workspace_units=["packages/*"])
            result = self._build(h, h.platform)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires trusted --platform-root", result.stderr)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
