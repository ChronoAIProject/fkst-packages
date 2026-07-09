#!/usr/bin/env python3
"""Acceptance tests for launchd supervise restart authority rendering."""

from __future__ import annotations

import copy
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
UNIT_PATH = REPO_ROOT / "scripts" / "launchd" / "supervise.fixture.json"
MANIFEST_PATH = REPO_ROOT / "scripts" / "launchd" / "com.chronoai.fkst.supervise.fixture.plist"


def load_launchd_supervise():
    path = REPO_ROOT / "scripts" / "launchd_supervise.py"
    spec = importlib.util.spec_from_file_location("launchd_supervise", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load launchd_supervise.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


launchd_supervise = load_launchd_supervise()


class LaunchdSuperviseTest(unittest.TestCase):
    def test_fixture_manifest_is_byte_equal_to_renderer_and_structurally_valid(self) -> None:
        unit = launchd_supervise.load_unit(str(UNIT_PATH))
        rendered = launchd_supervise.render_plist(unit)
        committed = MANIFEST_PATH.read_bytes()

        self.assertEqual(committed, rendered)
        parsed = plistlib.loads(committed)
        self.assertEqual(
            parsed["ProgramArguments"],
            [
                "/opt/fkst/fkst-packages/scripts/run.sh",
                "supervise",
                "--project-root",
                "/opt/fkst/host",
                "--platform-root",
                "/opt/fkst/fkst-packages",
                "--platform-packages",
                "github-devloop github-devloop-pr github-devloop-integration github-proxy consensus",
                "--durable-root",
                "/var/db/fkst/durable",
                "--restart",
            ],
        )
        self.assertIs(parsed["KeepAlive"], True)
        self.assertIs(parsed["AbandonProcessGroup"], True)
        self.assertEqual(launchd_supervise.verify_manifest(unit, committed), [])

    def test_checker_rejects_missing_abandon_process_group(self) -> None:
        unit = launchd_supervise.load_unit(str(UNIT_PATH))
        parsed = copy.deepcopy(launchd_supervise.launchd_manifest(unit))
        parsed.pop("AbandonProcessGroup")
        errors = launchd_supervise.verify_manifest(unit, plistlib.dumps(parsed, sort_keys=True))

        self.assertTrue(any("AbandonProcessGroup must be true" in error for error in errors), errors)

    def test_checker_rejects_dogfood_restart_wrapper(self) -> None:
        unit = launchd_supervise.load_unit(str(UNIT_PATH))
        parsed = copy.deepcopy(launchd_supervise.launchd_manifest(unit))
        parsed["ProgramArguments"] = [
            "/opt/fkst/fkst-packages/.claude/skills/dogfood-github-devloop/dogfood.sh",
            "restart",
        ]
        errors = launchd_supervise.verify_manifest(unit, plistlib.dumps(parsed, sort_keys=True))

        self.assertTrue(any("canonical foreground scripts/run.sh supervise command" in error for error in errors), errors)
        self.assertTrue(any("dogfood.sh" in error for error in errors), errors)

    def test_checker_rejects_shell_loop_background_wrapper(self) -> None:
        unit = launchd_supervise.load_unit(str(UNIT_PATH))
        parsed = copy.deepcopy(launchd_supervise.launchd_manifest(unit))
        parsed["ProgramArguments"] = [
            "/bin/sh",
            "-c",
            "while true; do scripts/run.sh supervise --restart & sleep 1; done",
        ]
        errors = launchd_supervise.verify_manifest(unit, plistlib.dumps(parsed, sort_keys=True))

        self.assertTrue(any("canonical foreground scripts/run.sh supervise command" in error for error in errors), errors)
        self.assertTrue(any("forbidden restart wrapper executable" in error for error in errors), errors)
        self.assertTrue(any("forbidden shell-wrapper token" in error for error in errors), errors)

    def test_checker_cli_accepts_committed_fixture(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(REPO_ROOT / "scripts" / "launchd_supervise.py"),
                "check",
                "--unit",
                str(UNIT_PATH),
                "--manifest",
                str(MANIFEST_PATH),
            ],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unit_requires_explicit_roots(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "unit.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": launchd_supervise.UNIT_SCHEMA,
                        "label": "com.chronoai.fkst.supervise.fixture",
                        "project_root": "relative-host",
                        "platform_root": "/opt/fkst/fkst-packages",
                        "platform_packages": ["github-proxy"],
                        "durable_root": "/var/db/fkst/durable",
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "project_root must be an explicit absolute path"):
                launchd_supervise.load_unit(str(path))


if __name__ == "__main__":
    unittest.main()
