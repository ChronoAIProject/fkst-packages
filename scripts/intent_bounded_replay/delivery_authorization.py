#!/usr/bin/env python3
"""Closed validation for the R11 queue-dialogue delivery authorization."""

from __future__ import annotations

from typing import Any


R11_CAUSE = "R11.queue_dialogue_to_sync_consensus_call"
FIELD = "authorized_delivery_atoms"
REMOVED_ATOMS = frozenset(
    {
        "queue:consensus.consensus_converge",
        "queue:consensus.consensus_reached",
        "queue:consensus.proposal",
    }
)
ADDED_ATOMS = frozenset(
    {
        "call:consensus.reach",
        "raise:devloop_consensus_continue",
        "raise:devloop_consensus_request",
    }
)
ENTRY_FIELDS = frozenset({"observation_id", "remove", "add"})
CHANGED_ID_FIELDS = (
    "changed_row_ids",
    "changed_edge_ids",
    "changed_policy_ids",
)


def _strings(value: Any, label: str, messages: list[str]) -> list[str] | None:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        messages.append(f"{label} must be an array of non-empty strings")
        return None
    if any(any(token in item for token in ("*", "?", "[", "]")) for item in value):
        messages.append(f"{label} must not contain wildcard values")
    canonical = sorted(set(value), key=lambda item: item.encode("utf-8"))
    if value != canonical:
        messages.append(f"{label} must be byte-sorted and unique")
    return value


def delivery_authorization_messages(
    artifact: dict[str, Any], relative: str
) -> list[str]:
    """Validate that R11 can authorize delivery atoms and nothing else."""
    cause = artifact.get("cause")
    if cause != R11_CAUSE:
        if FIELD in artifact:
            return [f"{relative} {FIELD} is reserved for cause {R11_CAUSE}"]
        return []

    messages: list[str] = []
    changed_ids: set[str] = set()
    for field in CHANGED_ID_FIELDS:
        values = _strings(artifact.get(field), f"{relative} field {field}", messages)
        if values is None:
            continue
        for value in values:
            if value in changed_ids:
                messages.append(f"{relative} changed observation ID appears in multiple sets: {value}")
            changed_ids.add(value)

    entries = artifact.get(FIELD)
    if not isinstance(entries, list) or not entries:
        return messages + [f"{relative} {FIELD} must be a non-empty array"]

    authorization_ids: list[str] = []
    removed_atoms: set[str] = set()
    added_atoms: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"{relative} {FIELD}[{index}]"
        if not isinstance(entry, dict):
            messages.append(f"{label} must be an object")
            continue
        actual_fields = set(entry)
        if actual_fields != ENTRY_FIELDS:
            missing = sorted(ENTRY_FIELDS - actual_fields)
            extra = sorted(actual_fields - ENTRY_FIELDS)
            if missing:
                messages.append(f"{label} is missing fields: {', '.join(missing)}")
            if extra:
                messages.append(f"{label} has unexpected fields: {', '.join(extra)}")
        observation_id = entry.get("observation_id")
        if not isinstance(observation_id, str) or not observation_id:
            messages.append(f"{label} observation_id must be a non-empty string")
        else:
            if any(token in observation_id for token in ("*", "?", "[", "]")):
                messages.append(f"{label} observation_id must not contain wildcard values")
            authorization_ids.append(observation_id)
        removed = _strings(entry.get("remove"), f"{label} remove", messages)
        added = _strings(entry.get("add"), f"{label} add", messages)
        for atom in removed or []:
            if atom not in REMOVED_ATOMS:
                messages.append(f"{label} has unsupported removed delivery atom: {atom}")
            removed_atoms.add(atom)
        for atom in added or []:
            if atom not in ADDED_ATOMS:
                messages.append(f"{label} has unsupported added delivery atom: {atom}")
            added_atoms.add(atom)
        if removed == [] and added == []:
            messages.append(f"{label} must authorize a non-empty delivery diff")

    canonical_ids = sorted(set(authorization_ids), key=lambda item: item.encode("utf-8"))
    if authorization_ids != canonical_ids:
        messages.append(f"{relative} {FIELD} observation_id values must be byte-sorted and unique")
    if set(authorization_ids) != changed_ids:
        messages.append(
            f"{relative} changed observation IDs must exactly equal {FIELD} observation IDs"
        )
    if removed_atoms != REMOVED_ATOMS:
        messages.append(f"{relative} removed delivery vocabulary must exactly equal the R11 closed set")
    if added_atoms != ADDED_ATOMS:
        messages.append(f"{relative} added delivery vocabulary must exactly equal the R11 closed set")
    return messages
