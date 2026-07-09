#!/usr/bin/env python3
"""Render and verify launchd restart authority for one fkst supervise unit."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any


UNIT_SCHEMA = "fkst.launchd.supervise.unit.v1"
BAD_EXECUTABLE_BASENAMES = {
    "bash",
    "crontab",
    "dogfood.sh",
    "launchctl",
    "nohup",
    "sh",
    "zsh",
}
BAD_SHELL_TOKENS = {"&", "cron", "crontab", "for", "nohup", "until", "while"}


@dataclass(frozen=True)
class SuperviseLaunchdUnit:
    label: str
    project_root: str
    platform_root: str
    platform_packages: tuple[str, ...]
    durable_root: str


def _string_field(data: dict[str, Any], field: str, errors: list[str]) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        errors.append(f"{field} must be a non-empty string")
        return ""
    if not value.startswith("/") and field.endswith("_root"):
        errors.append(f"{field} must be an explicit absolute path")
    return value


def load_unit(path: str) -> SuperviseLaunchdUnit:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("deployment unit must be a JSON object")

    errors: list[str] = []
    if data.get("schema") != UNIT_SCHEMA:
        errors.append(f"schema must be {UNIT_SCHEMA!r}")
    label = _string_field(data, "label", errors)
    project_root = _string_field(data, "project_root", errors)
    platform_root = _string_field(data, "platform_root", errors)
    durable_root = _string_field(data, "durable_root", errors)

    packages = data.get("platform_packages")
    platform_packages: list[str] = []
    if not isinstance(packages, list) or not packages:
        errors.append("platform_packages must be a non-empty string array")
    else:
        for index, package in enumerate(packages):
            if not isinstance(package, str) or package == "" or re.search(r"\s", package):
                errors.append(f"platform_packages[{index}] must be a non-empty package name without whitespace")
            else:
                platform_packages.append(package)

    if errors:
        raise ValueError("; ".join(errors))
    return SuperviseLaunchdUnit(
        label=label,
        project_root=project_root,
        platform_root=platform_root,
        platform_packages=tuple(platform_packages),
        durable_root=durable_root,
    )


def canonical_program_arguments(unit: SuperviseLaunchdUnit) -> list[str]:
    run_script = str(PurePosixPath(unit.platform_root) / "scripts" / "run.sh")
    return [
        run_script,
        "supervise",
        "--project-root",
        unit.project_root,
        "--platform-root",
        unit.platform_root,
        "--platform-packages",
        " ".join(unit.platform_packages),
        "--durable-root",
        unit.durable_root,
        "--restart",
    ]


def launchd_manifest(unit: SuperviseLaunchdUnit) -> dict[str, Any]:
    return {
        "AbandonProcessGroup": True,
        "KeepAlive": True,
        "Label": unit.label,
        "ProgramArguments": canonical_program_arguments(unit),
    }


def render_plist(unit: SuperviseLaunchdUnit) -> bytes:
    return plistlib.dumps(launchd_manifest(unit), sort_keys=True)


def _plist_object(manifest_bytes: bytes) -> dict[str, Any] | None:
    try:
        parsed = plistlib.loads(manifest_bytes)
    except Exception:
        return None
    return parsed if isinstance(parsed, dict) else None


def _basename(value: str) -> str:
    return value.rstrip("/").rsplit("/", 1)[-1]


def _shell_tokens(value: str) -> set[str]:
    return {token for token in re.split(r"[\s;|]+", value.lower()) if token}


def authority_shape_errors(parsed: dict[str, Any], unit: SuperviseLaunchdUnit) -> list[str]:
    errors: list[str] = []
    expected_args = canonical_program_arguments(unit)
    args = parsed.get("ProgramArguments")

    if parsed.get("Label") != unit.label:
        errors.append("Label does not match deployment unit")
    if parsed.get("KeepAlive") is not True:
        errors.append("KeepAlive must be true")
    if parsed.get("AbandonProcessGroup") is not True:
        errors.append("AbandonProcessGroup must be true")
    if args != expected_args:
        errors.append("ProgramArguments must be the canonical foreground scripts/run.sh supervise command")

    if isinstance(args, list) and all(isinstance(arg, str) for arg in args):
        basenames = {_basename(arg).lower() for arg in args}
        bad_execs = sorted(basenames & BAD_EXECUTABLE_BASENAMES)
        if bad_execs:
            errors.append("ProgramArguments contain forbidden restart wrapper executable(s): " + ", ".join(bad_execs))
        shell_tokens = set().union(*(_shell_tokens(arg) for arg in args))
        bad_tokens = sorted(shell_tokens & BAD_SHELL_TOKENS)
        if bad_tokens:
            errors.append("ProgramArguments contain forbidden shell-wrapper token(s): " + ", ".join(bad_tokens))
    else:
        errors.append("ProgramArguments must be an array of strings")

    return errors


def verify_manifest(unit: SuperviseLaunchdUnit, manifest_bytes: bytes) -> list[str]:
    parsed = _plist_object(manifest_bytes)
    if parsed is None:
        return ["manifest must be a parseable launchd plist dictionary"]

    errors = authority_shape_errors(parsed, unit)
    rendered = render_plist(unit)
    if manifest_bytes != rendered:
        rendered_object = _plist_object(rendered)
        if parsed == rendered_object:
            errors.append("manifest bytes drift from deterministic renderer output")
        else:
            errors.append("manifest structure drift from deterministic renderer output")
    return errors


def cmd_render(args: argparse.Namespace) -> int:
    unit = load_unit(args.unit)
    rendered = render_plist(unit)
    if args.output:
        with open(args.output, "wb") as handle:
            handle.write(rendered)
    else:
        sys.stdout.buffer.write(rendered)
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    unit = load_unit(args.unit)
    with open(args.manifest, "rb") as handle:
        errors = verify_manifest(unit, handle.read())
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__)
    sub = top.add_subparsers(dest="command", required=True)

    render = sub.add_parser("render")
    render.add_argument("--unit", required=True)
    render.add_argument("--output")
    render.set_defaults(func=cmd_render)

    check = sub.add_parser("check")
    check.add_argument("--unit", required=True)
    check.add_argument("--manifest", required=True)
    check.set_defaults(func=cmd_check)
    return top


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.func(args)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
