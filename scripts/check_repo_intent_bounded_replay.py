#!/usr/bin/env python3
"""R9 intent-bounded-replay enforcement for the refactor phase."""

from __future__ import annotations

from decimal import Decimal
import hashlib
from pathlib import Path
import re
import subprocess
from typing import Any

from intent_bounded_replay.compare import compare_report
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
    loads_json,
)
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256

import ratchet_base


ALLOWLIST = "migration/intent-bounded-replay.allowlist"
INTENT_DIFF_DIR = "migration/intent-diffs"
THINKING_OLD_CORPUS = "migration/intent_bounded_replay/corpus/thinking.json"
THINKING_NEW_TRACE = ".fkst/run/r9-thinking-new-trace.json"
ISSUE_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/issue-reconcile.json"
ISSUE_RECONCILE_NEW_TRACE = ".fkst/run/r9-issue-reconcile-new-trace.json"
LOOP_PLAIN_OLD_CORPUS = "migration/intent_bounded_replay/corpus/loop-plain.json"
LOOP_PLAIN_NEW_TRACE = ".fkst/run/r9-loop-plain-new-trace.json"
IMPLEMENT_ACTIVATION_OLD_CORPUS = "migration/intent_bounded_replay/corpus/implement-activation.json"
IMPLEMENT_ACTIVATION_NEW_TRACE = ".fkst/run/r9-implement-activation-new-trace.json"
AWAITING_PR_OLD_CORPUS = "migration/intent_bounded_replay/corpus/awaiting-pr.json"
AWAITING_PR_NEW_TRACE = ".fkst/run/r9-awaiting-pr-new-trace.json"
TIMEOUT_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/timeout-reconcile.json"
TIMEOUT_RECONCILE_NEW_TRACE = ".fkst/run/r9-timeout-reconcile-new-trace.json"
OBSERVE_ISSUE_ENTRY_OLD_CORPUS = "migration/intent_bounded_replay/corpus/observe-issue-entry.json"
OBSERVE_ISSUE_ENTRY_NEW_TRACE = ".fkst/run/r9-observe-issue-entry-new-trace.json"
PR_REVIEW_RESULT_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-result.json"
PR_REVIEW_RESULT_NEW_TRACE = ".fkst/run/r9-pr-review-result-new-trace.json"
PR_REVIEW_META_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-meta.json"
PR_REVIEW_META_NEW_TRACE = ".fkst/run/r9-pr-review-meta-new-trace.json"
PR_FIX_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-fix.json"
PR_FIX_NEW_TRACE = ".fkst/run/r9-pr-fix-new-trace.json"
PROTECTED_MODULES = (
    "scripts/intent_bounded_replay/normalize.py",
    "scripts/intent_bounded_replay/compare.py",
    "scripts/intent_bounded_replay/semantic_tree.py",
)
MANIFEST_RE = re.compile(r"(?P<pr>[1-9][0-9]*)\.json")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}")

MANIFEST_FIELDS = (
    "schema",
    "intent",
    "pr_number",
    "base_sha",
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "changed_row_ids",
    "changed_edge_ids",
    "changed_policy_ids",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "cause",
    "review_reference",
    "one_use_identity",
    "manifest_sha256",
)
ATTESTATION_FIELDS = (
    "schema",
    "pr_number",
    "base_sha",
    "head_sha",
    "manifest_path",
    "manifest_blob_sha256",
    "manifest_sha256",
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "result",
    "attestation_sha256",
)
MANIFEST_HASH_FIELDS = (
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "manifest_sha256",
)
ATTESTATION_HASH_FIELDS = (
    "manifest_blob_sha256",
    "manifest_sha256",
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "attestation_sha256",
)


def _exact_fields_messages(
    artifact: dict[str, Any], expected: set[str], relative: str
) -> list[str]:
    actual = set(artifact)
    messages: list[str] = []
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing:
        messages.append(f"{relative} is missing fields: {', '.join(missing)}")
    if extra:
        messages.append(f"{relative} has unexpected fields: {', '.join(extra)}")
    return messages


