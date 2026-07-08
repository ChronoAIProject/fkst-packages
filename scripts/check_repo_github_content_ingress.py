"""GitHub authored-content ingress ratchet."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable


RULE = "G-GITHUB-CONTENT-INGRESS"
WRAPPER_NEEDLES = {
    "libraries/forge/github/exec.lua": ("content_filter.filter_gh_content_json", "stdout_policy.is_content_json"),
    "libraries/devloop/gh_exec.lua": ("content_filter.filter_gh_content_json", "stdout_policy.is_content_json"),
}


def matching_call(text: str, open_paren: int) -> str:
    depth = 0
    cursor = open_paren
    while cursor < len(text):
        char = text[cursor]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return text[open_paren : cursor + 1]
        cursor += 1
    return text[open_paren:]


def top_level_commas(text: str) -> int:
    depth = 0
    commas = 0
    for char in text:
        if char in "([{":
            depth += 1
        elif char in ")]}" and depth > 0:
            depth -= 1
        elif char == "," and depth == 1:
            commas += 1
    return commas


def production_lua_sources(
    root: Path,
    read_text: Callable[[Path], str],
    rel: Callable[[Path, Path], str],
    package_lua_files: Callable[[Path], list[tuple[Path, Path]]],
) -> list[tuple[str, str]]:
    paths = [path for _packages, path in package_lua_files(root)]
    for scan_root in (root / "libraries" / "forge" / "github", root / "libraries" / "devloop"):
        if scan_root.exists():
            paths.extend(path for path in sorted(scan_root.rglob("*.lua")) if path.is_file())
    sources = []
    for path in sorted(set(paths)):
        relpath = rel(root, path)
        if "/tests/" in relpath or relpath.endswith("_test.lua"):
            continue
        if relpath in {
            "libraries/forge/github.lua",
            "libraries/forge/github_fake.lua",
        }:
            continue
        sources.append((relpath, read_text(path)))
    return sources


def file_has_obfuscated_gh_head(source: str) -> bool:
    return re.search(
        r"table\s*\.\s*concat\s*\(\s*\{\s*['\"]g['\"]\s*,\s*['\"]h['\"]\s*\}",
        source,
    ) is not None


def messages(
    root: Path,
    read_text: Callable[[Path], str],
    rel: Callable[[Path, Path], str],
    package_lua_files: Callable[[Path], list[tuple[Path, Path]]],
    strip_lua_comments_and_strings: Callable[[str], str],
) -> list[str]:
    violations: list[str] = []
    for relpath, needles in WRAPPER_NEEDLES.items():
        path = root / relpath
        text = read_text(path) if path.is_file() else ""
        for needle in needles:
            if needle not in text:
                violations.append(
                    f"{relpath} must apply the shared GitHub content filter at gh ingress (missing: {needle})"
                )

    for relpath, text in production_lua_sources(root, read_text, rel, package_lua_files):
        stripped = strip_lua_comments_and_strings(text)
        for match in re.finditer(r"\bhandle\s*\.\s*_exec\s*\(", stripped):
            call = matching_call(stripped, match.end() - 1)
            if top_level_commas(call) < 3 or "stdout_policy." not in call:
                line = text.count("\n", 0, match.start()) + 1
                violations.append(f"{relpath}:{line} gh handle._exec call must declare a stdout_policy")
        if relpath not in WRAPPER_NEEDLES:
            obfuscated_head = file_has_obfuscated_gh_head(text)
            for match in re.finditer(r"\bexec_argv\s*\(", stripped):
                call = matching_call(stripped, match.end() - 1)
                raw = text[match.start() : match.start() + len(call)]
                if "argv" in call and ('"gh"' in raw or "'gh'" in raw or obfuscated_head):
                    line = text.count("\n", 0, match.start()) + 1
                    violations.append(
                        f"{relpath}:{line} raw gh exec_argv egress must use forge.github.exec.run or devloop.gh_exec"
                    )
    return violations
