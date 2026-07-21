#!/usr/bin/env python3
"""Protected-base preflight for R9 restart-lifecycle refactor additions."""

from __future__ import annotations

from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Iterable


INVENTORY = "migration/restart-lifecycle.inventory.json"
SEMANTIC_TREE_CONTROL = "scripts/intent_bounded_replay/semantic_tree.py"
CHECKER_CONTROLS = {
    "scripts/check_repo_intent_bounded_replay.py",
    "scripts/check_repo_restart_preflight.py",
    "scripts/intent_bounded_replay/compare.py",
    "scripts/intent_bounded_replay/corpus_manifest.json",
    "scripts/intent_bounded_replay/normalize.py",
    SEMANTIC_TREE_CONTROL,
}
SEMANTIC_PREFIXES = (
    "libraries/devloop/",
    "packages/github-devloop/",
    "packages/github-devloop-pr/",
)
AUTHORITY_CALL_RE = re.compile(
    r"\b(?:decide_transition|seal_snapshot|mint_grant|verify_grant)\s*\("
)
GRANT_FACTORY_RE = re.compile(
    r"\b(?:mint_grant|verify_grant|restart_effect_seal)\b"
)
OWNER_SEAL_RE = re.compile(
    r"\b(?:owner_seal|_owner_snapshot_seal|_owner_grant_seal|seal_snapshot)\b"
)
ANOMALY_RE = re.compile(
    r"restart[_-]transition[_-]anomaly|restart-transition-anomaly\.v1"
)
ALLOWED_ANOMALY_SHADOW_PATHS = {
    "libraries/devloop/restart_transition_anomaly.lua",
    "packages/github-devloop/core/restart_analysis.lua",
    "packages/github-devloop-pr/core/restart_analysis.lua",
}
ATTESTATION_SCHEMA = "fkst.intent-diff-attestation.v1"
SAFE_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*")


def _git(root: Path, args: list[str], *, text: bool = True):
    return subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )


def _safe_ref(value: str) -> bool:
    return value not in {"", "HEAD"} and ".." not in value and SAFE_REF_RE.fullmatch(value) is not None


def _resolves(root: Path, ref: str) -> bool:
    result = _git(root, ["rev-parse", "--verify", "--quiet", "--end-of-options", f"{ref}^{{commit}}"])
    return result.returncode == 0 and bool(result.stdout.strip())


def selected_base_ref(root: Path) -> str | None:
    explicit = os.environ.get("FKST_RESTART_PREFLIGHT_BASE_REF")
    if explicit:
        return explicit if _safe_ref(explicit) and _resolves(root, explicit) else None

    github_base = os.environ.get("GITHUB_BASE_REF")
    if github_base and _safe_ref(github_base):
        remote = f"origin/{github_base}"
        if _resolves(root, remote):
            return remote
        if _resolves(root, github_base):
            return github_base
        return None

    upstream = _git(
        root,
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    )
    candidate = upstream.stdout.strip() if upstream.returncode == 0 else ""
    if candidate and _safe_ref(candidate) and _resolves(root, candidate):
        return candidate

    for fallback in ("origin/dev", "dev"):
        if _resolves(root, fallback):
            return fallback
    return None


def protected_merge_base(root: Path, base_ref: str) -> str | None:
    if not _safe_ref(base_ref) or not _resolves(root, base_ref):
        return None
    result = _git(root, ["merge-base", "HEAD", base_ref])
    base = result.stdout.strip()
    return base if result.returncode == 0 and base else None


def _tracked_paths(root: Path, ref: str) -> list[str]:
    result = _git(root, ["ls-tree", "-r", "-z", "--name-only", ref, "--"], text=False)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git ls-tree failed: {detail}")
    return [
        raw.decode("utf-8", "surrogateescape")
        for raw in result.stdout.split(b"\0")
        if raw
    ]


def _blob(root: Path, ref: str, path: str) -> bytes:
    result = _git(root, ["show", f"{ref}:{path}"], text=False)
    if result.returncode != 0:
        return b""
    return result.stdout


def _text(root: Path, ref: str, path: str) -> str:
    return _blob(root, ref, path).decode("utf-8", "replace")


