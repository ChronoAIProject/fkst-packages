#!/usr/bin/env python3
"""CI entrypoint for one freshly validated intent-diff rollup subject."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence

import check_repo_intent_bounded_replay as checker
from intent_bounded_replay.rollup_attestation import (
    CarrierPullRequest,
    RollupAttestationError,
    TracePair,
    derive_rollup_authorization,
    load_carrier_pull_request,
    write_rollup_attestation,
)


def _trace_pairs() -> tuple[TracePair, ...]:
    return tuple(
        TracePair(
            old_path=old_path,
            new_path=new_path,
            schema=schema,
            family=family,
            owner=owner,
        )
        for old_path, new_path, schema, family, owner in checker.ADMISSION_TRACE_SPECS
    )


def _safe_output(root: Path, output: Path) -> Path:
    root = root.resolve()
    candidate = output.resolve()
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise RollupAttestationError("rollup attestation output must be inside the repository") from error
    parts = relative.parts
    if len(parts) < 4 or parts[:2] != (".fkst", "run") or candidate.suffix != ".json":
        raise RollupAttestationError(
            "rollup attestation output must be a JSON file below .fkst/run"
        )
    return candidate


def orchestrate(
    *,
    root: Path,
    carrier: CarrierPullRequest,
    trace_root: Path,
    output_dir: Path,
):
    """Authorize, precheck, then generate with one shared immutable decision."""
    authorization = derive_rollup_authorization(carrier.authorization_facts)
    root = Path(root).resolve()
    trace_root = Path(trace_root)
    if not trace_root.is_absolute():
        trace_root = root / trace_root
    output_dir = Path(output_dir)
    if not output_dir.is_absolute():
        output_dir = root / output_dir
    safe_output = _safe_output(
        root, output_dir / f"{carrier.carrier_pr_number}.json"
    )
    safe_output.unlink(missing_ok=True)
    precheck = checker.rollup_precheck(
        root,
        carrier_pr_number=carrier.carrier_pr_number,
        base_sha=carrier.base_sha,
        head_sha=carrier.head_sha,
        trace_root=trace_root,
        authorization=authorization,
        trace_pairs=_trace_pairs(),
    )
    if precheck is None:
        return None
    return write_rollup_attestation(
        safe_output,
        carrier.carrier_pr_number,
        authorization,
        precheck,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Freshly validate and attest one authorized carried intent manifest."
    )
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--github-event", required=True, type=Path)
    parser.add_argument("--trace-root", required=True, type=Path)
    parser.add_argument(
        "--output-dir",
        default=Path(".fkst/run/intent-diff-rollup-attestations"),
        type=Path,
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
) -> int:
    args = _parser().parse_args(argv)
    try:
        carrier = load_carrier_pull_request(args.github_event)
        artifact = orchestrate(
            root=args.repo_root,
            carrier=carrier,
            trace_root=args.trace_root,
            output_dir=args.output_dir,
        )
    except (RollupAttestationError, OSError, ValueError) as error:
        print(f"intent-diff-rollup-attestation: {error}", file=sys.stderr)
        return 1
    if artifact is None:
        print("intent-diff-rollup-attestation: no rollup subject")
    else:
        output = args.output_dir / f"{carrier.carrier_pr_number}.json"
        print(f"intent-diff-rollup-attestation: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
