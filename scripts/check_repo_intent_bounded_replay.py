#!/usr/bin/env python3
"""R9 intent-bounded-replay enforcement for the refactor phase."""

from __future__ import annotations

from decimal import Decimal
import hashlib
import os
from pathlib import Path
import re
import subprocess
from typing import Any

from intent_bounded_replay.compare import compare_report
from intent_bounded_replay import delivery_authorization
from intent_bounded_replay.attestation import TRACE_PAIRS, attestation_messages
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
    loads_json,
)
from intent_bounded_replay.semantic_tree import semantic_diff_sha256, semantic_tree_sha256

import ratchet_base


ALLOWLIST = "migration/intent-bounded-replay.allowlist"
INTENT_DIFF_DIR = "migration/intent-diffs"
_TRACE_PAIRS_BY_FAMILY = {pair.family: pair for pair in TRACE_PAIRS}
THINKING_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["thinking"].old_path
THINKING_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["thinking"].new_path
ISSUE_RECONCILE_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["issue-reconcile"].old_path
ISSUE_RECONCILE_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["issue-reconcile"].new_path
LOOP_PLAIN_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["loop-plain"].old_path
LOOP_PLAIN_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["loop-plain"].new_path
IMPLEMENT_ACTIVATION_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["implement-activation"].old_path
IMPLEMENT_ACTIVATION_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["implement-activation"].new_path
AWAITING_PR_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["awaiting-pr"].old_path
AWAITING_PR_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["awaiting-pr"].new_path
TIMEOUT_RECONCILE_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["timeout-reconcile"].old_path
TIMEOUT_RECONCILE_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["timeout-reconcile"].new_path
OBSERVE_ISSUE_ENTRY_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["observe-issue-entry"].old_path
OBSERVE_ISSUE_ENTRY_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["observe-issue-entry"].new_path
PR_REVIEW_RESULT_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-review-result"].old_path
PR_REVIEW_RESULT_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-review-result"].new_path
PR_REVIEW_META_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-review-meta"].old_path
PR_REVIEW_META_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-review-meta"].new_path
PR_FIX_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-fix"].old_path
PR_FIX_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-fix"].new_path
PR_REVIEW_ACTIVATION_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-review-activation"].old_path
PR_REVIEW_ACTIVATION_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-review-activation"].new_path
OBSERVE_PR_FIX_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["observe-pr-fix"].old_path
OBSERVE_PR_FIX_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["observe-pr-fix"].new_path
PR_REVIEW_LOOP_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-review-loop"].old_path
PR_REVIEW_LOOP_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-review-loop"].new_path
PR_FIX_RECONCILE_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-fix-reconcile"].old_path
PR_FIX_RECONCILE_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-fix-reconcile"].new_path
PR_MERGE_OLD_CORPUS = _TRACE_PAIRS_BY_FAMILY["pr-merge"].old_path
PR_MERGE_NEW_TRACE = _TRACE_PAIRS_BY_FAMILY["pr-merge"].new_path
PROTECTED_MODULES = (
    "scripts/intent_bounded_replay/attestation.py",
    "scripts/intent_bounded_replay/normalize.py",
    "scripts/intent_bounded_replay/compare.py",
    "scripts/intent_bounded_replay/semantic_tree.py",
)
MANIFEST_RE = re.compile(r"(?P<pr>[1-9][0-9]*)\.json")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}")
BASE_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/\-]*")
SEMANTIC_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@#>;+-]*")

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
MANIFEST_HASH_FIELDS = (
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "manifest_sha256",
)
ANOMALY_TRANSPORT_FIELDS = {
    "qualified_queues",
    "ops_dependency",
    "ephemeral_consumes",
    "ingestion",
    "package_visible_delivery_delta",
}


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


CAPTURED_SINK_EFFECT_FIELDS = {
    "effect_id",
    "old_callsite",
    "old_probe_ids",
    "ordinal",
    "owning_effect_entitlement_ids",
    "sink_kind",
}