def _admission_trace_shape_messages(
    artifact: dict[str, Any], relative: str, schema: str, family: str,
    owner: str = "github-devloop",
) -> list[str]:
    messages = _exact_fields_messages(
        artifact,
        {"schema", "owner", "family", "fixtures", "artifact_sha256"},
        relative,
    )
    if artifact.get("schema") != schema:
        messages.append(f"{relative} schema must be {schema}")
    if artifact.get("owner") != owner:
        messages.append(f"{relative} owner must be {owner}")
    if artifact.get("family") != family:
        messages.append(f"{relative} family must be {family}")
    fixtures = artifact.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        return messages + [f"{relative} fixtures must be a non-empty array"]

    fixture_ids: list[str] = []
    for index, fixture in enumerate(fixtures):
        label = f"{relative} fixtures[{index}]"
        if not isinstance(fixture, dict):
            messages.append(f"{label} must be an object")
            continue
        messages.extend(
            _exact_fields_messages(
                fixture,
                {
                    "fixture_id",
                    "edge_id",
                    "cas_status",
                    "reason_code",
                    "cas_outcome",
                    "effect_entitlement_id",
                    "granted_effect_ids",
                    "observable_writes",
                },
                label,
            )
        )
        for field in ("fixture_id", "edge_id", "cas_status", "reason_code", "cas_outcome"):
            if not _nonempty_string(fixture.get(field)):
                messages.append(f"{label} field {field} must be a non-empty string")
        if _nonempty_string(fixture.get("fixture_id")):
            fixture_ids.append(fixture["fixture_id"])
        entitlement = fixture.get("effect_entitlement_id")
        if entitlement is not None and not _nonempty_string(entitlement):
            messages.append(f"{label} effect_entitlement_id must be string or null")
        effect_ids = fixture.get("granted_effect_ids")
        if not _string_list(effect_ids):
            messages.append(f"{label} granted_effect_ids must be an array of strings")
            effect_ids = []
        writes = fixture.get("observable_writes")
        if not isinstance(writes, list):
            messages.append(f"{label} observable_writes must be an array")
            continue
        observed_ids: list[str] = []
        for write_index, write in enumerate(writes, 1):
            write_label = f"{label} observable_writes[{write_index - 1}]"
            if not isinstance(write, dict):
                messages.append(f"{write_label} must be an object")
                continue
            messages.extend(
                _exact_fields_messages(
                    write,
                    {"ordinal", "effect_id", "write_kind", "marker_write"},
                    write_label,
                )
            )
            if not _positive_integer(write.get("ordinal")) or int(write["ordinal"]) != write_index:
                messages.append(f"{write_label} ordinal must match its one-based position")
            for field in ("effect_id", "write_kind"):
                if not _nonempty_string(write.get(field)):
                    messages.append(f"{write_label} field {field} must be a non-empty string")
            if not isinstance(write.get("marker_write"), bool):
                messages.append(f"{write_label} marker_write must be boolean")
            if _nonempty_string(write.get("effect_id")):
                observed_ids.append(write["effect_id"])
        if fixture.get("cas_status") == "apply":
            if observed_ids != effect_ids:
                messages.append(f"{label} granted_effect_ids must equal observable write order")
        elif observed_ids:
            messages.append(
                f"{label} {fixture.get('cas_status')} admission must not include observable writes"
            )

    if fixture_ids != sorted(fixture_ids) or len(fixture_ids) != len(set(fixture_ids)):
        messages.append(f"{relative} fixture_id values must be unique and byte-sorted")
    messages.extend(_hash_field_messages(artifact, ("artifact_sha256",), relative))
    messages.extend(_self_hash_messages(artifact, "artifact_sha256", relative))
    return messages


def _trace_pair_messages(
    root: Path,
    old_relative: str,
    new_relative: str,
    schema: str,
    family: str,
    owner: str = "github-devloop",
) -> list[str]:
    old_path = root / old_relative
    if not old_path.is_file():
        return [f"missing protected input: {old_relative}"]
    old, messages = _load_json_object(old_path)
    if old is None:
        return [
            message.replace(old_path.as_posix(), old_relative, 1)
            for message in messages
        ]
    messages.extend(
        _admission_trace_shape_messages(old, old_relative, schema, family, owner)
    )

    new_path = root / new_relative
    if not new_path.is_file():
        return messages
    new, load_messages = _load_json_object(new_path)
    messages.extend(
        message.replace(new_path.as_posix(), new_relative, 1)
        for message in load_messages
    )
    if new is None:
        return messages
    messages.extend(
        _admission_trace_shape_messages(new, new_relative, schema, family, owner)
    )
    if messages:
        return messages
    report = compare_report(old, new)
    if not report["equal"]:
        messages.append(
            f"{family} trace canonical hash mismatch: "
            f"OLD={report['old_hash']} NEW={report['new_hash']} "
            f"first_divergence={report.get('first_divergence', '')}"
        )
    return messages


