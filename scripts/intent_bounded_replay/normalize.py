#!/usr/bin/env python3
"""Canonical JSON and artifact hashing for the R9 semantic oracle."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from decimal import Decimal
from typing import Any

SELF_HASH_FIELDS = frozenset(
    {
        "artifact_sha256",
        "manifest_sha256",
        "attestation_sha256",
    }
)


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is not canonical: {value}")


def loads_json(source: str | bytes | bytearray) -> Any:
    """Parse UTF-8 JSON while retaining exact decimals and rejecting duplicate keys."""
    if isinstance(source, (bytes, bytearray)):
        source = bytes(source).decode("utf-8")
    elif not isinstance(source, str):
        raise TypeError("JSON source must be str, bytes, or bytearray")

    return json.loads(
        source,
        object_pairs_hook=_strict_object,
        parse_float=Decimal,
        parse_int=Decimal,
        parse_constant=_reject_json_constant,
    )


def _canonical_number(value: int | float | Decimal) -> bytes:
    """Return minimal plain decimal notation.

    The canonical numeric form never uses an exponent. Integers have no decimal
    point, fractional values have no unnecessary leading or trailing zeroes, and
    every representation of zero (including -0) is "0".
    Python floats first use their shortest round-trip decimal representation,
    then follow the same Decimal normalization rule.
    """
    if isinstance(value, int):
        return str(value).encode("ascii")

    decimal_value = Decimal(str(value)) if isinstance(value, float) else value
    if not decimal_value.is_finite():
        raise ValueError(f"non-finite JSON number is not canonical: {value!r}")
    if decimal_value.is_zero():
        return b"0"

    sign, digits_tuple, exponent = decimal_value.as_tuple()
    digits = "".join(str(digit) for digit in digits_tuple)
    if exponent >= 0:
        body = digits + ("0" * exponent)
    else:
        point = len(digits) + exponent
        if point > 0:
            body = digits[:point] + "." + digits[point:]
        else:
            body = "0." + ("0" * -point) + digits
        body = body.rstrip("0").rstrip(".")

    if sign:
        body = "-" + body
    return body.encode("ascii")


def _canonical_string(value: str) -> bytes:
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return encoded.encode("utf-8")


def _canonical_json(value: Any, active_containers: set[int]) -> bytes:
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, (int, float, Decimal)):
        return _canonical_number(value)
    if isinstance(value, str):
        return _canonical_string(value)

    if isinstance(value, Mapping):
        identity = id(value)
        if identity in active_containers:
            raise ValueError("cyclic JSON object is not canonical")
        active_containers.add(identity)
        try:
            keyed_values: list[tuple[bytes, str, Any]] = []
            seen: set[str] = set()
            for key, child in value.items():
                if not isinstance(key, str):
                    raise TypeError(f"JSON object key must be str, got {type(key).__name__}")
                if key in seen:
                    raise ValueError(f"duplicate JSON object key: {key!r}")
                seen.add(key)
                key_bytes = key.encode("utf-8")
                keyed_values.append((key_bytes, key, child))
            keyed_values.sort(key=lambda item: item[0])
            members = [
                _canonical_string(key) + b":" + _canonical_json(child, active_containers)
                for _, key, child in keyed_values
            ]
            return b"{" + b",".join(members) + b"}"
        finally:
            active_containers.remove(identity)

    if isinstance(value, (list, tuple)):
        identity = id(value)
        if identity in active_containers:
            raise ValueError("cyclic JSON array is not canonical")
        active_containers.add(identity)
        try:
            elements = [_canonical_json(child, active_containers) for child in value]
            return b"[" + b",".join(elements) + b"]"
        finally:
            active_containers.remove(identity)

    raise TypeError(f"value is not JSON-compatible: {type(value).__name__}")


def canonical_json(obj: Any) -> bytes:
    """Serialize a JSON-compatible value as deterministic canonical UTF-8 bytes."""
    return _canonical_json(obj, set())


def artifact_body_v1(artifact: Any) -> Any:
    """Return an artifact body with only its own top-level self-hash omitted."""
    if not isinstance(artifact, Mapping):
        return artifact

    present = sorted(field for field in SELF_HASH_FIELDS if field in artifact)
    if len(present) > 1:
        raise ValueError(f"artifact has multiple self-hash fields: {', '.join(present)}")
    if not present:
        return artifact

    body = dict(artifact)
    del body[present[0]]
    return body


def canonical_artifact_hash_v1(artifact: Any) -> str:
    """Return the hexadecimal SHA-256 of an artifact's canonical body."""
    return hashlib.sha256(canonical_json(artifact_body_v1(artifact))).hexdigest()
