#!/usr/bin/env python3
"""Structural and source-contract tests for the dogfood operator split."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop"
ENTRYPOINT = SKILL_ROOT / "dogfood.sh"
BOARD_MODULE = SKILL_ROOT / "dogfood_board.sh"


class DogfoodSplitContract(unittest.TestCase):
    def test_board_responsibility_is_extracted_and_sourced(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertTrue(BOARD_MODULE.is_file())
        self.assertIn('. "$_self_dir/dogfood_board.sh"', source)
        self.assertNotIn("board_one() {", source)
        self.assertIn("board_one() {", BOARD_MODULE.read_text(encoding="utf-8"))

    def test_operator_shell_files_leave_capacity_below_soft_limit(self) -> None:
        shell_files = [ENTRYPOINT, *sorted(SKILL_ROOT.glob("dogfood_*.sh"))]

        for path in shell_files:
            with self.subTest(path=path.name):
                lines = len(path.read_text(encoding="utf-8").splitlines())
                self.assertLess(lines, 900, f"{path} has {lines} lines")

    def test_entrypoint_and_modules_are_valid_shell(self) -> None:
        shell_files = [ENTRYPOINT, *sorted(SKILL_ROOT.glob("dogfood_*.sh"))]
        result = subprocess.run(
            ["/bin/bash", "-n", *map(str, shell_files)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sourcing_entrypoint_exposes_board_and_operator_commands(self) -> None:
        command = (
            f'source "{ENTRYPOINT}"\n'
            "declare -F board_one cmd_board status_one cmd_doctor bin_ensure_fresh cmd_sync\n"
        )
        result = subprocess.run(
            ["/bin/bash", "-c", command],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (
            "board_one",
            "cmd_board",
            "status_one",
            "cmd_doctor",
            "bin_ensure_fresh",
            "cmd_sync",
        ):
            self.assertIn(name, result.stdout)


if __name__ == "__main__":
    unittest.main()
