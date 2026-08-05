#!/usr/bin/env python3
"""Tests for shared repository-checker configuration helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_repo_config
import check_repo_content_truncation as content_truncation
import check_repo_dept_failure_surface as dept_failure_surface
import check_repo_hidden_state as hidden_state
import check_repo_monotone_gate as monotone_gate
import check_repo_producer_liveness as producer_liveness
import check_repo_saga_handler as saga_handler
import check_repo_saga_split as saga_split
import check_repo_version_suffix as version_suffix


class AllowlistAtDevBaseTest(unittest.TestCase):
    def call(self, parser, *, catch_errors: bool = True):
        kwargs = {}
        if not catch_errors:
            kwargs["catch_errors"] = False
        return check_repo_config.allowlist_at_dev_base(
            Path("/repo"),
            allowlist="migration/example.allowlist",
            parse_allowlist_lines=parser,
            **kwargs,
        )

    def test_present_content_uses_parser_and_preserves_set_type(self) -> None:
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("present", "alpha\nbeta\n"),
        ):
            status, parsed = self.call(set)

        self.assertEqual(status, "present")
        self.assertEqual(parsed, {"alpha", "beta"})
        self.assertIs(type(parsed), set)

    def test_present_content_preserves_ordered_list_type(self) -> None:
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("present", "alpha\nbeta\n"),
        ):
            status, parsed = self.call(list)

        self.assertEqual(status, "present")
        self.assertEqual(parsed, ["alpha", "beta"])
        self.assertIs(type(parsed), list)

    def test_absent_file_returns_none_without_parsing(self) -> None:
        parser = mock.Mock(side_effect=AssertionError("parser must not run"))
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("absent", None),
        ):
            self.assertEqual(self.call(parser), ("absent", None))

        parser.assert_not_called()

    def test_unresolved_base_returns_none_without_parsing(self) -> None:
        parser = mock.Mock(side_effect=AssertionError("parser must not run"))
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("unresolved", None),
        ):
            self.assertEqual(self.call(parser), ("unresolved", None))

        parser.assert_not_called()

    def test_parser_exception_becomes_unresolved_by_default(self) -> None:
        parser = mock.Mock(side_effect=ValueError("invalid typed entry"))
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("present", "invalid\n"),
        ):
            self.assertEqual(self.call(parser), ("unresolved", None))

    def test_retrieval_exception_becomes_unresolved_by_default(self) -> None:
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            side_effect=RuntimeError("git failed"),
        ):
            self.assertEqual(self.call(set), ("unresolved", None))

    def test_error_propagation_mode_preserves_checker_behavior(self) -> None:
        parser = mock.Mock(side_effect=ValueError("invalid typed entry"))
        with mock.patch.object(
            check_repo_config.ratchet_base,
            "file_at_base",
            return_value=("present", "invalid\n"),
        ):
            with self.assertRaisesRegex(ValueError, "invalid typed entry"):
                self.call(parser, catch_errors=False)

    def test_migrated_parsers_preserve_collection_and_element_types(self) -> None:
        cases = (
            (
                "content-truncation",
                content_truncation.parse_dev_allowlist_lines,
                "packages/example/core.lua|proposal_body|max_body_len|raise-payload|issue=#1|why=legacy cap",
                set,
                content_truncation.ContentTruncationSite,
            ),
            (
                "department-failure",
                dept_failure_surface.parse_allowlist_lines,
                "example.worker|issue=#1|why=missing retry",
                set,
                str,
            ),
            (
                "hidden-state",
                hidden_state.parse_dev_allowlist_lines,
                "github-devloop|ready|dependency-gate|implementing|issue=#1|why=existing debt",
                set,
                hidden_state.HiddenStateKey,
            ),
            (
                "monotone-gate",
                monotone_gate.parse_dev_allowlist_lines,
                "packages/example/core.lua|route|cursor-read|current_entity_state(|line=1|issue=#1|why=existing debt",
                list,
                monotone_gate.Violation,
            ),
            (
                "producer-liveness",
                producer_liveness.parse_dev_allowlist_lines,
                "example.poll",
                set,
                str,
            ),
            (
                "saga-handler",
                saga_handler.parse_dev_allowlist_lines,
                "packages/example/departments/worker/main.lua",
                set,
                str,
            ),
            (
                "saga-split",
                saga_split.parse_dev_allowlist_lines,
                saga_split.LeakSite(
                    "packages/github-devloop/core/entity.lua",
                    "linked-state-promotion",
                    "linked-pr-comments",
                    1,
                ).allowlist_line("existing debt"),
                set,
                saga_split.LeakSite,
            ),
            (
                "version-suffix",
                version_suffix.parse_dev_allowlist_lines,
                "libraries/contract/source_ref.lua:1 # why=existing parser debt",
                set,
                version_suffix.VersionSuffixAllowlistEntry,
            ),
        )

        for name, parser, line, collection_type, element_type in cases:
            with self.subTest(name=name):
                with mock.patch.object(
                    check_repo_config.ratchet_base,
                    "file_at_base",
                    return_value=("present", f"# comment\n{line}\n"),
                ):
                    status, parsed = check_repo_config.allowlist_at_dev_base(
                        Path("/repo"),
                        allowlist="migration/example.allowlist",
                        parse_allowlist_lines=parser,
                    )

                self.assertEqual(status, "present")
                self.assertIs(type(parsed), collection_type)
                self.assertEqual(len(parsed), 1)
                self.assertIsInstance(next(iter(parsed)), element_type)


if __name__ == "__main__":
    unittest.main()
