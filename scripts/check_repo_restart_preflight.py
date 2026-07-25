#!/usr/bin/env python3
"""Protected-base preflight for R9 restart-lifecycle refactor additions."""

from __future__ import annotations

from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tomllib
from typing import Any, Iterable

import check_repo_intent_bounded_replay as intent_replay
from intent_bounded_replay.normalize import loads_json

INVENTORY = "migration/restart-lifecycle.inventory.json"
SEMANTIC_TREE_CONTROL = "scripts/intent_bounded_replay/semantic_tree.py"
COCHANGE_GRANT_DIR = "migration/restart-cochange-grants/"
COCHANGE_GRANT_SCHEMA = "fkst.restart-cochange-grant.v1"
CHECKER_CONTROLS = {
    "scripts/check_repo_intent_bounded_replay.py",
    "scripts/check_repo_restart_preflight.py",
    "scripts/intent_bounded_replay/compare.py",
    "scripts/intent_bounded_replay/corpus_manifest.json",
    "scripts/intent_bounded_replay/normalize.py",
    SEMANTIC_TREE_CONTROL,
}
COCHANGE_GRANT_FIELDS = {"schema", "entries", "grant_sha256"}
COCHANGE_ENTRY_FIELDS = {"path", "status", "old_blob", "new_blob"}
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
    # The devloop library manifest only registers the shadow analyzer's
    # public export; it cannot declare anomaly transport (queues, ops
    # dependency, delivery live in department/ops manifests, still guarded).
    "libraries/devloop/fkst.toml",
}
ATTESTATION_SCHEMA = "fkst.intent-diff-attestation.v1"
SAFE_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*")
BLOB_OID_RE = re.compile(r"[0-9a-f]{40}")
R7_QUEUES = {
    "github-devloop.restart_transition_anomaly",
    "github-devloop-pr.restart_transition_anomaly",
}
R7_INGESTION = "github-devloop-ops.observability"
R7_OWNER_DEPARTMENTS = {
    "packages/github-devloop/departments/observe_issue/main.lua": "github-devloop.observe_issue",
    "packages/github-devloop-pr/departments/observe_pr/main.lua": "github-devloop-pr.observe_pr",
}
R7_SINK_INVENTORIES = {
    "packages/github-devloop/core/restart/sink_inventory.lua": "github-devloop",
    "packages/github-devloop-pr/core/restart/sink_inventory.lua": "github-devloop-pr",
}
R7_OPS_DEPARTMENT = "packages/github-devloop-ops/departments/observability/main.lua"
R7_OPS_MANIFEST = "packages/github-devloop-ops/fkst.toml"
R7_PRODUCTION_PATHS = set(R7_OWNER_DEPARTMENTS) | set(R7_SINK_INVENTORIES) | {
    R7_OPS_DEPARTMENT,
    R7_OPS_MANIFEST,
}
OLD_AUTHORITY_PATHS = {
    "libraries/devloop/restart_effect_seal.lua",
    "packages/github-devloop/loop_department_caps.lua",
    "packages/github-devloop-pr/review_loop_department_caps.lua",
}
OLD_AUTHORITY_PATTERNS = {
    "libraries/devloop/state.lua": re.compile(
        r"\b(?:transition_status|versioned_transition_status|cyclic_transition_status)\b"
    ),
    "libraries/devloop/di/providers.lua": re.compile(r'["]versioned_transition_status["]'),
    "libraries/devloop/fkst.toml": re.compile(r'["]devloop\.restart_effect_seal["]'),
}
DURABLE_TRANSPORT_RE = re.compile(
    r"\b(?:source_ref|dedup_key|delivery_id|delivery_key|durable_identity|event_id|"
    r"idempotency_key|message_id|content_fetch|rehydrat[A-Za-z0-9_]*)\b"
)
GRANT_TRANSPORT_RE = re.compile(
    r"\b(?:grant|mint_grant|verify_grant|restart_sink_grants|transition_grant|effect_grant|"
    r"requires?_grant|grant_required)\b"
)
LUA_LIST_RE_TEMPLATE = r"\b%s\s*=\s*\{(?P<body>[^{}]*)\}"
LUA_STRING_RE = re.compile(r"[\"']([^\"']+)[\"']")
RAISE_CALL_RE = re.compile(r"\b(?:raise|log_raise)\s*\((?P<body>.{0,800}?)\)", re.DOTALL)
QUEUE_RECORD_RE = re.compile(
    r"\bqueue\s*\(\s*[\"'](?P<department>[^\"']+)[\"']\s*,\s*"
    r"[\"'](?P<queue>[^\"']+)[\"']\s*,\s*[\"'](?P<authority>[^\"']+)[\"']",
    re.DOTALL,
)
BLOB_OID_RE = re.compile(r"[0-9a-f]{40}")


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


