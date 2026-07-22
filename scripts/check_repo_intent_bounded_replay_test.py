#!/usr/bin/env python3
"""Unit tests for the R9 canonical artifact hashing foundation."""

from __future__ import annotations

from decimal import Decimal
import math
import unittest

from check_repo_intent_bounded_replay import _admission_trace_shape_messages
from intent_bounded_replay.compare import artifacts_equal, compare_report
from intent_bounded_replay.normalize import (
    canonical_artifact_hash_v1,
    canonical_json,
    loads_json,
)


class CanonicalJsonTest(unittest.TestCase):
    def test_object_keys_are_sorted_by_utf8_bytes(self) -> None:
        first = {"b": 1, "a": 2}
        second = {"a": 2, "b": 1}

        self.assertEqual(canonical_json(first), b'{"a":2,"b":1}')
        self.assertEqual(
            canonical_artifact_hash_v1(first),
            canonical_artifact_hash_v1(second),
        )
        # UTF-8 byte ordering puts ASCII z before the first byte of non-ASCII e-acute.
        self.assertEqual(
            canonical_artifact_hash_v1(first),
            "d3626ac30a87e6f7a6428233b3c68299976865fa5508e4267c5415c76af7a772",
        )
        self.assertEqual(canonical_json({"\u00e9": 1, "z": 2}), b'{"z":2,"\xc3\xa9":1}')

    def test_array_order_is_preserved(self) -> None:
        self.assertNotEqual(
            canonical_artifact_hash_v1([1, 2]),
            canonical_artifact_hash_v1([2, 1]),
        )

    def test_insignificant_input_formatting_does_not_affect_hash(self) -> None:
        formatted = loads_json('{\n  "b": 1.00,\n  "a": [true, null]\n}')
        compact = loads_json('{"a":[true,null],"b":1}')

        self.assertEqual(
            canonical_artifact_hash_v1(formatted),
            canonical_artifact_hash_v1(compact),
        )

    def test_duplicate_object_keys_are_rejected_before_information_is_lost(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            loads_json('{"same":1,"same":2}')

    def test_numbers_use_minimal_exponent_free_decimal_form(self) -> None:
        variants = [1, 1.0, loads_json("1.00")]
        hundreds = [100, 1e2, loads_json("1e2")]

        self.assertEqual({canonical_json(value) for value in variants}, {b"1"})
        self.assertEqual({canonical_json(value) for value in hundreds}, {b"100"})
        self.assertEqual(canonical_json(-0.0), b"0")
        self.assertEqual(canonical_json(loads_json("0.0012300")), b"0.00123")

    def test_non_finite_numbers_are_rejected(self) -> None:
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(value=value), self.assertRaises(ValueError):
                canonical_json(value)


class ArtifactHashTest(unittest.TestCase):
    def test_artifact_own_self_hash_value_is_omitted(self) -> None:
        for field in ("artifact_sha256", "manifest_sha256", "attestation_sha256"):
            with self.subTest(field=field):
                first = {"schema": "example.v1", "value": 7, field: "old"}
                second = {"schema": "example.v1", "value": 7, field: "new"}

                self.assertEqual(
                    canonical_artifact_hash_v1(first),
                    canonical_artifact_hash_v1(second),
                )
                self.assertEqual(first[field], "old")
                self.assertEqual(second[field], "new")

    def test_more_than_one_top_level_self_hash_field_is_rejected(self) -> None:
        artifact = {
            "schema": "example.v1",
            "artifact_sha256": "a",
            "manifest_sha256": "b",
        }

        with self.assertRaisesRegex(ValueError, "multiple self-hash fields"):
            canonical_artifact_hash_v1(artifact)

    def test_nested_hash_references_are_not_omitted(self) -> None:
        first = {"schema": "example.v1", "child": {"artifact_sha256": "a"}}
        second = {"schema": "example.v1", "child": {"artifact_sha256": "b"}}

        self.assertNotEqual(
            canonical_artifact_hash_v1(first),
            canonical_artifact_hash_v1(second),
        )

    def test_schema_and_version_are_included(self) -> None:
        baseline = {"schema": "example.v1", "version": 1, "value": "same"}

        self.assertNotEqual(
            canonical_artifact_hash_v1(baseline),
            canonical_artifact_hash_v1({**baseline, "schema": "example.v2"}),
        )
        self.assertNotEqual(
            canonical_artifact_hash_v1(baseline),
            canonical_artifact_hash_v1({**baseline, "version": 2}),
        )


class CompareTest(unittest.TestCase):
    def test_identical_artifacts_compare_equal(self) -> None:
        old = {"schema": "example.v1", "values": [1, 2], "artifact_sha256": "old"}
        new = {"values": [1.0, 2.00], "artifact_sha256": "new", "schema": "example.v1"}

        self.assertTrue(artifacts_equal(old, new))
        report = compare_report(old, new)
        self.assertTrue(report["equal"])
        self.assertEqual(report["old_hash"], report["new_hash"])
        self.assertNotIn("first_divergence", report)

    def test_difference_report_points_to_first_canonical_difference(self) -> None:
        old = {"schema": "example.v1", "payload": {"count": 1, "name": "same"}}
        new = {"schema": "example.v1", "payload": {"count": 2, "name": "same"}}

        self.assertFalse(artifacts_equal(old, new))
        report = compare_report(old, new)
        self.assertFalse(report["equal"])
        self.assertNotEqual(report["old_hash"], report["new_hash"])
        self.assertEqual(report["first_divergence"], "/payload/count")


class AdmissionTraceShapeTest(unittest.TestCase):
    @staticmethod
    def artifact(
        status: str,
        effect_ids: list[str],
        writes: list[dict[str, object]],
        entitlement_id: str | None = "owner/edge/idempotent",
    ) -> dict[str, object]:
        artifact: dict[str, object] = {
            "schema": "restart-example-trace.v1",
            "owner": "github-devloop",
            "family": "example",
            "fixtures": [
                {
                    "fixture_id": "fixture",
                    "edge_id": "owner/edge",
                    "cas_status": status,
                    "reason_code": "reason",
                    "cas_outcome": "outcome",
                    "effect_entitlement_id": entitlement_id,
                    "granted_effect_ids": effect_ids,
                    "observable_writes": writes,
                }
            ],
            "artifact_sha256": "0" * 64,
        }
        artifact["artifact_sha256"] = canonical_artifact_hash_v1(artifact)
        return artifact

    @staticmethod
    def write(ordinal: int, effect_id: str) -> dict[str, object]:
        return {
            "ordinal": Decimal(ordinal),
            "effect_id": effect_id,
            "write_kind": "queue",
            "marker_write": False,
        }

    def messages(self, artifact: dict[str, object]) -> list[str]:
        return _admission_trace_shape_messages(
            artifact,
            "trace.json",
            "restart-example-trace.v1",
            "example",
        )

    def test_idempotent_writes_may_exactly_equal_declared_entitlement(self) -> None:
        effect_ids = ["queue.one", "queue.two"]
        artifact = self.artifact(
            "idempotent",
            effect_ids,
            [self.write(index, effect_id) for index, effect_id in enumerate(effect_ids, 1)],
        )

        self.assertEqual(self.messages(artifact), [])

    def test_idempotent_writes_must_not_be_a_subset_of_declared_entitlement(self) -> None:
        artifact = self.artifact(
            "idempotent",
            ["queue.one", "queue.two"],
            [self.write(1, "queue.one")],
        )

        self.assertTrue(
            any("granted_effect_ids must equal observable write order" in message for message in self.messages(artifact))
        )

    def test_idempotent_writes_require_a_declared_entitlement(self) -> None:
        artifact = self.artifact(
            "idempotent",
            ["queue.one"],
            [self.write(1, "queue.one")],
            entitlement_id=None,
        )

        self.assertTrue(
            any("idempotent observable writes require an effect entitlement" in message for message in self.messages(artifact))
        )

    def test_pending_stale_and_illegal_admissions_remain_write_free(self) -> None:
        for status in ("pending", "stale", "illegal"):
            with self.subTest(status=status):
                artifact = self.artifact(status, ["queue.one"], [self.write(1, "queue.one")])
                self.assertTrue(
                    any(f"{status} admission must not include observable writes" in message for message in self.messages(artifact))
                )


if __name__ == "__main__":
    unittest.main()