def _captured_sink_effect_messages(
    captures: Any, relative: str,
) -> list[str]:
    if not isinstance(captures, list) or not captures:
        return [f"{relative} captured_sink_effects must be a non-empty array"]
    messages: list[str] = []
    effect_ids: list[str] = []
    expected_prefixes = {
        "codex": "codex.dispatch:",
        "git": "git.push:",
        "merge": "github.merge:",
    }
    for index, capture in enumerate(captures, 1):
        label = f"{relative} captured_sink_effects[{index - 1}]"
        if not isinstance(capture, dict):
            messages.append(f"{label} must be an object")
            continue
        messages.extend(_exact_fields_messages(capture, CAPTURED_SINK_EFFECT_FIELDS, label))
        if not _positive_integer(capture.get("ordinal")) or int(capture["ordinal"]) != index:
            messages.append(f"{label} ordinal must match its one-based capture order")
        for field in ("effect_id", "old_callsite", "sink_kind"):
            if not _nonempty_string(capture.get(field)):
                messages.append(f"{label} field {field} must be a non-empty string")
        probe_ids = capture.get("old_probe_ids")
        if not _string_list(probe_ids) or not probe_ids:
            messages.append(f"{label} old_probe_ids must be a non-empty string array")
        entitlement_ids = capture.get("owning_effect_entitlement_ids")
        if not _string_list(entitlement_ids) or not entitlement_ids:
            messages.append(
                f"{label} owning_effect_entitlement_ids must be a non-empty string array"
            )
        kind = capture.get("sink_kind")
        prefix = expected_prefixes.get(kind)
        effect_id = capture.get("effect_id")
        if prefix is None:
            messages.append(f"{label} sink_kind must be codex, git, or merge")
        elif _nonempty_string(effect_id) and not effect_id.startswith(prefix):
            messages.append(f"{label} effect_id does not match sink_kind {kind}")
        if _nonempty_string(effect_id):
            effect_ids.append(effect_id)
    if len(effect_ids) != len(set(effect_ids)):
        messages.append(f"{relative} captured_sink_effects effect_id values must be unique")
    return messages