def _changed_paths(root: Path, base: str) -> set[str]:
    result = _git(
        root,
        ["diff", "--name-only", "-z", "--no-renames", base, "HEAD", "--"],
        text=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git diff failed: {detail}")
    return {
        raw.decode("utf-8", "surrogateescape")
        for raw in result.stdout.split(b"\0")
        if raw
    }


def _production_semantic(path: str) -> bool:
    return (
        path.endswith((".lua", ".toml"))
        and any(path.startswith(prefix) for prefix in SEMANTIC_PREFIXES)
        and "/tests/" not in path
    )


def _new_matches(pattern: re.Pattern[str], old: str, new: str) -> Counter[str]:
    return Counter(pattern.findall(new)) - Counter(pattern.findall(old))


def _inventory_contract(
    root: Path, head_ref: str
) -> tuple[set[str], set[str], list[str]]:
    try:
        document = json.loads(_text(root, head_ref, INVENTORY))
    except (json.JSONDecodeError, TypeError) as error:
        return set(), set(), [f"inventory-unreadable: {INVENTORY}: {error}"]
    watched = document.get("watched_files")
    if not isinstance(watched, list) or not all(isinstance(path, str) and path for path in watched):
        return set(), set(), [f"inventory-unreadable: {INVENTORY}: watched_files must be an array of paths"]
    sites = document.get("production_writer_sites")
    if not isinstance(sites, list):
        return set(), set(), [f"inventory-unreadable: {INVENTORY}: production_writer_sites must be an array"]
    writer_tokens: set[str] = set()
    for site in sites:
        ordinal = site.get("ordinal") if isinstance(site, dict) else None
        token = ordinal.split(":", 1)[0] if isinstance(ordinal, str) else ""
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
            writer_tokens.add(token)
    if not writer_tokens:
        return set(), set(), [f"inventory-unreadable: {INVENTORY}: no writer primitives derived from production_writer_sites"]
    return set(watched), writer_tokens, []


def _tracked_attestation_messages(root: Path, head_ref: str, paths: Iterable[str]) -> list[str]:
    messages: list[str] = []
    for path in paths:
        if not path.endswith(".json"):
            continue
        try:
            document = json.loads(_text(root, head_ref, path))
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(document, dict) and document.get("schema") == ATTESTATION_SCHEMA:
            messages.append(
                f"tracked-attestation: {path} is a tracked CI attestation; attestations must stay outside the tracked tree"
            )
    return messages


def _exposure_messages(
    root: Path,
    base: str,
    head_ref: str,
    changed: set[str],
    watched: set[str],
) -> list[str]:
    messages: list[str] = []
    for path in sorted(changed - watched):
        if not _production_semantic(path):
            continue
        old = _text(root, base, path)
        new = _text(root, head_ref, path)
        shared_outside_factory = (
            path.startswith("libraries/devloop/")
            and path != "libraries/devloop/restart_effect_seal.lua"
        )
        explicit_exposure_surface = (
            "/departments/" in path
            or "/raisers/" in path
            or path.startswith("libraries/devloop/di/")
            or path.endswith("/fkst.toml")
        )
        if (shared_outside_factory or explicit_exposure_surface) and _new_matches(
            GRANT_FACTORY_RE, old, new
        ):
            messages.append(
                f"grant-factory-exposure: {path} adds a grant factory/verifier to a shared or public production surface"
            )
        if (shared_outside_factory or explicit_exposure_surface) and _new_matches(
            OWNER_SEAL_RE, old, new
        ):
            messages.append(
                f"owner-seal-exposure: {path} adds an owner seal to a shared, DI, manifest, or receiver surface"
            )
    return messages


def _unlisted_caller_messages(
    root: Path,
    base: str,
    head_ref: str,
    changed: set[str],
    watched: set[str],
    writer_tokens: set[str],
) -> list[str]:
    messages: list[str] = []
    writer_re = re.compile(
        r"\b(?:" + "|".join(map(re.escape, sorted(writer_tokens))) + r")\s*\("
    )
    for path in sorted(changed - watched):
        if not _production_semantic(path) or not path.endswith(".lua"):
            continue
        old = _text(root, base, path)
        new = _text(root, head_ref, path)
        if _new_matches(AUTHORITY_CALL_RE, old, new):
            messages.append(
                f"unlisted-authority-caller: {path} adds a restart authority call outside {INVENTORY} watched_files"
            )
        if _new_matches(writer_re, old, new):
            messages.append(
                f"unlisted-writer: {path} adds a writer primitive derived from {INVENTORY} outside watched_files"
            )
    return messages


def _anomaly_activation_messages(
    root: Path,
    base: str,
    head_ref: str,
    changed: set[str],
) -> list[str]:
    messages: list[str] = []
    for path in sorted(changed):
        if (
            not _production_semantic(path)
            or path in ALLOWED_ANOMALY_SHADOW_PATHS
            or "/tests/" in path
        ):
            continue
        if _new_matches(ANOMALY_RE, _text(root, base, path), _text(root, head_ref, path)):
            messages.append(
                f"anomaly-transport-activation: {path} activates restart anomaly production, ingestion, dependency, or delivery during refactor"
            )
    return messages


def repository_messages(
    root: Path,
    *,
    base_ref: str | None = None,
    head_ref: str = "HEAD",
) -> list[str]:
    root = Path(root)
    selected = base_ref or selected_base_ref(root)
    if selected is None:
        return ["protected-base-unresolved: configure GITHUB_BASE_REF or FKST_RESTART_PREFLIGHT_BASE_REF"]
    base = protected_merge_base(root, selected)
    if base is None:
        return [f"protected-base-unresolved: cannot resolve merge base for {selected}"]

    try:
        paths = _tracked_paths(root, head_ref)
        changed = _changed_paths(root, base)
    except RuntimeError as error:
        return [f"protected-base-unresolved: {error}"]

    watched, writer_tokens, messages = _inventory_contract(root, head_ref)
    messages.extend(_tracked_attestation_messages(root, head_ref, paths))

    if SEMANTIC_TREE_CONTROL in changed:
        messages.append(
            f"exclusion-control-changed: {SEMANTIC_TREE_CONTROL} differs from the protected base"
        )

    changed_checkers = sorted(changed & CHECKER_CONTROLS)
    changed_semantics = sorted(path for path in changed if _production_semantic(path))
    if changed_checkers and changed_semantics:
        messages.append(
            "checker-checked-cochange: checker controls and production restart semantics changed together "
            f"(checkers={','.join(changed_checkers)}; semantics={','.join(changed_semantics)})"
        )

    messages.extend(_exposure_messages(root, base, head_ref, changed, watched))
    if writer_tokens:
        messages.extend(
            _unlisted_caller_messages(root, base, head_ref, changed, watched, writer_tokens)
        )
    messages.extend(_anomaly_activation_messages(root, base, head_ref, changed))
    return messages


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    messages = repository_messages(root)
    if messages:
        for message in messages:
            print(f"R9-RESTART-PREFLIGHT: {message}")
        return 1
    print("OK: R9 protected-base restart preflight passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
