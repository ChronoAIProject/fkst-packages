"""Shrink-only ratchet for unclassified production error() strings."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

import check_repo_config
import ratchet_base


ALLOWLIST = "migration/error-class.allowlist"
LIBRARY_ALLOWLIST = "migration/library-error-class.allowlist"
LIBRARY_ID_RE = re.compile(
    r"(?P<path>libraries/.+\.lua):fingerprint=(?P<fingerprint>[0-9a-f]{64})"
    r":occurrence=(?P<occurrence>[1-9][0-9]*)\Z"
)
ERROR_CALL_STRING_RE = re.compile(r"\berror\s*\(\s*(?P<quote>['\"])(?P<message>[^'\"]*)(?P=quote)")
ERROR_CLASS_PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9-]*: [a-z0-9][a-z0-9-]*:")


def unclassified_error_calls(text: str, strip_lua_comments_and_strings, is_unmasked_range) -> list[tuple[int, str]]:
    stripped = strip_lua_comments_and_strings(text)
    calls: list[tuple[int, str]] = []
    for match in ERROR_CALL_STRING_RE.finditer(text):
        if not is_unmasked_range(text, stripped, match.start(), match.start("quote")):
            continue
        message = match.group("message")
        if not ERROR_CLASS_PREFIX_RE.match(message):
            calls.append((text.count("\n", 0, match.start()) + 1, message))
    return calls


def parse_scoped_allowlist_lines(lines: list[str], allowlist: str, prefix: str) -> set[str]:
    entries: set[str] = set()
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not line.startswith(prefix) or ":line=" in line or ":" not in line:
            raise ValueError(f"invalid {allowlist} line: {raw}")
        path_part, line_part = line.rsplit(":", 1)
        if not path_part.endswith(".lua") or not line_part.isdigit() or int(line_part) < 1:
            raise ValueError(f"invalid {allowlist} line: {raw}")
        entries.add(line)
    return entries


def parse_allowlist_lines(lines: list[str]) -> set[str]:
    return parse_scoped_allowlist_lines(lines, ALLOWLIST, "packages/")


def parse_library_allowlist_lines(lines: list[str]) -> set[str]:
    entries: set[str] = set()
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if LIBRARY_ID_RE.fullmatch(line) is None:
            raise ValueError(f"invalid {LIBRARY_ALLOWLIST} line: {raw}")
        entries.add(line)
    return entries


load_allowlist, allowlist_at_dev_base = check_repo_config.bind_allowlist_helpers(ALLOWLIST, parse_allowlist_lines)


def load_library_allowlist(path: Path) -> set[str]:
    return check_repo_config.load_allowlist(path, parse_allowlist_lines=parse_library_allowlist_lines)


def current_sites(root, package_lua_files, read_text, rel, unclassified_error_call_lines) -> set[str]:
    sites: set[str] = set()
    for packages, path in package_lua_files(root):
        if not path.is_file() or "tests" in path.relative_to(packages).parts:
            continue
        for line in unclassified_error_call_lines(read_text(path)):
            sites.add(f"{rel(root, path)}:{line}")
    return sites


def library_sites_for_source(relative_path: str, text: str, unclassified_error_calls) -> dict[str, str]:
    sites: dict[str, str] = {}
    occurrences: dict[str, int] = {}
    for line, message in unclassified_error_calls(text):
        fingerprint = hashlib.sha256(message.encode("utf-8")).hexdigest()
        occurrence = occurrences.get(fingerprint, 0) + 1
        occurrences[fingerprint] = occurrence
        identity = f"{relative_path}:fingerprint={fingerprint}:occurrence={occurrence}"
        sites[identity] = f"{relative_path}:{line}"
    return sites


def current_library_diagnostics(root, read_text, rel, unclassified_error_calls) -> dict[str, str]:
    libraries = root / "libraries"
    sites: dict[str, str] = {}
    if not libraries.exists():
        return sites
    for path in sorted(libraries.rglob("*.lua")):
        if not path.is_file() or "tests" in path.relative_to(libraries).parts:
            continue
        sites.update(library_sites_for_source(rel(root, path), read_text(path), unclassified_error_calls))
    return sites


def target_library_sites(root, current: dict[str, str], unclassified_error_calls) -> tuple[str, dict[str, str] | None]:
    target_commit = ratchet_base.resolve_target_ref(root)
    if target_commit is None:
        return "unresolved", None
    changed = ratchet_base.changed_paths(root, target_commit, "libraries")
    if changed is None:
        return "unresolved", None

    changed_set = set(changed)
    target = {
        identity: location
        for identity, location in current.items()
        if identity.split(":fingerprint=", 1)[0] not in changed_set
    }
    for relative_path in sorted(changed_set):
        path = Path(relative_path)
        if path.suffix != ".lua" or "tests" in path.relative_to("libraries").parts:
            continue
        status, source = ratchet_base.file_at_commit(root, target_commit, relative_path)
        if status == "unresolved":
            return "unresolved", None
        if status == "present":
            assert source is not None
            target.update(library_sites_for_source(relative_path, source, unclassified_error_calls))
    return "present", target


def scoped_ratchet_messages(
    current: set[str],
    allowlist: set[str],
    base_allowlist: set[str] | None,
    allowlist_name: str,
    source_name: str,
) -> list[str]:
    messages = [
        f"{site} {source_name} error(...) string lacks a greppable class prefix and is not in {allowlist_name}"
        for site in sorted(current - allowlist)
    ]
    if base_allowlist is not None:
        messages.extend(
            f"{site} grows {allowlist_name} relative to dev; classify the error string instead"
            for site in sorted(allowlist - base_allowlist)
        )
    return messages


def ratchet_messages(
    current: set[str],
    allowlist: set[str],
    base_allowlist: set[str] | None = None,
) -> list[str]:
    return scoped_ratchet_messages(current, allowlist, base_allowlist, ALLOWLIST, "production")


def library_ratchet_messages(
    current: dict[str, str],
    allowlist: set[str],
    target_sites: dict[str, str] | None = None,
) -> list[str]:
    messages: list[str] = []
    for identity in sorted(current):
        location = current[identity]
        if target_sites is not None and identity not in target_sites:
            messages.append(
                f"{location} production library error(...) string is new relative to the target baseline; "
                f"diagnostic identity {identity}; classify the error string instead"
            )
        elif identity not in allowlist:
            messages.append(
                f"{location} production library error(...) string lacks a greppable class prefix; "
                f"diagnostic identity {identity} is not in {LIBRARY_ALLOWLIST}"
            )
    return messages