def _admission_trace_messages(root: Path) -> list[str]:
    messages = _trace_pair_messages(
        root,
        THINKING_OLD_CORPUS,
        THINKING_NEW_TRACE,
        "restart-thinking-trace.v1",
        "thinking",
    )
    messages.extend(
        _trace_pair_messages(
            root,
            ISSUE_RECONCILE_OLD_CORPUS,
            ISSUE_RECONCILE_NEW_TRACE,
            "restart-issue-reconcile-trace.v1",
            "issue-reconcile",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            LOOP_PLAIN_OLD_CORPUS,
            LOOP_PLAIN_NEW_TRACE,
            "restart-loop-plain-trace.v1",
            "loop-plain",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            IMPLEMENT_ACTIVATION_OLD_CORPUS,
            IMPLEMENT_ACTIVATION_NEW_TRACE,
            "restart-implement-activation-trace.v1",
            "implement-activation",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            AWAITING_PR_OLD_CORPUS,
            AWAITING_PR_NEW_TRACE,
            "restart-awaiting-pr-trace.v1",
            "awaiting-pr",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            TIMEOUT_RECONCILE_OLD_CORPUS,
            TIMEOUT_RECONCILE_NEW_TRACE,
            "restart-timeout-reconcile-trace.v1",
            "timeout-reconcile",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            OBSERVE_ISSUE_ENTRY_OLD_CORPUS,
            OBSERVE_ISSUE_ENTRY_NEW_TRACE,
            "restart-observe-issue-entry-trace.v1",
            "observe-issue-entry",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            PR_REVIEW_RESULT_OLD_CORPUS,
            PR_REVIEW_RESULT_NEW_TRACE,
            "restart-pr-review-result-trace.v1",
            "pr-review-result",
            owner="github-devloop-pr",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            PR_REVIEW_META_OLD_CORPUS,
            PR_REVIEW_META_NEW_TRACE,
            "restart-pr-review-meta-trace.v1",
            "pr-review-meta",
            owner="github-devloop-pr",
        )
    )
    messages.extend(
        _trace_pair_messages(
            root,
            PR_FIX_OLD_CORPUS,
            PR_FIX_NEW_TRACE,
            "restart-pr-fix-trace.v1",
            "pr-fix",
            owner="github-devloop-pr",
        )
    )
    return messages


def admission_trace_status(root: Path) -> str:
    emitted = [
        relative
        for relative in (
            THINKING_NEW_TRACE,
            ISSUE_RECONCILE_NEW_TRACE,
            LOOP_PLAIN_NEW_TRACE,
            IMPLEMENT_ACTIVATION_NEW_TRACE,
            AWAITING_PR_NEW_TRACE,
            TIMEOUT_RECONCILE_NEW_TRACE,
            OBSERVE_ISSUE_ENTRY_NEW_TRACE,
            PR_REVIEW_RESULT_NEW_TRACE,
            PR_REVIEW_META_NEW_TRACE,
            PR_FIX_NEW_TRACE,
        )
        if (Path(root) / relative).is_file()
    ]
    if not emitted:
        return "admission trace comparisons skipped: emitted traces are absent"
    return "admission trace comparisons executed by canonical artifact hash: " + ", ".join(emitted)


