#!/usr/bin/env python3
"""Source identity validation tests for scripts/host_run.sh."""

from __future__ import annotations

import unittest

from host_run_fixture import HostRunHarness, commit_git_file, create_git_source


SOURCE_ID = "fkst-packages-platform"


class HostRunSourceIdentityTest(unittest.TestCase):
    def assert_duplicate_error(
        self,
        result,
        *,
        first_location: str,
        second_location: str,
    ) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"duplicate source id '{SOURCE_ID}'", result.stderr)
        self.assertIn(first_location, result.stderr)
        self.assertIn(second_location, result.stderr)

    def test_duplicate_workspace_source_id_fails_closed(self) -> None:
        for variant in ("identical", "conflicting"):
            with self.subTest(variant=variant):
                h = HostRunHarness()
                try:
                    first_repo, first_rev = create_git_source(
                        h.root,
                        f"workspace-{variant}-first",
                        {"packages/github-proxy/fkst.toml": 'kind = "package"\nname = "github-proxy"\n'},
                    )
                    second_repo = first_repo
                    second_rev = first_rev
                    if variant == "conflicting":
                        second_repo, second_rev = create_git_source(
                            h.root,
                            "workspace-conflicting-second",
                            {"packages/github-proxy/fkst.toml": 'kind = "package"\nname = "github-proxy"\n'},
                        )
                    h.write_workspace_manifest(
                        external_sources=[
                            (SOURCE_ID, first_repo, ["github-proxy"]),
                            (SOURCE_ID, second_repo, ["github-proxy"]),
                        ]
                    )
                    h.write_external_sources_lock([(SOURCE_ID, second_repo, second_rev)])

                    result = h.package_roots(
                        [
                            "--project-root",
                            str(h.website_host),
                            "--platform-root",
                            str(second_repo),
                            "--platform-packages",
                            "github-proxy",
                            "--durable-root",
                            str(h.durable),
                            "--runtime-root",
                            str(h.runtime),
                        ]
                    )

                    self.assert_duplicate_error(
                        result,
                        first_location="fkst.workspace.toml external_sources[1]",
                        second_location="fkst.workspace.toml external_sources[2]",
                    )
                finally:
                    h.close()

    def test_duplicate_lock_source_id_fails_closed(self) -> None:
        for variant in ("identical", "conflicting"):
            with self.subTest(variant=variant):
                h = HostRunHarness()
                try:
                    platform_repo, first_rev = create_git_source(
                        h.root,
                        f"lock-{variant}-source",
                        {"packages/github-proxy/fkst.toml": 'kind = "package"\nname = "github-proxy"\n'},
                    )
                    second_rev = first_rev
                    if variant == "conflicting":
                        second_rev = commit_git_file(platform_repo, "second.txt", "second revision\n")
                    h.write_workspace_manifest(
                        external_sources=[(SOURCE_ID, platform_repo, ["github-proxy"])]
                    )
                    h.write_external_sources_lock(
                        [
                            (SOURCE_ID, platform_repo, first_rev),
                            (SOURCE_ID, platform_repo, second_rev),
                        ]
                    )

                    result = h.package_roots(
                        [
                            "--project-root",
                            str(h.website_host),
                            "--platform-root",
                            str(platform_repo),
                            "--platform-packages",
                            "github-proxy",
                            "--durable-root",
                            str(h.durable),
                            "--runtime-root",
                            str(h.runtime),
                        ]
                    )

                    self.assert_duplicate_error(
                        result,
                        first_location="fkst.lock external_source[1]",
                        second_location="fkst.lock external_source[2]",
                    )
                finally:
                    h.close()


if __name__ == "__main__":
    unittest.main()
