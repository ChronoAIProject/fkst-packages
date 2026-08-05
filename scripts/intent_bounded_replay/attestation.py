#!/usr/bin/env python3
"""Canonical trace aggregation for intent-diff CI attestations."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
import hashlib
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Iterable, Mapping

from .compare import compare_report
from .normalize import canonical_artifact_hash_v1, canonical_json, loads_json
from .semantic_tree import semantic_diff_sha256, semantic_tree_sha256


SHA256_RE = re.compile(r"[0-9a-f]{64}")
TRACE_HASH_FIELDS = (
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
)
ATTESTATION_FIELDS = {
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
}
ATTESTATION_HASH_FIELDS = {
    "manifest_blob_sha256",
    "manifest_sha256",
    "semantic_tree_sha256",
    "semantic_diff_sha256",
    "old_trace_sha256",
    "new_trace_sha256",
    "behavior_diff_sha256",
    "attestation_sha256",
}
GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}")
ROLLUP_HEAD_REF_RE = re.compile(r"integration(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?")
ROLLUP_PROVENANCE_ERROR = (
    "rollup attestation requires the configured same-repository "
    "integration-to-dev topology"
)


class AttestationError(RuntimeError):
    """Raised when verifier-owned attestation evidence is incomplete or invalid."""


def rollup_provenance_messages(
    environ: Mapping[str, str] | None = None,
) -> list[str]:
    """Validate producer-owned GitHub facts that authorize rollup semantics."""
    values = os.environ if environ is None else environ
    repository = values.get("GITHUB_REPOSITORY", "")
    head_repository = values.get("FKST_R9_PR_HEAD_REPOSITORY", "")
    head_ref = values.get("GITHUB_HEAD_REF", "")
    base_ref = values.get("GITHUB_BASE_REF", "")
    authorized = (
        values.get("GITHUB_EVENT_NAME") == "pull_request"
        and repository != ""
        and head_repository == repository
        and ROLLUP_HEAD_REF_RE.fullmatch(head_ref) is not None
        and base_ref == "dev"
    )
    return [] if authorized else [ROLLUP_PROVENANCE_ERROR]


@dataclass(frozen=True)
class TracePair:
    family: str
    old_path: str
    new_path: str
    schema: str
    owner: str


TRACE_PAIRS = (
    TracePair(
        "awaiting-pr",
        "migration/intent_bounded_replay/corpus/awaiting-pr.json",
        "r9-awaiting-pr-new-trace.json",
        "restart-awaiting-pr-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "implement-activation",
        "migration/intent_bounded_replay/corpus/implement-activation.json",
        "r9-implement-activation-new-trace.json",
        "restart-implement-activation-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "issue-reconcile",
        "migration/intent_bounded_replay/corpus/issue-reconcile.json",
        "r9-issue-reconcile-new-trace.json",
        "restart-issue-reconcile-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "loop-plain",
        "migration/intent_bounded_replay/corpus/loop-plain.json",
        "r9-loop-plain-new-trace.json",
        "restart-loop-plain-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "observe-issue-entry",
        "migration/intent_bounded_replay/corpus/observe-issue-entry.json",
        "r9-observe-issue-entry-new-trace.json",
        "restart-observe-issue-entry-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "observe-pr-fix",
        "migration/intent_bounded_replay/corpus/observe-pr-fix.json",
        "r9-observe-pr-fix-new-trace.json",
        "restart-observe-pr-fix-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-fix",
        "migration/intent_bounded_replay/corpus/pr-fix.json",
        "r9-pr-fix-new-trace.json",
        "restart-pr-fix-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-fix-reconcile",
        "migration/intent_bounded_replay/corpus/pr-fix-reconcile.json",
        "r9-pr-fix-reconcile-new-trace.json",
        "restart-pr-fix-reconcile-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-merge",
        "migration/intent_bounded_replay/corpus/pr-merge.json",
        "r9-pr-merge-new-trace.json",
        "restart-pr-merge-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-review-activation",
        "migration/intent_bounded_replay/corpus/pr-review-activation.json",
        "r9-pr-review-activation-new-trace.json",
        "restart-pr-review-activation-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-review-loop",
        "migration/intent_bounded_replay/corpus/pr-review-loop.json",
        "r9-pr-review-loop-new-trace.json",
        "restart-pr-review-loop-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-review-meta",
        "migration/intent_bounded_replay/corpus/pr-review-meta.json",
        "r9-pr-review-meta-new-trace.json",
        "restart-pr-review-meta-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "pr-review-result",
        "migration/intent_bounded_replay/corpus/pr-review-result.json",
        "r9-pr-review-result-new-trace.json",
        "restart-pr-review-result-trace.v1",
        "github-devloop-pr",
    ),
    TracePair(
        "thinking",
        "migration/intent_bounded_replay/corpus/thinking.json",
        "r9-thinking-new-trace.json",
        "restart-thinking-trace.v1",
        "github-devloop",
    ),
    TracePair(
        "timeout-reconcile",
        "migration/intent_bounded_replay/corpus/timeout-reconcile.json",
        "r9-timeout-reconcile-new-trace.json",
        "restart-timeout-reconcile-trace.v1",
        "github-devloop",
    ),
)


def canonical_attestation_sha256(artifact: Mapping[str, object]) -> str:
    """Hash an attestation while retaining all referenced artifact hashes."""
    body = dict(artifact)
    body.pop("attestation_sha256", None)
    return hashlib.sha256(canonical_json(body)).hexdigest()


def _load_trace(
    root: Path,
    relative: str,
    pair: TracePair,
    *,
    git_ref: str | None = None,
) -> dict[str, Any]:
    if git_ref is None:
        path = root / relative
        if not path.is_file():
            raise AttestationError(f"missing trace artifact: {relative}")
        raw = path.read_bytes()
    else:
        if GIT_SHA_RE.fullmatch(git_ref) is None:
            raise AttestationError(f"trace artifact Git ref must be an object ID: {git_ref}")
        result = subprocess.run(
            ["git", "cat-file", "blob", f"{git_ref}:{relative}"],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise AttestationError(
                f"cannot load trace artifact {relative} from {git_ref}: {detail}"
            )
        raw = result.stdout
    try:
        artifact = loads_json(raw)
    except Exception as error:
        raise AttestationError(f"cannot load trace artifact {relative}: {error}") from error
    if not isinstance(artifact, dict):
        raise AttestationError(f"trace artifact {relative} must contain an object")
    for field, expected in (
        ("schema", pair.schema),
        ("owner", pair.owner),
        ("family", pair.family),
    ):
        if artifact.get(field) != expected:
            raise AttestationError(
                f"trace artifact {relative} field {field} must be {expected}"
            )
    declared_hash = artifact.get("artifact_sha256")
    if not isinstance(declared_hash, str) or SHA256_RE.fullmatch(declared_hash) is None:
        raise AttestationError(
            f"trace artifact {relative} field artifact_sha256 must be a lowercase SHA-256"
        )
    computed_hash = canonical_artifact_hash_v1(artifact)
    if declared_hash != computed_hash:
        raise AttestationError(
            f"trace artifact {relative} artifact_sha256 mismatch: "
            f"declared {declared_hash}, computed {computed_hash}"
        )
    return artifact


def recompute_trace_hashes(
    root: Path,
    trace_pairs: Iterable[TracePair] = TRACE_PAIRS,
    *,
    old_ref: str | None = None,
    trace_root: Path | None = None,
) -> dict[str, str]:
    """Recompute aggregate OLD, NEW, and behavior-diff hashes from all trace pairs."""
    pairs = sorted(tuple(trace_pairs), key=lambda pair: pair.family.encode("utf-8"))
    families = [pair.family for pair in pairs]
    if not pairs:
        raise AttestationError("intent-diff attestation has no trace families")
    if len(families) != len(set(families)):
        raise AttestationError("intent-diff attestation trace families must be unique")

    old_entries: list[dict[str, str]] = []
    new_entries: list[dict[str, str]] = []
    comparisons: list[dict[str, object]] = []
    new_artifact_root = Path(trace_root) if trace_root is not None else Path(root)
    for pair in pairs:
        old = _load_trace(Path(root), pair.old_path, pair, git_ref=old_ref)
        new = _load_trace(new_artifact_root, pair.new_path, pair)
        report = compare_report(old, new)
        old_hash = str(report["old_hash"])
        new_hash = str(report["new_hash"])
        old_entries.append({"family": pair.family, "trace_sha256": old_hash})
        new_entries.append({"family": pair.family, "trace_sha256": new_hash})
        comparison: dict[str, object] = {
            "equal": bool(report["equal"]),
            "family": pair.family,
            "new_trace_sha256": new_hash,
            "old_trace_sha256": old_hash,
        }
        if not report["equal"]:
            comparison["first_divergence"] = report.get("first_divergence")
        comparisons.append(comparison)

    old_set = {"schema": "fkst.intent-diff-trace-set.v1", "traces": old_entries}
    new_set = {"schema": "fkst.intent-diff-trace-set.v1", "traces": new_entries}
    behavior_diff = {
        "schema": "fkst.intent-diff-behavior-diff.v1",
        "comparisons": comparisons,
    }
    return {
        "old_trace_sha256": canonical_artifact_hash_v1(old_set),
        "new_trace_sha256": canonical_artifact_hash_v1(new_set),
        "behavior_diff_sha256": canonical_artifact_hash_v1(behavior_diff),
    }


def trace_hash_messages(
    root: Path,
    declared: Mapping[str, object],
    relative: str,
    trace_pairs: Iterable[TracePair] = TRACE_PAIRS,
    *,
    old_ref: str | None = None,
    trace_root: Path | None = None,
) -> list[str]:
    """Return fail-closed verifier messages for declared aggregate trace hashes."""
    try:
        computed = recompute_trace_hashes(
            root,
            trace_pairs,
            old_ref=old_ref,
            trace_root=trace_root,
        )
    except AttestationError as error:
        return [f"{relative} cannot recompute trace hashes: {error}"]
    return [
        f"{relative} {field} mismatch: declared {declared.get(field)}, computed {computed[field]}"
        for field in TRACE_HASH_FIELDS
        if declared.get(field) != computed[field]
    ]


def _head_sha(root: Path, head_ref: str) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", f"{head_ref}^{{commit}}"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise AttestationError(
            f"git rev-parse {head_ref} failed ({result.returncode}): {detail}"
        )
    return result.stdout.strip().lower()


def attestation_messages(
    root: Path,
    path: Path,
    artifact: dict[str, Any],
    manifests: Mapping[str, dict[str, Any]],
    *,
    head_ref: str = "HEAD",
    trace_root: Path | None = None,
) -> list[str]:
    """Validate an attestation by recomputing every verifier-owned digest."""
    relative = path.relative_to(root).as_posix()
    actual_fields = set(artifact)
    missing = sorted(ATTESTATION_FIELDS - actual_fields)
    extra = sorted(actual_fields - ATTESTATION_FIELDS)
    messages: list[str] = []
    if missing:
        messages.append(f"{relative} is missing fields: {', '.join(missing)}")
    if extra:
        messages.append(f"{relative} has unexpected fields: {', '.join(extra)}")
    if missing:
        return messages

    if artifact["schema"] != "fkst.intent-diff-attestation.v1":
        messages.append(f"{relative} schema must be fkst.intent-diff-attestation.v1")
    if artifact["result"] != "approved":
        messages.append(f"{relative} result must be approved")
    pr_number = artifact["pr_number"]
    if not (
        isinstance(pr_number, Decimal)
        and pr_number >= 1
        and pr_number == pr_number.to_integral_value()
    ):
        messages.append(f"{relative} pr_number must be a positive integer")
        expected_manifest = None
    else:
        expected_manifest = f"migration/intent-diffs/{int(pr_number)}.json"
        if artifact["manifest_path"] != expected_manifest:
            messages.append(f"{relative} manifest_path must be {expected_manifest}")
    for field in ("base_sha", "head_sha"):
        value = artifact[field]
        if not isinstance(value, str) or GIT_SHA_RE.fullmatch(value) is None:
            messages.append(f"{relative} {field} must be a lowercase Git object ID")
    for field in ATTESTATION_HASH_FIELDS:
        value = artifact[field]
        if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
            messages.append(f"{relative} field {field} must be a lowercase SHA-256")
    declared_self_hash = artifact["attestation_sha256"]
    if isinstance(declared_self_hash, str):
        computed_self_hash = canonical_attestation_sha256(artifact)
        if declared_self_hash != computed_self_hash:
            messages.append(
                f"{relative} attestation_sha256 mismatch: declared "
                f"{declared_self_hash}, computed {computed_self_hash}"
            )
    if messages or expected_manifest is None:
        return messages

    manifest = manifests.get(expected_manifest)
    manifest_path = root / expected_manifest
    if manifest is None or not manifest_path.is_file():
        return messages + [
            f"{relative} references missing or invalid manifest {expected_manifest}"
        ]
    manifest_blob = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if artifact["manifest_blob_sha256"] != manifest_blob:
        messages.append(
            f"{relative} manifest_blob_sha256 mismatch: declared "
            f"{artifact['manifest_blob_sha256']}, computed {manifest_blob}"
        )
    if artifact["manifest_sha256"] != manifest.get("manifest_sha256"):
        messages.append(f"{relative} manifest_sha256 does not match {expected_manifest}")
    if artifact["base_sha"] != manifest.get("base_sha"):
        messages.append(f"{relative} base_sha does not match {expected_manifest}")
    for field in TRACE_HASH_FIELDS:
        if artifact[field] != manifest.get(field):
            messages.append(f"{relative} {field} does not match {expected_manifest}")
    messages.extend(
        trace_hash_messages(
            root,
            artifact,
            relative,
            old_ref=str(artifact["base_sha"]),
            trace_root=trace_root,
        )
    )

    try:
        actual_head = _head_sha(root, head_ref)
        actual_tree = semantic_tree_sha256(root, head_ref)
        actual_diff = semantic_diff_sha256(root, str(artifact["base_sha"]), head_ref)
    except Exception as error:
        return messages + [f"{relative} cannot recompute semantic hashes: {error}"]
    if artifact["head_sha"] != actual_head:
        messages.append(
            f"{relative} head_sha mismatch: declared {artifact['head_sha']}, "
            f"computed {actual_head}"
        )
    for field, actual in (
        ("semantic_tree_sha256", actual_tree),
        ("semantic_diff_sha256", actual_diff),
    ):
        if artifact[field] != actual:
            messages.append(
                f"{relative} {field} mismatch: declared {artifact[field]}, computed {actual}"
            )
        if manifest.get(field) != actual:
            messages.append(
                f"{expected_manifest} {field} mismatch: "
                f"declared {manifest.get(field)}, computed {actual}"
            )
    return messages