def _relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _positive_integer(value: Any) -> bool:
    return isinstance(value, Decimal) and value >= 1 and value == value.to_integral_value()


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _load_json_object(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    relative = path.as_posix()
    try:
        artifact = loads_json(path.read_bytes())
    except Exception as error:
        return None, [f"{relative} is not valid canonical JSON input: {error}"]
    if not isinstance(artifact, dict):
        return None, [f"{relative} must contain a JSON object"]
    return artifact, []


def _required_field_messages(
    artifact: dict[str, Any], required: tuple[str, ...], relative: str
) -> list[str]:
    missing = [field for field in required if field not in artifact]
    if not missing:
        return []
    return [f"{relative} is missing required fields: {', '.join(missing)}"]


def _hash_field_messages(
    artifact: dict[str, Any], fields: tuple[str, ...], relative: str
) -> list[str]:
    return [
        f"{relative} field {field} must be a lowercase SHA-256"
        for field in fields
        if field in artifact
        and (not isinstance(artifact[field], str) or SHA256_RE.fullmatch(artifact[field]) is None)
    ]


def _self_hash_messages(
    artifact: dict[str, Any], field: str, relative: str
) -> list[str]:
    if field not in artifact or not isinstance(artifact[field], str):
        return []
    try:
        if field == "attestation_sha256":
            body = dict(artifact)
            del body[field]
            actual = hashlib.sha256(canonical_json(body)).hexdigest()
        else:
            actual = canonical_artifact_hash_v1(artifact)
    except Exception as error:
        return [f"{relative} cannot compute {field}: {error}"]
    if artifact[field] == actual:
        return []
    return [f"{relative} {field} mismatch: declared {artifact[field]}, computed {actual}"]


def _manifest_messages(
    artifact: dict[str, Any], relative: str, filename_pr: int
) -> list[str]:
    messages = _required_field_messages(artifact, MANIFEST_FIELDS, relative)
    if messages:
        return messages
    if artifact["schema"] != "fkst.intent-diff.v2":
        messages.append(f"{relative} schema must be fkst.intent-diff.v2")
    if artifact["intent"] != "behavior-change":
        messages.append(f"{relative} intent must be behavior-change")
    if not _positive_integer(artifact["pr_number"]):
        messages.append(f"{relative} pr_number must be a positive integer")
    elif int(artifact["pr_number"]) != filename_pr:
        messages.append(f"{relative} pr_number must match its filename")
    if not isinstance(artifact["base_sha"], str) or GIT_SHA_RE.fullmatch(artifact["base_sha"]) is None:
        messages.append(f"{relative} base_sha must be a lowercase Git object ID")
    for field in ("changed_row_ids", "changed_edge_ids", "changed_policy_ids"):
        if not _string_list(artifact[field]):
            messages.append(f"{relative} field {field} must be an array of strings")
    for field in ("cause", "review_reference", "one_use_identity"):
        if not _nonempty_string(artifact[field]):
            messages.append(f"{relative} field {field} must be a non-empty string")
    if "head_sha" in artifact:
        messages.append(f"{relative} must not contain authoritative head_sha")
    messages.extend(_hash_field_messages(artifact, MANIFEST_HASH_FIELDS, relative))
    messages.extend(_self_hash_messages(artifact, "manifest_sha256", relative))
    return messages


def _parse_allowlist(source: str, lines: list[str]) -> tuple[set[str], list[str]]:
    entries: set[str] = set()
    messages: list[str] = []
    for line_number, raw in enumerate(lines, 1):
        entry = raw.split("#", 1)[0].strip()
        if not entry:
            continue
        if re.fullmatch(r"migration/intent-diffs/[1-9][0-9]*\.json", entry) is None:
            messages.append(f"{source}:{line_number} is not a numbered intent-diff manifest path")
            continue
        entries.add(entry)
    return entries, messages


def _allowlist_entries(path: Path, root: Path) -> tuple[set[str], list[str]]:
    if not path.is_file():
        return set(), [f"missing protected input: {_relative(path, root)}"]
    return _parse_allowlist(ALLOWLIST, path.read_text(encoding="utf-8").splitlines())


def _base_allowlist(root: Path) -> tuple[str, set[str] | None, list[str]]:
    status, text = ratchet_base.file_at_base(root, ALLOWLIST)
    if status != "present":
        return status, set() if status == "absent" else None, []
    assert text is not None
    entries, messages = _parse_allowlist(f"protected-base:{ALLOWLIST}", text.splitlines())
    return status, entries, messages


def _head_sha(root: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD^{commit}"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise RuntimeError(f"git rev-parse HEAD failed ({result.returncode}): {detail}")
    return result.stdout.strip().lower()


def _attestation_messages(
    root: Path,
    path: Path,
    artifact: dict[str, Any],
    manifests: dict[str, dict[str, Any]],
) -> list[str]:
    relative = _relative(path, root)
    messages = _required_field_messages(artifact, ATTESTATION_FIELDS, relative)
    if messages:
        return messages
    if artifact["schema"] != "fkst.intent-diff-attestation.v1":
        messages.append(f"{relative} schema must be fkst.intent-diff-attestation.v1")
    if artifact["result"] != "approved":
        messages.append(f"{relative} result must be approved")
    if not _positive_integer(artifact["pr_number"]):
        messages.append(f"{relative} pr_number must be a positive integer")
        expected_manifest = None
    else:
        expected_manifest = f"{INTENT_DIFF_DIR}/{int(artifact['pr_number'])}.json"
        if artifact["manifest_path"] != expected_manifest:
            messages.append(f"{relative} manifest_path must be {expected_manifest}")
    for field in ("base_sha", "head_sha"):
        if not isinstance(artifact[field], str) or GIT_SHA_RE.fullmatch(artifact[field]) is None:
            messages.append(f"{relative} {field} must be a lowercase Git object ID")
    messages.extend(_hash_field_messages(artifact, ATTESTATION_HASH_FIELDS, relative))
    messages.extend(_self_hash_messages(artifact, "attestation_sha256", relative))
    if messages or expected_manifest is None:
        return messages

    manifest = manifests.get(expected_manifest)
    manifest_path = root / expected_manifest
    if manifest is None or not manifest_path.is_file():
        return messages + [f"{relative} references missing or invalid manifest {expected_manifest}"]
    manifest_blob = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if artifact["manifest_blob_sha256"] != manifest_blob:
        messages.append(
            f"{relative} manifest_blob_sha256 mismatch: declared {artifact['manifest_blob_sha256']}, computed {manifest_blob}"
        )
    if artifact["manifest_sha256"] != manifest.get("manifest_sha256"):
        messages.append(f"{relative} manifest_sha256 does not match {expected_manifest}")
    if artifact["base_sha"] != manifest.get("base_sha"):
        messages.append(f"{relative} base_sha does not match {expected_manifest}")
    for field in ("old_trace_sha256", "new_trace_sha256", "behavior_diff_sha256"):
        if artifact[field] != manifest.get(field):
            messages.append(f"{relative} {field} does not match {expected_manifest}")

    try:
        actual_head = _head_sha(root)
        actual_tree = semantic_tree_sha256(root)
        actual_diff = semantic_diff_sha256(root, artifact["base_sha"])
    except Exception as error:
        return messages + [f"{relative} cannot recompute semantic hashes: {error}"]
    if artifact["head_sha"] != actual_head:
        messages.append(f"{relative} head_sha mismatch: declared {artifact['head_sha']}, computed {actual_head}")
    for field, actual in (
        ("semantic_tree_sha256", actual_tree),
        ("semantic_diff_sha256", actual_diff),
    ):
        if artifact[field] != actual:
            messages.append(f"{relative} {field} mismatch: declared {artifact[field]}, computed {actual}")
        if manifest.get(field) != actual:
            messages.append(f"{expected_manifest} {field} mismatch: declared {manifest.get(field)}, computed {actual}")
    return messages


def repository_messages(root: Path, enforce_base: bool = False) -> list[str]:
    root = Path(root)
    messages = _admission_trace_messages(root)
    messages.extend(
        f"missing protected input: {relative}"
        for relative in PROTECTED_MODULES
        if not (root / relative).is_file()
    )
    intent_diff_dir = root / INTENT_DIFF_DIR
    if not intent_diff_dir.is_dir():
        messages.append(f"missing protected input directory: {INTENT_DIFF_DIR}")
        return messages

    allowlist, allowlist_messages = _allowlist_entries(root / ALLOWLIST, root)
    messages.extend(allowlist_messages)
    if enforce_base:
        base_status, base_allowlist, base_messages = _base_allowlist(root)
        messages.extend(base_messages)
        if base_status == "unresolved":
            messages.append(
                f"cannot resolve protected base {ALLOWLIST} to enforce the shrink-only ratchet"
            )
        elif base_allowlist is not None:
            for entry in sorted(allowlist - base_allowlist):
                messages.append(f"{entry} grows {ALLOWLIST} relative to the protected base")
    manifests: dict[str, dict[str, Any]] = {}
    attestations: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(intent_diff_dir.iterdir()):
        if not path.is_file() or path.name == ".gitkeep":
            continue
        relative = _relative(path, root)
        artifact, load_messages = _load_json_object(path)
        if load_messages:
            if path.suffix == ".json" or "attestation" in path.name:
                messages.extend(message.replace(path.as_posix(), relative, 1) for message in load_messages)
            continue
        assert artifact is not None
        if "attestation" in path.name:
            attestations.append((path, artifact))
            continue
        if path.suffix != ".json":
            continue
        match = MANIFEST_RE.fullmatch(path.name)
        if match is None:
            messages.append(f"{relative} is not named with its positive PR number")
            continue
        filename_pr = int(match.group("pr"))
        manifest_messages = _manifest_messages(artifact, relative, filename_pr)
        messages.extend(manifest_messages)
        if relative not in allowlist:
            messages.append(f"{relative} is not listed in {ALLOWLIST}")
        if not manifest_messages:
            manifests[relative] = artifact

    for path, artifact in attestations:
        messages.extend(_attestation_messages(root, path, artifact, manifests))
    return messages


if __name__ == "__main__":
    project_root = Path(__file__).resolve().parents[1]
    violations = repository_messages(project_root, enforce_base=True)
    if violations:
        for violation in violations:
            print(f"R9-INTENT-BOUNDED-REPLAY: {violation}")
        raise SystemExit(1)
    print("OK: R9 intent-bounded-replay refactor-phase checks passed; "
          + admission_trace_status(project_root))
