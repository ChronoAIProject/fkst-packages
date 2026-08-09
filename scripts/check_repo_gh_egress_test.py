#!/usr/bin/env python3
"""Behavior tests for the exact-one GitHub raw argv egress checker."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


CHECKER = Path(__file__).with_name("check_repo_gh_egress.py")
SANCTIONED = "libraries/forge/github/exec.lua:M.run"


def write(root: Path, relpath: str, source: str) -> None:
    path = root / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(source), encoding="utf-8")


def run_checker(files: dict[str, str], inventory: str = SANCTIONED + "\n") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write(root, "migration/gh-egress.inventory", inventory)
        for relpath, source in files.items():
            write(root, relpath, source)
        return subprocess.run(
            [sys.executable, "-B", str(CHECKER), str(root)],
            check=False,
            capture_output=True,
            text=True,
        )


def canonical_source() -> str:
    return """
        local M = {}
        function M.run(exec, argv, timeout)
          return exec({ argv = argv, timeout = timeout })
        end
        return M
    """


def test_canonical_single_egress_is_green_and_delegation_is_not_a_sink() -> None:
    result = run_checker(
        {
            "libraries/forge/github/exec.lua": canonical_source(),
            "libraries/forge/github.lua": """
                local exec_wrap = require("forge.github.exec")
                function M.new(exec)
                  return exec_wrap.run(exec, { "gh", "issue", "view" }, 30)
                end
            """,
        }
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert f'"{SANCTIONED}"' in result.stdout


def test_additional_injected_callback_sink_is_red_with_exact_message() -> None:
    rogue = "libraries/forge/github/rogue.lua:M.run_direct"
    result = run_checker(
        {
            "libraries/forge/github/exec.lua": canonical_source(),
            "libraries/forge/github/rogue.lua": """
                function M.run_direct(run, argv)
                  return run({ argv = argv })
                end
            """,
        }
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert (
        f"VIOLATION: G-GH-EGRESS: {rogue} is an additional GitHub raw argv egress sink; "
        f"exactly one is sanctioned: {SANCTIONED}"
    ) in result.stdout


def test_additional_direct_exec_argv_sink_is_red() -> None:
    result = run_checker(
        {
            "libraries/forge/github/exec.lua": canonical_source(),
            "libraries/forge/github/direct.lua": """
                function M.run_direct(argv)
                  return exec_argv({ argv = argv })
                end
            """,
        }
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "libraries/forge/github/direct.lua:M.run_direct is an additional" in result.stdout


def test_empty_inventory_is_rejected_because_terminal_floor_is_one() -> None:
    result = run_checker(
        {"libraries/forge/github/exec.lua": canonical_source()},
        "# Historical wording must not turn the terminal contract into a zero target.\n",
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "terminal floor is one, not zero" in result.stdout


def test_comments_and_strings_do_not_create_sinks() -> None:
    result = run_checker(
        {
            "libraries/forge/github/exec.lua": canonical_source(),
            "libraries/forge/github/messages.lua": """
                function M.describe(exec)
                  -- exec({ argv = argv })
                  return "exec_argv({ argv = argv })"
                end
            """,
        }
    )

    assert result.returncode == 0, result.stdout + result.stderr
