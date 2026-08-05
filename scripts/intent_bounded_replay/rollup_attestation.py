#!/usr/bin/env python3
"""Verifier-owned evidence for one authorized intent-diff rollup subject."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Any, Callable, Iterable, Mapping

from .compare import compare_report
from .normalize import canonical_artifact_hash_v1, canonical_json, loads_json
from .semantic_tree import semantic_diff_sha256, semantic_tree_sha256


GIT_SHA_RE = re.compile(r"[0-9a-f]{40,64}")
ROLLUP_HEAD_REF_RE = re.compile(r"integration-[A-Za-z0-9][A-Za-z0-9._-]*")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class RollupAttestationError(RuntimeError):
    """Raised when exact rollup evidence cannot be established."""


@dataclass(frozen=True)
class CarrierAuthorizationFacts:
    """GitHub-owned facts used exclusively to classify the carrier."""

    event_repository: str
    head_repository: str
    head_ref: str
    base_ref: str


@dataclass(frozen=True)
class RollupAuthorizationDecision:
    """Immutable complete-mediation decision derived before content inspection."""

    facts: CarrierAuthorizationFacts
    authorized: bool


@dataclass(frozen=True)
class CarrierPullRequest:
    """Exact GitHub-owned carrier identity and immutable commit subject."""

    carrier_pr_number: int
    base_sha: str
    head_sha: str
    authorization_facts: CarrierAuthorizationFacts


@dataclass(frozen=True)
class TracePair:
    old_path: str
    new_path: str
    schema: str
    family: str
    owner: str


@dataclass(frozen=True)
class ManifestSubject:
    manifest_path: str
    manifest_blob_sha256: str
    manifest_sha256: str

    def artifact(self) -> dict[str, str]:
        return {
            "manifest_path": self.manifest_path,
            "manifest_blob_sha256": self.manifest_blob_sha256,
            "manifest_sha256": self.manifest_sha256,
        }


@dataclass(frozen=True)
class RollupPrecheck:
    authorization: RollupAuthorizationDecision
    base_sha: str
    head_sha: str
    subject: ManifestSubject
    old_trace_sha256: str
    new_trace_sha256: str
    behavior_diff_sha256: str

    def trace_hashes(self) -> dict[str, str]:
        return {
            "old_trace_sha256": self.old_trace_sha256,
            "new_trace_sha256": self.new_trace_sha256,
            "behavior_diff_sha256": self.behavior_diff_sha256,
        }


@dataclass(frozen=True)
class CarriedManifest:
    """One structurally valid manifest carried by an authorized commit pair."""

    authorization: RollupAuthorizationDecision
    base_sha: str
    head_sha: str
    subject: ManifestSubject
    declared_old_trace_sha256: str
    declared_new_trace_sha256: str
    declared_behavior_diff_sha256: str


ManifestValidator = Callable[[dict[str, Any], str, int], list[str]]
AllowlistParser = Callable[[str, list[str]], tuple[set[str], list[str]]]
TraceValidator = Callable[
    [dict[str, Any], str, str, str, str],
    list[str],
]


def derive_rollup_authorization(
    facts: CarrierAuthorizationFacts,
) -> RollupAuthorizationDecision:
    """Classify a same-repository integration-device to dev carrier."""
    authorized = (
        facts.event_repository != ""
        and facts.head_repository == facts.event_repository
        and ROLLUP_HEAD_REF_RE.fullmatch(facts.head_ref) is not None
        and facts.base_ref == "dev"
    )
    return RollupAuthorizationDecision(facts=facts, authorized=authorized)


def _required_mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise RollupAttestationError(f"GitHub event field {label} must be an object")
    return value


def _required_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise RollupAttestationError(
            f"GitHub event field {label} must be a non-empty string"
        )
    return value


def load_carrier_pull_request(event_path: Path) -> CarrierPullRequest:
    """Load exact carrier facts from the authenticated GitHub event document."""
    try:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RollupAttestationError(f"cannot load GitHub pull-request event: {error}") from error
    event = _required_mapping(event, "root")
    repository = _required_mapping(event.get("repository"), "repository")
    pull_request = _required_mapping(event.get("pull_request"), "pull_request")
    head = _required_mapping(pull_request.get("head"), "pull_request.head")
    base = _required_mapping(pull_request.get("base"), "pull_request.base")
    head_repository = _required_mapping(
        head.get("repo"), "pull_request.head.repo"
    )

    pr_number = event.get("number")
    if isinstance(pr_number, bool) or not isinstance(pr_number, int) or pr_number < 1:
        raise RollupAttestationError(
            "GitHub event field number must be a positive integer"
        )
    base_sha = _required_string(base.get("sha"), "pull_request.base.sha")
    head_sha = _required_string(head.get("sha"), "pull_request.head.sha")
    for value, label in ((base_sha, "base SHA"), (head_sha, "head SHA")):
        if GIT_SHA_RE.fullmatch(value) is None:
            raise RollupAttestationError(
                f"GitHub pull-request {label} must be a lowercase Git object ID"
            )

    return CarrierPullRequest(
        carrier_pr_number=pr_number,
        base_sha=base_sha,
        head_sha=head_sha,
        authorization_facts=CarrierAuthorizationFacts(
            event_repository=_required_string(
                repository.get("full_name"), "repository.full_name"
            ),
            head_repository=_required_string(
                head_repository.get("full_name"),
                "pull_request.head.repo.full_name",
            ),
            head_ref=_required_string(head.get("ref"), "pull_request.head.ref"),
            base_ref=_required_string(base.get("ref"), "pull_request.base.ref"),
        ),
    )


def carrier_pull_request_from_environment(
    environ: Mapping[str, str],
) -> CarrierPullRequest | None:
    """Load PR context only when GitHub identifies the current event as a PR."""
    if environ.get("GITHUB_EVENT_NAME") != "pull_request":
        return None
    event_path = environ.get("GITHUB_EVENT_PATH", "")
    if not event_path:
        raise RollupAttestationError(
            "GITHUB_EVENT_PATH is required for a pull-request rollup decision"
        )
    return load_carrier_pull_request(Path(event_path))


def _git(
    root: Path,
    *args: str,
    input_bytes: bytes | None = None,
) -> bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        input=input_bytes,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RollupAttestationError(
            f"git {' '.join(args)} failed ({result.returncode}): {detail}"
        )
    return result.stdout


def verify_commit(root: Path, sha: str, label: str) -> str:
    """Resolve an exact full commit ID without accepting a moving ref."""
    if GIT_SHA_RE.fullmatch(sha) is None:
        raise RollupAttestationError(f"{label} must be a lowercase Git object ID")
    resolved = _git(
        Path(root),
        "rev-parse",
        "--verify",
        "--end-of-options",
        f"{sha}^{{commit}}",
    ).strip().decode("ascii").lower()
    if resolved != sha:
        raise RollupAttestationError(
            f"{label} must name the exact resolved commit {resolved}, got {sha}"
        )
    return resolved


def changed_intent_diff_paths(
    root: Path,
    base_sha: str,
    head_sha: str,
    intent_diff_dir: str,
) -> list[str]:
    """Return every byte-ordered intent-diff path changed by the carrier."""
    output = _git(
        Path(root),
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        "--diff-filter=ACDMRT",
        base_sha,
        head_sha,
        "--",
        intent_diff_dir,
    )
    paths: set[str] = set()
    for raw in output.split(b"\0"):
        if not raw:
            continue
        try:
            paths.add(raw.decode("utf-8"))
        except UnicodeDecodeError as error:
            raise RollupAttestationError(
                f"changed intent-diff path is not valid UTF-8: {raw!r}"
            ) from error
    return sorted(paths, key=lambda value: value.encode("utf-8"))


def git_blob(root: Path, commit_sha: str, relative: str) -> bytes:
    """Read exact subject bytes from an immutable carrier commit."""
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/\-]*", relative) is None:
        raise RollupAttestationError(f"Git blob path is not canonical: {relative}")
    return _git(Path(root), "cat-file", "blob", f"{commit_sha}:{relative}")


def _parsed_allowlist(
    root: Path,
    commit_sha: str,
    allowlist_path: str,
    parse_allowlist: AllowlistParser,
) -> tuple[set[str], list[str]]:
    try:
        text = git_blob(root, commit_sha, allowlist_path).decode("utf-8")
    except (RollupAttestationError, UnicodeDecodeError) as error:
        raise RollupAttestationError(
            f"cannot load {allowlist_path} from carrier commit {commit_sha}: {error}"
        ) from error
    return parse_allowlist(
        f"carrier:{commit_sha}:{allowlist_path}", text.splitlines()
    )


def _semantic_subject_commit(
    root: Path,
    head_sha: str,
    relative: str,
    raw_manifest: bytes,
    manifest: Mapping[str, Any],
) -> str | None:
    """Find exact manifest bytes whose declared semantic subject revalidates."""
    manifest_base = verify_commit(
        root, str(manifest["base_sha"]), "manifest semantic base SHA"
    )
    history = _git(
        root, "rev-list", "--full-history", head_sha, "--", relative
    ).decode("ascii").splitlines()
    for commit in history:
        if GIT_SHA_RE.fullmatch(commit) is None:
            raise RollupAttestationError(
                f"git rev-list returned invalid object ID {commit!r}"
            )
        try:
            historical_blob = git_blob(root, commit, relative)
        except RollupAttestationError:
            continue
        if historical_blob != raw_manifest:
            continue
        ancestry = subprocess.run(
            ["git", "merge-base", "--is-ancestor", manifest_base, commit],
            cwd=root,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if ancestry.returncode == 1:
            continue
        if ancestry.returncode != 0:
            detail = ancestry.stderr.decode("utf-8", errors="replace").strip()
            raise RollupAttestationError(
                "git merge-base --is-ancestor failed "
                f"({ancestry.returncode}): {detail}"
            )
        if (
            manifest["semantic_tree_sha256"] == semantic_tree_sha256(root, commit)
            and manifest["semantic_diff_sha256"]
            == semantic_diff_sha256(root, manifest_base, commit)
        ):
            return commit
    return None


def precheck_carried_manifest(
    root: Path,
    *,
    carrier_pr_number: int,
    base_sha: str,
    head_sha: str,
    authorization: RollupAuthorizationDecision,
    intent_diff_dir: str,
    allowlist_path: str,
    validate_manifest: ManifestValidator,
    parse_allowlist: AllowlistParser,
) -> CarriedManifest | None:
    """Validate the exact one-manifest carrier without trusting manifest claims."""
    root = Path(root)
    if isinstance(carrier_pr_number, bool) or carrier_pr_number < 1:
        raise RollupAttestationError("carrier pull request number must be positive")
    actual_base = verify_commit(root, base_sha, "carrier base SHA")
    actual_head = verify_commit(root, head_sha, "carrier head SHA")
    changed = changed_intent_diff_paths(
        root, actual_base, actual_head, intent_diff_dir
    )

    if not authorization.authorized:
        if not changed:
            return None
        expected = f"{intent_diff_dir}/{carrier_pr_number}.json"
        if changed != [expected]:
            shown = ", ".join(changed)
            raise RollupAttestationError(
                "ordinary pull request may change only its own numbered manifest "
                f"{expected}; found: {shown}"
            )
        return None

    numbered = re.compile(rf"{re.escape(intent_diff_dir)}/[1-9][0-9]*\.json")
    if not changed:
        return None
    if len(changed) != 1 or numbered.fullmatch(changed[0]) is None:
        shown = ", ".join(changed)
        raise RollupAttestationError(
            "authorized rollup must carry exactly one numbered manifest; "
            f"found: {shown}"
        )

    relative = changed[0]
    raw_manifest = git_blob(root, actual_head, relative)
    try:
        manifest = loads_json(raw_manifest)
    except Exception as error:
        raise RollupAttestationError(
            f"cannot load carried intent-diff manifest {relative}: {error}"
        ) from error
    if not isinstance(manifest, dict):
        raise RollupAttestationError(
            f"carried intent-diff manifest {relative} must contain an object"
        )

    messages = validate_manifest(manifest, relative, int(Path(relative).stem))
    if not messages:
        expected_identity = "/".join(
            (
                str(int(manifest["pr_number"])),
                str(manifest["base_sha"]),
                str(manifest["semantic_tree_sha256"]),
                str(manifest["semantic_diff_sha256"]),
            )
        )
        if manifest["one_use_identity"] != expected_identity:
            messages.append(
                f"{relative} one_use_identity is not bound to pr/base/semantic hashes"
            )

    base_allowlist, base_messages = _parsed_allowlist(
        root, actual_base, allowlist_path, parse_allowlist
    )
    head_allowlist, head_messages = _parsed_allowlist(
        root, actual_head, allowlist_path, parse_allowlist
    )
    messages.extend(base_messages)
    messages.extend(head_messages)
    growth = head_allowlist - base_allowlist
    if growth != {relative}:
        shown = ", ".join(sorted(growth, key=lambda value: value.encode("utf-8")))
        messages.append(
            "authorized rollup allowlist growth must equal its exact manifest subject "
            f"{relative}; found: {shown or '<none>'}"
        )
    if not messages:
        try:
            subject_commit = _semantic_subject_commit(
                root, actual_head, relative, raw_manifest, manifest
            )
        except Exception as error:
            messages.append(
                f"{relative} cannot revalidate its semantic subject: {error}"
            )
        else:
            if subject_commit is None:
                messages.append(
                    f"{relative} exact bytes do not identify a valid semantic subject "
                    f"in carrier head {actual_head}"
                )
    if messages:
        raise RollupAttestationError("; ".join(messages))

    subject = ManifestSubject(
        manifest_path=relative,
        manifest_blob_sha256=hashlib.sha256(raw_manifest).hexdigest(),
        manifest_sha256=str(manifest["manifest_sha256"]),
    )
    return CarriedManifest(
        authorization=authorization,
        base_sha=actual_base,
        head_sha=actual_head,
        subject=subject,
        declared_old_trace_sha256=str(manifest["old_trace_sha256"]),
        declared_new_trace_sha256=str(manifest["new_trace_sha256"]),
        declared_behavior_diff_sha256=str(manifest["behavior_diff_sha256"]),
    )


def _load_trace(
    root: Path,
    pair: TracePair,
    *,
    base_sha: str,
    trace_root: Path,
    old: bool,
) -> dict[str, Any]:
    relative = pair.old_path if old else pair.new_path
    if old:
        raw = git_blob(root, base_sha, relative)
    else:
        path = trace_root / relative
        if not path.is_file():
            raise RollupAttestationError(f"missing trace artifact: {relative}")
        raw = path.read_bytes()
    try:
        artifact = loads_json(raw)
    except Exception as error:
        raise RollupAttestationError(
            f"cannot load trace artifact {relative}: {error}"
        ) from error
    if not isinstance(artifact, dict):
        raise RollupAttestationError(f"trace artifact {relative} must contain an object")
    for field, expected in (
        ("schema", pair.schema),
        ("family", pair.family),
        ("owner", pair.owner),
    ):
        if artifact.get(field) != expected:
            raise RollupAttestationError(
                f"trace artifact {relative} field {field} must be {expected}"
            )
    declared = artifact.get("artifact_sha256")
    computed = canonical_artifact_hash_v1(artifact)
    if not isinstance(declared, str) or SHA256_RE.fullmatch(declared) is None:
        raise RollupAttestationError(
            f"trace artifact {relative} artifact_sha256 must be a lowercase SHA-256"
        )
    if declared != computed:
        raise RollupAttestationError(
            f"trace artifact {relative} artifact_sha256 mismatch: "
            f"declared {declared}, computed {computed}"
        )
    return artifact


def recompute_trace_hashes(
    root: Path,
    base_sha: str,
    trace_root: Path,
    trace_pairs: Iterable[TracePair],
    validate_trace: TraceValidator | None = None,
) -> dict[str, str]:
    """Recompute canonical OLD, NEW, and behavior-diff aggregate hashes."""
    pairs = sorted(tuple(trace_pairs), key=lambda pair: pair.family.encode("utf-8"))
    families = [pair.family for pair in pairs]
    if not pairs:
        raise RollupAttestationError("rollup attestation has no trace families")
    if len(families) != len(set(families)):
        raise RollupAttestationError("rollup attestation trace families must be unique")

    old_entries: list[dict[str, str]] = []
    new_entries: list[dict[str, str]] = []
    comparisons: list[dict[str, object]] = []
    for pair in pairs:
        old = _load_trace(
            Path(root),
            pair,
            base_sha=base_sha,
            trace_root=Path(trace_root),
            old=True,
        )
        new = _load_trace(
            Path(root),
            pair,
            base_sha=base_sha,
            trace_root=Path(trace_root),
            old=False,
        )
        if validate_trace is not None:
            shape_messages = validate_trace(
                old, pair.old_path, pair.schema, pair.family, pair.owner
            )
            shape_messages.extend(
                validate_trace(
                    new, pair.new_path, pair.schema, pair.family, pair.owner
                )
            )
            if shape_messages:
                raise RollupAttestationError("; ".join(shape_messages))
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


def complete_rollup_precheck(
    root: Path,
    *,
    carrier_pr_number: int,
    base_sha: str,
    head_sha: str,
    trace_root: Path,
    authorization: RollupAuthorizationDecision,
    trace_pairs: tuple[TracePair, ...],
    intent_diff_dir: str,
    allowlist_path: str,
    validate_manifest: ManifestValidator,
    parse_allowlist: AllowlistParser,
    validate_trace: TraceValidator,
) -> RollupPrecheck | None:
    """Freshly validate one exact carried subject and its emitted traces."""
    carried = precheck_carried_manifest(
        root,
        carrier_pr_number=carrier_pr_number,
        base_sha=base_sha,
        head_sha=head_sha,
        authorization=authorization,
        intent_diff_dir=intent_diff_dir,
        allowlist_path=allowlist_path,
        validate_manifest=validate_manifest,
        parse_allowlist=parse_allowlist,
    )
    if carried is None:
        return None

    trace_hashes = recompute_trace_hashes(
        Path(root),
        carried.base_sha,
        Path(trace_root),
        trace_pairs,
        validate_trace,
    )
    declared = {
        "old_trace_sha256": carried.declared_old_trace_sha256,
        "new_trace_sha256": carried.declared_new_trace_sha256,
        "behavior_diff_sha256": carried.declared_behavior_diff_sha256,
    }
    mismatches = [
        f"{carried.subject.manifest_path} {field} mismatch: "
        f"declared {declared[field]}, computed {computed}"
        for field, computed in trace_hashes.items()
        if declared[field] != computed
    ]
    if mismatches:
        raise RollupAttestationError("; ".join(mismatches))

    return RollupPrecheck(
        authorization=authorization,
        base_sha=carried.base_sha,
        head_sha=carried.head_sha,
        subject=carried.subject,
        old_trace_sha256=trace_hashes["old_trace_sha256"],
        new_trace_sha256=trace_hashes["new_trace_sha256"],
        behavior_diff_sha256=trace_hashes["behavior_diff_sha256"],
    )


def canonical_rollup_attestation_sha256(artifact: Mapping[str, object]) -> str:
    """Hash the canonical rollup attestation body without its self-hash."""
    body = dict(artifact)
    body.pop("attestation_sha256", None)
    return hashlib.sha256(canonical_json(body)).hexdigest()


def write_rollup_attestation(
    output: Path,
    carrier_pr_number: int,
    authorization: RollupAuthorizationDecision,
    precheck: RollupPrecheck,
) -> dict[str, object]:
    """Write the one-subject artifact authorized by the exact precheck decision."""
    if precheck.authorization is not authorization:
        raise RollupAttestationError(
            "artifact generation did not receive the exact precheck authorization decision"
        )
    if not authorization.authorized:
        raise RollupAttestationError("ordinary pull request cannot emit a rollup attestation")
    if carrier_pr_number < 1:
        raise RollupAttestationError("carrier pull request number must be positive")
    artifact: dict[str, object] = {
        "schema": "fkst.intent-diff-rollup-attestation.v1",
        "carrier_pr_number": carrier_pr_number,
        "base_sha": precheck.base_sha,
        "head_sha": precheck.head_sha,
        "manifest_subjects": [precheck.subject.artifact()],
        **precheck.trace_hashes(),
        "result": "approved",
        "attestation_sha256": "",
    }
    artifact["attestation_sha256"] = canonical_rollup_attestation_sha256(artifact)
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(artifact) + b"\n")
    return artifact
