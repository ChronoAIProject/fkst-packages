#!/usr/bin/env python3
"""Tests for the G-GH-HANDLE-CONSTRUCTION debt ratchet."""

from __future__ import annotations

import sys
import tempfile
import textwrap
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_repo_gh_handle_construction as ratchet  # noqa: E402


def write(root: Path, relpath: str, source: str) -> None:
    path = root / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(source), encoding="utf-8")


def test_detector_distinguishes_ownership_wiring_and_consumer_locators() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        write(
            root,
            "libraries/forge/github.lua",
            """
            local M = {}
            function M.new(exec, opts) return {} end
            return M
            """,
        )
        write(
            root,
            "libraries/forge/ports.lua",
            """
            local M = {}
            local function github_from_options(run, options)
              return require("forge.github").new(run, options)
            end
            function M.production_handles(opts) return github_from_options(exec_argv, opts) end
            function M.install(make_department, opts) return make_department(M.production_handles(opts)) end
            return M
            """,
        )
        write(
            root,
            "libraries/devloop/github_factory.lua",
            """
            local github_adapter = require("forge.github")
            local M = {}
            function M.new(exec, env_exec) return github_adapter.new(exec, {}) end
            function M.production_handle() return M.new(exec_argv, exec_sync) end
            return M
            """,
        )
        write(
            root,
            "packages/canonical/core.lua",
            """
            local M = {}
            local github_factory = require("devloop.github_factory")
            local github_handle = github_factory.production_handle()
            require("forge.merge").install(M, {
              github_handle = require("devloop.github_factory").production_handle,
            })
            return M
            """,
        )
        write(
            root,
            "packages/canonical/departments/wired/main.lua",
            """
            local ports_lib = require("forge.ports")
            local function make_department(ports) return { spec = {}, pipeline = function() end } end
            return ports_lib.install(make_department)
            """,
        )
        write(
            root,
            "libraries/devloop/consumer.lua",
            """
            local github_factory = require("devloop.github_factory")
            local function github()
              return github_factory.production_handle()
            end
            return { github = github }
            """,
        )
        write(
            root,
            "packages/rogue/core/constructor.lua",
            """
            local function unsafe_handle(run)
              return require("forge.github").new(run, {})
            end
            return { unsafe_handle = unsafe_handle }
            """,
        )

        debt = ratchet.current_debt(root)
        canonical = ratchet.canonical_sites(root)

    assert debt == {
        "libraries/devloop/consumer.lua:github",
        "packages/canonical/core.lua:github_handle",
        "packages/rogue/core/constructor.lua:unsafe_handle",
    }
    assert "libraries/forge/github.lua:M.new" in canonical
    assert "libraries/forge/ports.lua:M.production_handles" in canonical
    assert "libraries/devloop/github_factory.lua:M.new" in canonical
    assert "libraries/devloop/github_factory.lua:M.production_handle" in canonical
    assert "packages/canonical/core.lua:forge.merge.install" in canonical
    assert "packages/canonical/departments/wired/main.lua:ports_lib.install" in canonical


def test_inventory_must_equal_current_debt_and_shrink_against_scoped_base() -> None:
    current = {"libraries/devloop/consumer.lua:github"}

    assert ratchet.ratchet_messages(current, set(current), set(current)) == []
    assert any(
        "new consumer-side GitHub handle locator" in message
        for message in ratchet.ratchet_messages(
            current | {"packages/example/core.lua:rogue"},
            set(current),
            set(current),
        )
    )
    assert any(
        "no longer exists; remove it" in message
        for message in ratchet.ratchet_messages(set(), set(current), set(current))
    )
    assert any(
        "inventory grew relative to the base" in message
        for message in ratchet.ratchet_messages(
            current,
            set(current),
            set(),
        )
    )


def test_unscoped_manual_base_does_not_block_one_time_debt_rescope() -> None:
    lines = [
        "# Shrink-only production GitHub handle construction inventory",
        "libraries/forge/github.lua:M.new",
    ]

    assert ratchet.parse_inventory_lines(lines, require_debt_header=True) is None


def test_current_repository_has_19_debts_and_recognizes_original_16_canonical_facts() -> None:
    root = Path(__file__).resolve().parents[1]

    debt = ratchet.current_debt(root)
    canonical = ratchet.canonical_sites(root)

    assert len(debt) == 19
    assert ratchet.ORIGINAL_CANONICAL_FACTS <= canonical
    assert ratchet.ORIGINAL_CANONICAL_FACTS.isdisjoint(debt)
    assert ratchet.load_inventory(root) == debt
