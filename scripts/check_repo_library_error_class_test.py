#!/usr/bin/env python3
"""Tests for the production-library error-class shrink-only ratchet."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scripts_dir = Path(__file__).resolve().parent
check_repo = load_module("check_repo", scripts_dir / "check_repo.py")
check_repo_runner = load_module("check_repo_runner", scripts_dir / "check_repo_runner.py")


class LibraryErrorClassRatchetTest(unittest.TestCase):
    @staticmethod
    def site(message: str, occurrence: int = 1) -> str:
        fingerprint = hashlib.sha256(message.encode("utf-8")).hexdigest()
        return f"libraries/example/core.lua:fingerprint={fingerprint}:occurrence={occurrence}"

    def violations_for(self, source_text: str, allowlist_text: str = "") -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text(source_text, encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            (migration / "library-error-class.allowlist").write_text(allowlist_text, encoding="utf-8")

            violations: list[str] = []
            check_repo_runner.check_library_error_class(
                check_repo,
                root,
                violations,
                enforce_base=False,
            )
            return violations

    @staticmethod
    def git(root: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.stdout.strip()

    def test_unclassified_library_error_fails(self) -> None:
        violations = self.violations_for('error("missing class")\n')
        site = self.site("missing class")

        self.assertEqual(len(violations), 1)
        self.assertEqual(
            violations[0],
            "G-LIB-ERROR-CLASS: libraries/example/core.lua:1 production library error(...) string "
            f"lacks a greppable class prefix; diagnostic identity {site} is not in "
            "migration/library-error-class.allowlist",
        )

    def test_classified_library_error_passes(self) -> None:
        violations = self.violations_for('error("example: missing-capability: adapter is required")\n')

        self.assertEqual(violations, [])

    def test_line_relocation_preserves_diagnostic_identity(self) -> None:
        site = self.site("missing class")

        violations = self.violations_for(
            'local unrelated = true\n\nerror("missing class")\n',
            f"{site}\n",
        )

        self.assertEqual(violations, [])

    def test_duplicate_diagnostics_preserve_multiplicity(self) -> None:
        first = self.site("missing class")
        second = self.site("missing class", occurrence=2)

        violations = self.violations_for(
            'error("missing class")\nerror("missing class")\n',
            f"{first}\n",
        )

        self.assertEqual(len(violations), 1)
        self.assertIn("libraries/example/core.lua:2", violations[0])
        self.assertIn(second, violations[0])

    def test_new_target_relative_diagnostic_fails_even_when_allowlisted(self) -> None:
        existing = self.site("existing debt")
        added = self.site("new debt")
        current = {
            existing: "libraries/example/core.lua:10",
            added: "libraries/example/core.lua:20",
        }
        target = {existing: "libraries/example/core.lua:4"}

        messages = check_repo.check_repo_error_class.library_ratchet_messages(
            current,
            {existing, added},
            target_sites=target,
        )

        self.assertEqual(
            messages,
            [
                "libraries/example/core.lua:20 production library error(...) string is new relative "
                f"to the target baseline; diagnostic identity {added}; "
                "classify the error string instead"
            ],
        )

    def test_git_target_comparison_ignores_relocation_and_rejects_addition(self) -> None:
        existing = self.site("existing debt")
        added = self.site("new debt")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.git(root, "init")
            self.git(root, "config", "user.email", "fkst-test@example.invalid")
            self.git(root, "config", "user.name", "fkst test")
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text('error("existing debt")\n', encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            allowlist = migration / "library-error-class.allowlist"
            allowlist.write_text(f"{existing}\n", encoding="utf-8")
            self.git(root, "add", ".")
            self.git(root, "commit", "-m", "target")
            target = self.git(root, "rev-parse", "HEAD")
            self.git(root, "update-ref", "refs/remotes/origin/dev", target)

            source.write_text(
                'local unrelated = true\n\nerror("existing debt")\nerror("new debt")\n',
                encoding="utf-8",
            )
            allowlist.write_text(f"{existing}\n{added}\n", encoding="utf-8")
            violations: list[str] = []
            with mock.patch.dict(
                "os.environ",
                {
                    "FKST_DEVLOOP_INTEGRATION_BRANCH": "",
                    "FKST_RATCHET_TARGET_REF": "",
                    "GITHUB_BASE_REF": "",
                    "GITHUB_EVENT_NAME": "",
                    "GITHUB_REF_NAME": "",
                    "GITHUB_REF_TYPE": "",
                },
            ):
                check_repo_runner.check_library_error_class(check_repo, root, violations, enforce_base=True)

        self.assertEqual(len(violations), 1)
        self.assertIn("libraries/example/core.lua:4", violations[0])
        self.assertIn(added, violations[0])
        self.assertIn("new relative to the target baseline", violations[0])

    def test_git_target_comparison_accepts_target_debt_absent_from_candidate_allowlist(self) -> None:
        existing = self.site("existing debt")
        target_debt = self.site("target debt")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.git(root, "init")
            self.git(root, "config", "user.email", "fkst-test@example.invalid")
            self.git(root, "config", "user.name", "fkst test")
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text('error("existing debt")\n', encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            allowlist = migration / "library-error-class.allowlist"
            allowlist.write_text(f"{existing}\n", encoding="utf-8")
            self.git(root, "add", ".")
            self.git(root, "commit", "-m", "common base")
            self.git(root, "branch", "feature")

            source.write_text(
                'error("existing debt")\nerror("target debt")\n',
                encoding="utf-8",
            )
            allowlist.write_text(f"{existing}\n{target_debt}\n", encoding="utf-8")
            self.git(root, "add", ".")
            self.git(root, "commit", "-m", "target advance")
            target = self.git(root, "rev-parse", "HEAD")
            self.git(root, "update-ref", "refs/remotes/origin/integration", target)

            self.git(root, "checkout", "feature")
            source.write_text(
                'error("existing debt")\nerror("target debt")\n',
                encoding="utf-8",
            )
            allowlist.write_text(f"{existing}\n", encoding="utf-8")
            violations: list[str] = []
            with mock.patch.dict(
                "os.environ",
                {"GITHUB_BASE_REF": "integration", "FKST_RATCHET_TARGET_REF": ""},
            ):
                check_repo_runner.check_library_error_class(check_repo, root, violations, enforce_base=True)

        self.assertEqual(violations, [])

    def test_push_rejects_source_and_allowlist_growth_against_event_before(self) -> None:
        existing = self.site("existing debt")
        added = self.site("new debt")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.git(root, "init")
            self.git(root, "config", "user.email", "fkst-test@example.invalid")
            self.git(root, "config", "user.name", "fkst test")
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text('error("existing debt")\n', encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            allowlist = migration / "library-error-class.allowlist"
            allowlist.write_text(f"{existing}\n", encoding="utf-8")
            self.git(root, "add", ".")
            self.git(root, "commit", "-m", "target")
            before = self.git(root, "rev-parse", "HEAD")

            source.write_text(
                'error("existing debt")\nerror("new debt")\n',
                encoding="utf-8",
            )
            allowlist.write_text(f"{existing}\n{added}\n", encoding="utf-8")
            self.git(root, "add", ".")
            self.git(root, "commit", "-m", "candidate")
            candidate = self.git(root, "rev-parse", "HEAD")
            self.git(root, "update-ref", "refs/remotes/origin/integration", candidate)
            event_path = root / "push-event.json"
            event_path.write_text(json.dumps({"before": before}), encoding="utf-8")

            violations: list[str] = []
            with mock.patch.dict(
                "os.environ",
                {
                    "FKST_DEVLOOP_INTEGRATION_BRANCH": "",
                    "FKST_RATCHET_TARGET_REF": "",
                    "GITHUB_BASE_REF": "",
                    "GITHUB_EVENT_NAME": "push",
                    "GITHUB_EVENT_PATH": str(event_path),
                    "GITHUB_REF_NAME": "integration",
                    "GITHUB_REF_TYPE": "branch",
                },
            ):
                check_repo_runner.check_library_error_class(check_repo, root, violations, enforce_base=True)

        self.assertEqual(len(violations), 1)
        self.assertIn("libraries/example/core.lua:2", violations[0])
        self.assertIn(added, violations[0])
        self.assertIn("new relative to the target baseline", violations[0])

    def test_checker_loads_target_diagnostics_when_enforcing_base(self) -> None:
        existing = self.site("missing class")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "libraries" / "example" / "core.lua"
            source.parent.mkdir(parents=True)
            source.write_text('error("missing class")\n', encoding="utf-8")
            migration = root / "migration"
            migration.mkdir()
            (migration / "library-error-class.allowlist").write_text(f"{existing}\n", encoding="utf-8")
            violations: list[str] = []
            with mock.patch.object(
                check_repo.check_repo_error_class,
                "target_library_sites",
                return_value=("present", {existing: "libraries/example/core.lua:7"}),
            ) as target_sites:
                check_repo_runner.check_library_error_class(check_repo, root, violations, enforce_base=True)

        target_sites.assert_called_once()
        self.assertEqual(violations, [])

    def test_library_allowlist_accepts_stable_identity_and_rejects_line_identity(self) -> None:
        stable = self.site("missing class")
        self.assertEqual(
            check_repo.check_repo_error_class.parse_library_allowlist_lines([stable]),
            {stable},
        )
        with self.assertRaises(ValueError):
            check_repo.check_repo_error_class.parse_library_allowlist_lines(
                ["libraries/example/core.lua:1"]
            )


if __name__ == "__main__":
    unittest.main()