def _changed_paths(root: Path, base: str, head_ref: str) -> set[str]:
    result = _git(
        root,
        ["diff", "--name-only", "-z", "--no-renames", base, head_ref, "--"],
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


def _checker_control(path: str) -> bool:
    return path in CHECKER_CONTROLS or path.startswith(COCHANGE_GRANT_DIR)


def _git_object_exists(root: Path, ref: str, path: str) -> bool:
    return _git(root, ["cat-file", "-e", f"{ref}:{path}"]).returncode == 0


def _blob_oid(root: Path, ref: str, path: str) -> str:
    result = _git(
        root,
        ["rev-parse", "--verify", "--quiet", "--end-of-options", f"{ref}:{path}"],
    )
    oid = result.stdout.strip()
    if result.returncode != 0 or BLOB_OID_RE.fullmatch(oid) is None:
        return ""
    return oid


def _cochange_delta_entry(root: Path, base: str, head_ref: str, path: str) -> dict[str, str] | None:
    old_blob = _blob_oid(root, base, path)
    new_blob = _blob_oid(root, head_ref, path)
    if old_blob and new_blob:
        status = "M"
    elif old_blob:
        status = "D"
    elif new_blob:
        status = "A"
    else:
        return None
    return {
        "path": path,
        "status": status,
        "old_blob": old_blob,
        "new_blob": new_blob,
    }


# Admission binds only git-native blob OIDs and stdlib JSON; it does not depend on
# a HEAD-tamperable repo parser/canonicalizer. Without a valid base-resident grant,
# the conservative cochange rejection remains byte-identical.
def _cochange_promotion_admitted(
    root: Path,
    base: str,
    head_ref: str,
    changed_checkers: Iterable[str],
    changed_semantics: Iterable[str],
) -> bool:
    delta_paths = set(changed_checkers) | set(changed_semantics)
    expected_entries: dict[str, dict[str, str]] = {}
    for path in delta_paths:
        entry = _cochange_delta_entry(root, base, head_ref, path)
        if entry is None:
            return False
        expected_entries[path] = entry

    try:
        grant_paths = sorted(
            path
            for path in _tracked_paths(root, base)
            if path.startswith(COCHANGE_GRANT_DIR) and path.endswith(".json")
        )
    except RuntimeError:
        return False

    for grant_path in grant_paths:
        if not _git_object_exists(root, base, grant_path):
            continue
        base_blob = _blob(root, base, grant_path)
        if base_blob != _blob(root, head_ref, grant_path):
            continue
        try:
            document = json.loads(base_blob)
        except (TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(document, dict) or set(document) != COCHANGE_GRANT_FIELDS:
            continue
        if document.get("schema") != COCHANGE_GRANT_SCHEMA:
            continue
        grant_sha256 = document.get("grant_sha256")
        if not isinstance(grant_sha256, str):
            continue
        body: dict[str, Any] = dict(document)
        del body["grant_sha256"]
        canonical_body = json.dumps(
            body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        if hashlib.sha256(canonical_body).hexdigest() != grant_sha256:
            continue

        entries = document.get("entries")
        if not isinstance(entries, list):
            continue
        actual_entries: dict[str, dict[str, str]] = {}
        valid_entries = True
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != COCHANGE_ENTRY_FIELDS:
                valid_entries = False
                break
            path = entry.get("path")
            if not isinstance(path, str) or not path or path in actual_entries:
                valid_entries = False
                break
            if entry.get("status") not in {"M", "A", "D"}:
                valid_entries = False
                break
            old_blob = entry.get("old_blob")
            new_blob = entry.get("new_blob")
            if not isinstance(old_blob, str) or not isinstance(new_blob, str):
                valid_entries = False
                break
            if old_blob and BLOB_OID_RE.fullmatch(old_blob) is None:
                valid_entries = False
                break
            if new_blob and BLOB_OID_RE.fullmatch(new_blob) is None:
                valid_entries = False
                break
            actual_entries[path] = entry
        if valid_entries and actual_entries == expected_entries:
            return True
    return False


def _new_matches(pattern: re.Pattern[str], old: str, new: str) -> Counter[str]:
    return Counter(pattern.findall(new)) - Counter(pattern.findall(old))


def _lua_list_values(text: str, field: str) -> Counter[str]:
    pattern = re.compile(LUA_LIST_RE_TEMPLATE % re.escape(field), re.DOTALL)
    return Counter(
        value
        for match in pattern.finditer(text)
        for value in LUA_STRING_RE.findall(match.group("body"))
    )


def _added_lua_values(root: Path, base: str, head_ref: str, path: str, field: str) -> Counter[str]:
    return _lua_list_values(_text(root, head_ref, path), field) - _lua_list_values(_text(root, base, path), field)


def _qualify_queue(owner: str, queue: str) -> str:
    return queue if "." in queue else f"{owner}.{queue}"


def _raise_records(text: str, path: str) -> Counter[str]:
    department = R7_OWNER_DEPARTMENTS[path]
    owner = department.split(".", 1)[0]
    return Counter(
        f"{department}->{_qualify_queue(owner, value)}"
        for call in RAISE_CALL_RE.finditer(text)
        for value in LUA_STRING_RE.findall(call.group("body"))
        if ANOMALY_RE.search(value)
    )


def _sink_records(text: str, owner: str) -> Counter[str]:
    return Counter(
        _qualify_queue(owner, match.group("queue"))
        for match in QUEUE_RECORD_RE.finditer(text)
        if ANOMALY_RE.search(match.group("queue"))
        and match.group("authority") == "grantless-telemetry"
    )


def _event_dependencies(text: str) -> set[str]:
    if not text:
        return set()
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return set()
    dependencies = document.get("event_deps", {}).get("packages", [])
    return set(dependencies) if isinstance(dependencies, list) else set()


def _step8_complete(root: Path, base: str, head_ref: str) -> bool:
    for ref in (base, head_ref):
        tracked = set(_tracked_paths(root, ref))
        if tracked & OLD_AUTHORITY_PATHS:
            return False
        if any(pattern.search(_text(root, ref, path)) for path, pattern in OLD_AUTHORITY_PATTERNS.items()):
            return False
    return True


def _anomaly_manifest(
    root: Path, base: str, head_ref: str, changed: set[str], paths: list[str],
) -> dict[str, object] | None:
    changed_manifests = sorted(
        path for path in changed
        if re.fullmatch(r"migration/intent-diffs/[1-9][0-9]*\.json", path)
    )
    if len(changed_manifests) != 1:
        return None
    relative = changed_manifests[0]
    try:
        artifact = loads_json(_blob(root, head_ref, relative))
    except Exception:
        return None
    if not isinstance(artifact, dict) or "anomaly_transport" not in artifact:
        return None
    allowlist, allowlist_messages = intent_replay._parse_allowlist(
        intent_replay.ALLOWLIST,
        _text(root, head_ref, intent_replay.ALLOWLIST).splitlines(),
    )
    if allowlist_messages or relative not in allowlist:
        return None
    if intent_replay._bound_manifest_messages(root, artifact, relative, base, head_ref):
        return None
    identity = artifact["one_use_identity"]
    for path in paths:
        if path == relative or re.fullmatch(r"migration/intent-diffs/[1-9][0-9]*\.json", path) is None:
            continue
        try:
            other = loads_json(_blob(root, head_ref, path))
        except Exception:
            continue
        if isinstance(other, dict) and other.get("one_use_identity") == identity:
            return None
    return artifact


def _r7_anomaly_admitted(
    root: Path, base: str, head_ref: str, changed: set[str], paths: list[str],
) -> bool:
    artifact = _anomaly_manifest(root, base, head_ref, changed, paths)
    if artifact is None or not _step8_complete(root, base, head_ref):
        return False

    owner_produces: Counter[str] = Counter()
    deliveries: Counter[str] = Counter()
    for path, department in R7_OWNER_DEPARTMENTS.items():
        owner = department.split(".", 1)[0]
        owner_produces.update(
            _qualify_queue(owner, queue)
            for queue in _added_lua_values(root, base, head_ref, path, "produces").elements()
        )
        deliveries.update(
            _raise_records(_text(root, head_ref, path), path)
            - _raise_records(_text(root, base, path), path)
        )
    consumes = _added_lua_values(root, base, head_ref, R7_OPS_DEPARTMENT, "consumes")
    ephemeral = _added_lua_values(root, base, head_ref, R7_OPS_DEPARTMENT, "ephemeral")
    dependencies = _event_dependencies(_text(root, head_ref, R7_OPS_MANIFEST)) - _event_dependencies(
        _text(root, base, R7_OPS_MANIFEST)
    )
    sinks: Counter[str] = Counter()
    for path, owner in R7_SINK_INVENTORIES.items():
        sinks.update(
            _sink_records(_text(root, head_ref, path), owner)
            - _sink_records(_text(root, base, path), owner)
        )

    expected_deliveries = {
        "github-devloop.observe_issue->github-devloop.restart_transition_anomaly",
        "github-devloop-pr.observe_pr->github-devloop-pr.restart_transition_anomaly",
    }
    exact_shape = (
        owner_produces == Counter({queue: 1 for queue in R7_QUEUES})
        and consumes == Counter({queue: 1 for queue in R7_QUEUES})
        and ephemeral == Counter({queue: 1 for queue in R7_QUEUES})
        and deliveries == Counter({delivery: 1 for delivery in expected_deliveries})
        and sinks == Counter({queue: 1 for queue in R7_QUEUES})
        and dependencies == {"github-devloop-pr"}
    )
    semantic_changed = {
        path for path in changed
        if path.endswith((".lua", ".toml"))
        and path.startswith(("packages/github-devloop/", "packages/github-devloop-pr/", "packages/github-devloop-ops/"))
        and "/tests/" not in path
    }
    no_other_behavior = semantic_changed == R7_PRODUCTION_PATHS and all(
        artifact[field] == []
        for field in ("changed_row_ids", "changed_edge_ids", "changed_policy_ids")
    )
    no_durable_or_grant_path = all(
        not _new_matches(pattern, _text(root, base, path), _text(root, head_ref, path))
        for path in R7_PRODUCTION_PATHS
        for pattern in (DURABLE_TRANSPORT_RE, GRANT_TRANSPORT_RE)
    )
    actual_atoms = {
        "qualified_queues": sorted(owner_produces, key=lambda item: item.encode("utf-8")),
        "ops_dependency": next(iter(dependencies), ""),
        "ephemeral_consumes": sorted(ephemeral, key=lambda item: item.encode("utf-8")),
        "ingestion": R7_INGESTION if consumes else "",
        "package_visible_delivery_delta": ";".join(sorted(deliveries, key=lambda item: item.encode("utf-8"))),
    }
    return exact_shape and no_other_behavior and no_durable_or_grant_path and artifact["anomaly_transport"] == actual_atoms


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
    if messages and _r7_anomaly_admitted(root, base, head_ref, changed, _tracked_paths(root, head_ref)):
        return []
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
        changed = _changed_paths(root, base, head_ref)
    except RuntimeError as error:
        return [f"protected-base-unresolved: {error}"]

    watched, writer_tokens, messages = _inventory_contract(root, head_ref)
    messages.extend(_tracked_attestation_messages(root, head_ref, paths))

    if SEMANTIC_TREE_CONTROL in changed:
        messages.append(
            f"exclusion-control-changed: {SEMANTIC_TREE_CONTROL} differs from the protected base"
        )

    changed_checkers = sorted(path for path in changed if _checker_control(path))
    changed_semantics = sorted(path for path in changed if _production_semantic(path))
    if changed_checkers and changed_semantics and not _cochange_promotion_admitted(
        root, base, head_ref, changed_checkers, changed_semantics
    ):
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
