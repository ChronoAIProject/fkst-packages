#!/usr/bin/env python3
"""Unit tests for repository guard helpers."""

from __future__ import annotations

import importlib.util
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


def load_resolve_substrate_ref():
    path = Path(__file__).with_name("resolve_substrate_ref.py")
    spec = importlib.util.spec_from_file_location("resolve_substrate_ref", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load resolve_substrate_ref.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


resolve_substrate_ref = load_resolve_substrate_ref()


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


class SubstrateRefParseTest(unittest.TestCase):
    def test_defaults_blank_pin(self) -> None:
        self.assertEqual(
            resolve_substrate_ref.parse_pin(""),
            ("ChronoAIProject/fkst-substrate", "dev"),
        )

    def test_short_ref_uses_default_repository(self) -> None:
        self.assertEqual(
            resolve_substrate_ref.parse_pin(" dev\n"),
            ("ChronoAIProject/fkst-substrate", "dev"),
        )

    def test_owner_repo_ref_pin(self) -> None:
        self.assertEqual(
            resolve_substrate_ref.parse_pin("ChronoAIProject/fkst-substrate@dev"),
            ("ChronoAIProject/fkst-substrate", "dev"),
        )

    def test_other_repository_pin_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            resolve_substrate_ref.parse_pin("ExampleOrg/fkst-substrate@dev")

    def test_invalid_repository_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            resolve_substrate_ref.parse_pin("https://github.com/ChronoAIProject/fkst-substrate@dev")

    def test_path_segment_repository_is_rejected(self) -> None:
        invalid_pins = [
            "./fkst-substrate@dev",
            "../fkst-substrate@dev",
            "ChronoAIProject/.@dev",
            "ChronoAIProject/..@dev",
            "ChronoAIProject/../fkst-substrate@dev",
        ]
        for pin in invalid_pins:
            with self.subTest(pin=pin):
                with self.assertRaises(ValueError):
                    resolve_substrate_ref.parse_pin(pin)


if __name__ == "__main__":
    unittest.main()
