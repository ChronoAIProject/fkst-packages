#!/usr/bin/env python3
"""Unit tests for repository guard helpers."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


def load_check_repo():
    path = Path(__file__).with_name("check_repo.py")
    spec = importlib.util.spec_from_file_location("check_repo", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load check_repo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


check_repo = load_check_repo()
ROOT = Path(__file__).resolve().parents[1]


class GraphqlConnectionGuardTest(unittest.TestCase):
    def warning_lines(self, source: str) -> list[int]:
        return check_repo.unguarded_graphql_first_connection_lines(source)

    def test_warns_first_connection_without_guard(self) -> None:
        source = """
local query = [[
  query { repository(owner: "o", name: "r") { issues(first:10) { nodes { number } } } }
]]
"""
        self.assertEqual(self.warning_lines(source), [3])

    def test_allows_total_count_guard(self) -> None:
        source = """
local query = 'query { repository(owner:"o", name:"r") { issues(first:10) { totalCount nodes { number } } } }'
"""
        self.assertEqual(self.warning_lines(source), [])

    def test_allows_page_info_has_next_page_guard(self) -> None:
        source = """
local query = 'query { repository(owner:"o", name:"r") { issues(first:10) { pageInfo { hasNextPage } nodes { number } } } }'
"""
        self.assertEqual(self.warning_lines(source), [])

    def test_warns_page_info_without_has_next_page(self) -> None:
        source = """
local query = 'query { repository(owner:"o", name:"r") { issues(first:10) { pageInfo { endCursor } nodes { number } } } }'
"""
        self.assertEqual(self.warning_lines(source), [2])

    def test_ignores_comments(self) -> None:
        source = """
-- query { repository(owner:"o", name:"r") { issues(first:10) { nodes { number } } } }
local query = 'query { repository(owner:"o", name:"r") { issues(first:10) { totalCount nodes { number } } } }'
"""
        self.assertEqual(self.warning_lines(source), [])


class SubstratePinHelperTest(unittest.TestCase):
    def run_helper(self, script: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", script],
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_ref_only_matches_default_owner_repo_pin(self) -> None:
        result = self.run_helper(
            """
set -euo pipefail
source scripts/substrate_pin.sh
fkst_parse_substrate_pin dev
fkst_parse_substrate_pin ChronoAIProject/fkst-substrate@dev
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "ChronoAIProject\tfkst-substrate\tdev",
                "ChronoAIProject\tfkst-substrate\tdev",
            ],
        )

    def test_sanitizes_cache_ref_component(self) -> None:
        result = self.run_helper(
            """
set -euo pipefail
source scripts/substrate_pin.sh
fkst_sanitize_substrate_ref 'feature/bootstrap part A+review'
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "feature-bootstrap-part-A-review")

    def test_cache_path_is_deterministic_per_pin(self) -> None:
        result = self.run_helper(
            """
set -euo pipefail
source scripts/substrate_pin.sh
HOME=/tmp/fkst-home
IFS=$'\t' read -r owner repo ref < <(fkst_parse_substrate_pin 'Owner/repo@refs/heads/dev')
fkst_substrate_cache_path "$owner" "$repo" "$ref"
fkst_substrate_cache_path "$owner" "$repo" "$ref"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], lines[1])
        self.assertEqual(lines[0], "/tmp/fkst-home/.cache/fkst/substrate/Owner-repo-refs-heads-dev")

    def test_empty_pin_defaults_to_dev(self) -> None:
        result = self.run_helper(
            """
set -euo pipefail
source scripts/substrate_pin.sh
fkst_parse_substrate_pin ''
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ChronoAIProject\tfkst-substrate\tdev")

    def test_rejects_malformed_owner_repo_pin(self) -> None:
        result = self.run_helper(
            """
set -euo pipefail
source scripts/substrate_pin.sh
fkst_parse_substrate_pin 'ChronoAIProject@dev'
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid fkst-substrate pin", result.stderr)


if __name__ == "__main__":
    unittest.main()