def _admission_trace_shape_messages(
    artifact: dict[str, Any], relative: str, schema: str, family: str,
    owner: str = "github-devloop",
) -> list[str]:
    expected_fields = {"schema", "owner", "family", "fixtures", "artifact_sha256"}
    if "captured_sink_effects" in artifact:
        expected_fields.add("captured_sink_effects")
    messages = _exact_fields_messages(artifact, expected_fields, relative)
    if "captured_sink_effects" in artifact:
        messages.extend(
            _captured_sink_effect_messages(artifact["captured_sink_effects"], relative)
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
        status = fixture.get("cas_status")
        if status == "apply":
            if observed_ids != effect_ids:
                messages.append(f"{label} granted_effect_ids must equal observable write order")
        elif status == "idempotent" and observed_ids:
            if entitlement is None:
                messages.append(f"{label} idempotent observable writes require an effect entitlement")
            if observed_ids != effect_ids:
                messages.append(f"{label} granted_effect_ids must equal observable write order")
        elif observed_ids:
            messages.append(
                f"{label} {status} admission must not include observable writes"
            )

    if fixture_ids != sorted(fixture_ids) or len(fixture_ids) != len(set(fixture_ids)):
        messages.append(f"{relative} fixture_id values must be unique and byte-sorted")
    messages.extend(_hash_field_messages(artifact, ("artifact_sha256",), relative))
    messages.extend(
        _self_hash_messages(_active_admission_trace(artifact), "artifact_sha256", relative)
    )
    return messages


def _active_admission_trace(artifact: dict[str, Any]) -> dict[str, Any]:
    return dict(artifact)


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
    report = compare_report(_active_admission_trace(old), _active_admission_trace(new))
    if not report["equal"]:
        messages.append(
            f"{family} trace canonical hash mismatch: "
            f"OLD={report['old_hash']} NEW={report['new_hash']} "
            f"first_divergence={report.get('first_divergence', '')}"
        )
    return messages


def _admission_trace_messages(root: Path) -> list[str]:
    messages: list[str] = []
    for pair in TRACE_PAIRS:
        messages.extend(
            _trace_pair_messages(
                root,
                pair.old_path,
                pair.new_path,
                pair.schema,
                pair.family,
                owner=pair.owner,
            )
        )
    return messages


def admission_trace_status(root: Path) -> str:
    emitted = [
        pair.new_path
        for pair in TRACE_PAIRS
        if (Path(root) / pair.new_path).is_file()
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


def _anomaly_transport_messages(value: Any, relative: str) -> list[str]:
    label = f"{relative} anomaly_transport"
    if not isinstance(value, dict):
        return [f"{label} must be an object"]
    messages = _exact_fields_messages(value, ANOMALY_TRANSPORT_FIELDS, label)
    for field in ("qualified_queues", "ephemeral_consumes"):
        identities = value.get(field)
        if not _string_list(identities) or not identities:
            messages.append(f"{label} field {field} must be a non-empty string array")
            continue
        canonical = sorted(set(identities), key=lambda item: item.encode("utf-8"))
        if identities != canonical:
            messages.append(f"{label} field {field} must be byte-sorted and unique")
        if any(SEMANTIC_ID_RE.fullmatch(item) is None for item in identities):
            messages.append(f"{label} field {field} contains a non-canonical semantic identity")
    for field in ("ops_dependency", "ingestion", "package_visible_delivery_delta"):
        identity = value.get(field)
        if not _nonempty_string(identity) or SEMANTIC_ID_RE.fullmatch(identity) is None:
            messages.append(f"{label} field {field} must be a canonical semantic identity")
    return messages
def _manifest_messages(
    artifact: dict[str, Any], relative: str, filename_pr: int
) -> list[str]:
    messages = _required_field_messages(artifact, MANIFEST_FIELDS, relative)
    if messages:
        return messages
    expected = set(MANIFEST_FIELDS)
    if "anomaly_transport" in artifact:
        expected.add("anomaly_transport")
    if "authorized_delivery_atoms" in artifact: expected.add("authorized_delivery_atoms")
    messages.extend(_exact_fields_messages(artifact, expected, relative))
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
    if "anomaly_transport" in artifact:
        messages.extend(_anomaly_transport_messages(artifact["anomaly_transport"], relative))
    messages.extend(delivery_authorization.delivery_authorization_messages(artifact, relative))
    return messages


def _bound_manifest_messages(
    root: Path,
    artifact: dict[str, Any],
    relative: str,
    base_sha: str,
    head_ref: str = "HEAD",
) -> list[str]:
    messages = _manifest_messages(artifact, relative, int(MANIFEST_RE.fullmatch(Path(relative).name).group("pr")))
    if messages:
        return messages
    if artifact["base_sha"] != base_sha:
        messages.append(f"{relative} base_sha must equal protected merge-base {base_sha}")
    expected_identity = "/".join((
        str(int(artifact["pr_number"])),
        artifact["base_sha"],
        artifact["semantic_tree_sha256"],
        artifact["semantic_diff_sha256"],
    ))
    if artifact["one_use_identity"] != expected_identity:
        messages.append(f"{relative} one_use_identity is not bound to pr/base/semantic hashes")
    try:
        actual_tree = semantic_tree_sha256(root, head_ref)
        actual_diff = semantic_diff_sha256(root, base_sha, head_ref)
    except Exception as error:
        return messages + [f"{relative} cannot recompute semantic hashes: {error}"]
    for field, actual in (
        ("semantic_tree_sha256", actual_tree),
        ("semantic_diff_sha256", actual_diff),
    ):
        if artifact[field] != actual:
            messages.append(f"{relative} {field} mismatch: declared {artifact[field]}, computed {actual}")
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


def _protected_base_sha(root: Path) -> str | None:
    explicit = os.environ.get("FKST_RESTART_PREFLIGHT_BASE_REF")
    if explicit and ".." not in explicit and BASE_REF_RE.fullmatch(explicit):
        result = subprocess.run(
            ["git", "merge-base", "HEAD", explicit], cwd=root, check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return ratchet_base.resolve_dev_merge_base(root)


def _base_allowlist(root: Path, base_sha: str | None = None) -> tuple[str, set[str] | None, list[str]]:
    if base_sha is not None:
        text = ratchet_base.show_file_at(root, base_sha, ALLOWLIST)
        if text is None:
            return "absent", set(), []
        entries, messages = _parse_allowlist(f"protected-base:{ALLOWLIST}", text.splitlines())
        return "present", entries, messages
    status, text = ratchet_base.file_at_base(root, ALLOWLIST)
    if status != "present":
        return status, set() if status == "absent" else None, []
    assert text is not None
    entries, messages = _parse_allowlist(f"protected-base:{ALLOWLIST}", text.splitlines())
    return status, entries, messages


def repository_messages(root: Path, enforce_base: bool = False) -> list[str]:
    from check_repo_restart_preflight import _step8_complete  # Lazy to avoid the checker import cycle.

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
    growth: set[str] = set()
    protected_base: str | None = None
    if enforce_base:
        protected_base = _protected_base_sha(root)
        base_status, base_allowlist, base_messages = _base_allowlist(root, protected_base)
        messages.extend(base_messages)
        if base_status == "unresolved":
            messages.append(
                f"cannot resolve protected base {ALLOWLIST} to enforce the shrink-only ratchet"
            )
        elif base_allowlist is not None:
            growth = allowlist - base_allowlist
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

    identities: dict[str, str] = {}
    for relative, artifact in sorted(manifests.items()):
        identity = artifact["one_use_identity"]
        prior = identities.get(identity)
        if prior is not None:
            messages.append(f"{relative} reuses one_use_identity from {prior}")
        else:
            identities[identity] = relative

    for entry in sorted(growth):
        artifact = manifests.get(entry)
        bound_messages = (
            [f"{entry} has no structurally valid manifest"]
            if artifact is None
            else [f"cannot resolve protected merge-base for {entry}"]
            if protected_base is None
            else _bound_manifest_messages(root, artifact, entry, protected_base)
        )
        messages.extend(bound_messages)
        if bound_messages or not _step8_complete(root, protected_base, "HEAD"):
            messages.append(f"{entry} grows {ALLOWLIST} relative to the protected base")

    for path, artifact in attestations:
        messages.extend(attestation_messages(root, path, artifact, manifests))
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
