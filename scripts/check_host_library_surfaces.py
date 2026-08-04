#!/usr/bin/env python3
"""Verify the exact publishable library surfaces through a real host catalog."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import textwrap
import tomllib
from pathlib import Path


HOST_LIBRARIES = ("contract", "workflow", "testkit")
HOST_EXPORTS = {
    "workflow": ["workflow.dead_letter", "workflow.saga"],
    "testkit": ["testkit.graph"],
}


def run(
    args: list[str],
    cwd: Path,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def require_success(result: subprocess.CompletedProcess[str], action: str) -> None:
    if result.returncode == 0:
        return
    detail = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    raise RuntimeError(f"{action} failed with exit {result.returncode}:\n{detail}")


def write_host(host: Path, source_root: Path, revision: str) -> Path:
    package_root = host / ".fkst" / "local-packages" / "surface-probe"
    package_root.mkdir(parents=True)
    (host / "fkst.workspace.toml").write_text(
        textwrap.dedent(
            f"""\
            [workspace]
            units = [".fkst/local-packages/*"]

            [[external_sources]]
            id = "fkst-packages-platform"
            git = {json.dumps(str(source_root))}
            rev = {json.dumps(revision)}
            packages = ["github-proxy"]
            libraries = ["contract", "workflow", "testkit"]
            """
        ),
        encoding="utf-8",
    )
    (package_root / "fkst.toml").write_text(
        textwrap.dedent(
            """\
            kind = "package"
            name = "surface-probe"
            persistence_class = "stateless_adapter"

            [code]
            root = "."

            [lib_deps]
            libraries = ["contract", "workflow", "testkit"]
            """
        ),
        encoding="utf-8",
    )
    (package_root / "core.lua").write_text(
        textwrap.dedent(
            """\
            local saga = require("workflow.saga")
            local dead_letter = require("workflow.dead_letter")
            local graph = require("testkit.graph")

            return {
              saga_department = saga.department,
              dead_letter_handlers = dead_letter.handlers,
              graph_assert_covers = graph.assert_covers,
            }
            """
        ),
        encoding="utf-8",
    )
    department_root = package_root / "departments" / "probe"
    department_root.mkdir(parents=True)
    (department_root / "main.lua").write_text(
        textwrap.dedent(
            """\
            local saga = require("workflow.saga")

            local spec = {
              consumes = { "probe" },
              produces = {},
              stall_window = "1m",
            }

            return saga.department(spec, {
              done = function(_event)
                return false
              end,
              act = function(_event)
                return nil
              end,
            })
            """
        ),
        encoding="utf-8",
    )
    raisers_root = package_root / "raisers"
    raisers_root.mkdir()
    (raisers_root / "probe.lua").write_text(
        textwrap.dedent(
            """\
            return {
              type = "cron",
              interval = "1h",
              produces = "probe",
            }
            """
        ),
        encoding="utf-8",
    )
    tests_root = package_root / "tests"
    tests_root.mkdir()
    (tests_root / "run_graph_public_surfaces_test.lua").write_text(
        textwrap.dedent(
            """\
            local dead_letter = require("workflow.dead_letter")
            local graph = require("testkit.graph")
            local t = fkst.test

            return {
              test_publishable_host_surfaces_execute = function()
                local handlers = dead_letter.handlers({ package = "surface-probe" })
                t.eq(type(handlers.done), "function")
                t.eq(type(handlers.act), "function")

                local trace = graph.require_quiescent(
                  graph.run("surface-probe.probe", { max_steps = 1 })
                )
                graph.assert_covers(trace, {
                  "surface-probe.probe -> surface-probe.probe",
                })
              end,
            }
            """
        ),
        encoding="utf-8",
    )
    return package_root


def lock_library_names(lock_path: Path) -> list[str]:
    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    sources = lock.get("external_source") or []
    if len(sources) != 1:
        raise RuntimeError(f"host lock must contain one external source, observed {len(sources)}")
    return sorted(entry["name"] for entry in sources[0].get("libraries") or [])


def verify_catalog(report: dict) -> None:
    if report.get("ok") is not True:
        raise RuntimeError(f"host dependency catalog failed: {report.get('failures')}")
    units = {unit.get("library"): unit for unit in report.get("units") or [] if unit.get("library")}
    for library, expected_exports in HOST_EXPORTS.items():
        unit = units.get(library)
        if unit is None:
            raise RuntimeError(f"host dependency catalog omitted library {library}")
        observed = unit.get("public_exports")
        if observed != expected_exports:
            raise RuntimeError(f"{library} exports {observed}, expected {expected_exports}")


def verify(bin_path: Path, source_root: Path) -> None:
    revision_result = run(["git", "rev-parse", "HEAD"], source_root)
    require_success(revision_result, "resolve source revision")
    revision = revision_result.stdout.strip()

    with tempfile.TemporaryDirectory(prefix="fkst-host-library-surfaces-") as tmp:
        host = Path(tmp)
        write_host(host, source_root, revision)
        lock_result = run(
            [
                str(bin_path),
                "host",
                "lock",
                "--project-root",
                str(host),
            ],
            source_root,
        )
        require_success(lock_result, "lock host library surfaces")
        observed_libraries = lock_library_names(host / "fkst.lock")
        if observed_libraries != sorted(HOST_LIBRARIES):
            raise RuntimeError(f"host lock admitted {observed_libraries}, expected {sorted(HOST_LIBRARIES)}")

        deps_result = run(
            [
                str(bin_path),
                "deps",
                "--project-root",
                str(host),
                "--locked",
                "--json",
            ],
            source_root,
        )
        require_success(deps_result, "resolve host library surfaces")
        verify_catalog(json.loads(deps_result.stdout))

        host_test_env = os.environ.copy()
        host_test_env["BIN"] = str(bin_path)
        test_result = run(
            [
                str(source_root / "scripts" / "run.sh"),
                "host",
                "--host-root",
                str(host),
                "--platform-root",
                str(source_root),
                "--",
                "test",
            ],
            source_root,
            env=host_test_env,
        )
        require_success(test_result, "execute host library surfaces")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    args = parser.parse_args()
    verify(args.bin.resolve(), args.source_root.resolve())
    print("OK: host can resolve and execute exact workflow and testkit public surfaces")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
