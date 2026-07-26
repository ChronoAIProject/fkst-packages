#!/usr/bin/env python3
"""Tests for the R11 delivery-only intent authorization shape."""

from __future__ import annotations

import unittest

from intent_bounded_replay.delivery_authorization import (
    R11_CAUSE,
    delivery_authorization_messages,
)


def manifest() -> dict[str, object]:
    return {
        "cause": R11_CAUSE,
        "changed_row_ids": ["row:one"],
        "changed_edge_ids": ["edge:two"],
        "changed_policy_ids": [],
        "authorized_delivery_atoms": [
            {
                "observation_id": "edge:two",
                "remove": ["queue:consensus.consensus_converge"],
                "add": ["call:consensus.reach", "raise:devloop_consensus_continue"],
            },
            {
                "observation_id": "row:one",
                "remove": [
                    "queue:consensus.consensus_reached",
                    "queue:consensus.proposal",
                ],
                "add": ["raise:devloop_consensus_request"],
            },
        ],
    }


class DeliveryAuthorizationTest(unittest.TestCase):
    def test_exact_closed_delivery_vocabulary_passes(self) -> None:
        self.assertEqual(delivery_authorization_messages(manifest(), "2775.json"), [])

    def test_product_atom_is_structurally_ineligible(self) -> None:
        changed = manifest()
        changed["authorized_delivery_atoms"][0]["add"].append("marker:state-payload")

        messages = delivery_authorization_messages(changed, "2775.json")

        self.assertTrue(any("unsupported added delivery atom" in message for message in messages))

    def test_changed_ids_must_exactly_equal_authorized_ids(self) -> None:
        changed = manifest()
        changed["changed_policy_ids"] = ["policy:uncommitted"]

        messages = delivery_authorization_messages(changed, "2775.json")

        self.assertTrue(any("must exactly equal" in message for message in messages))

    def test_wildcards_duplicates_and_wrong_direction_fail(self) -> None:
        changed = manifest()
        changed["authorized_delivery_atoms"][0]["observation_id"] = "edge:*"
        changed["authorized_delivery_atoms"][0]["remove"] = [
            "raise:devloop_consensus_request",
            "raise:devloop_consensus_request",
        ]

        messages = delivery_authorization_messages(changed, "2775.json")

        self.assertTrue(any("wildcard" in message for message in messages))
        self.assertTrue(any("byte-sorted and unique" in message for message in messages))
        self.assertTrue(any("unsupported removed delivery atom" in message for message in messages))


if __name__ == "__main__":
    unittest.main()
