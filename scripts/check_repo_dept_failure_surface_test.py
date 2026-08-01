"""Mutation tests for the department failure-surface ratchet (#2996).

These are deliberately mutation-shaped rather than example-shaped. A check that still passes
when the thing it checks is removed is not a check, and a check satisfied by an unrelated edit
is worse than none -- both failure modes were observed on an earlier harness for #2991, which
survived deleting every guard it claimed to protect.

So each test either breaks the property and demands a message, or perturbs something irrelevant
and demands silence.
"""

from __future__ import annotations

import unittest

import check_repo_dept_failure_surface as check

PROTECTED = "packages/pkg/departments/worker/main.lua"
NAKED = "packages/pkg/departments/scanner/main.lua"
DEAD_LETTER = "packages/pkg/departments/dead_letter/main.lua"
PROBE = "packages/pkg/departments/test_probe/main.lua"

WITH_RETRY = """local spec = {
  consumes = { "q" },
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}
"""
WITH_WRAPPER = """local spec = { consumes = { "q" } }
return devloop_logging.wrap_pipeline_failure("worker", pipeline)
"""
NO_SURFACE = """local spec = { consumes = { "q" } }
"""


def messages(sources, allowlist, base=None):
    current = check.exposed_departments(sources)
    return check.ratchet_messages(current, allowlist, base if base is not None else allowlist)


class DeptFailureSurfaceTest(unittest.TestCase):
    def test_department_with_retry_policy_is_silent(self):
        self.assertEqual(messages({PROTECTED: WITH_RETRY}, set()), [])

    def test_department_with_failure_wrapper_is_silent(self):
        self.assertEqual(messages({PROTECTED: WITH_WRAPPER}, set()), [])

    def test_removing_the_retry_policy_makes_the_check_fire(self):
        """MUTATION: the property is removed, so the check MUST fail."""
        before = messages({PROTECTED: WITH_RETRY}, set())
        after = messages({PROTECTED: NO_SURFACE}, set())
        self.assertEqual(before, [])
        self.assertTrue(after, "removing retry+wrapper must produce a message")
        self.assertIn("neither a `retry` policy nor `wrap_pipeline_failure`", after[0])
        self.assertIn("pkg.worker", after[0])

    def test_removing_the_wrapper_makes_the_check_fire(self):
        """MUTATION: same property, other mechanism."""
        stripped = WITH_WRAPPER.replace("wrap_pipeline_failure", "some_other_helper")
        self.assertTrue(messages({PROTECTED: stripped}, set()))

    def test_unrelated_edit_does_not_satisfy_or_trip_the_check(self):
        """NEGATIVE CONTROL: an irrelevant change must not move the verdict either way.

        An earlier harness passed because *any* perturbation satisfied it. This asserts the
        check is coupled to the property and nothing else.
        """
        noisy = WITH_RETRY + "\n-- unrelated trailing comment\nlocal unused = 1\n"
        self.assertEqual(messages({PROTECTED: noisy}, set()), [])
        noisy_naked = NO_SURFACE + "\n-- unrelated trailing comment\n"
        self.assertTrue(messages({NAKED: noisy_naked}, set()))

    def test_dead_letter_is_structurally_exempt(self):
        self.assertTrue(check.is_structurally_exempt("pkg.dead_letter"))
        self.assertEqual(messages({DEAD_LETTER: NO_SURFACE}, set()), [])

    def test_test_probe_is_structurally_exempt(self):
        self.assertTrue(check.is_structurally_exempt("pkg.test_probe"))
        self.assertEqual(messages({PROBE: NO_SURFACE}, set()), [])

    def test_exemption_is_by_role_not_by_substring(self):
        """`dead_letter_replay` is not a DLQ consumer and must not inherit the exemption."""
        self.assertFalse(check.is_structurally_exempt("pkg.dead_letter_replay"))
        self.assertFalse(check.is_structurally_exempt("pkg.audit_test"))

    def test_allowlisted_department_is_silent_but_stale_entry_is_reported(self):
        allow = {"pkg.scanner"}
        self.assertEqual(messages({NAKED: NO_SURFACE}, allow), [])
        stale = messages({NAKED: WITH_RETRY}, allow)
        self.assertTrue(stale, "an allowlisted department that gained a surface must be reported")
        self.assertIn("stale allowlist entry", stale[0])

    def test_allowlist_growth_is_rejected(self):
        """MUTATION: the ratchet must only shrink."""
        base = set()
        grown = {"pkg.scanner"}
        grew = messages({NAKED: NO_SURFACE}, grown, base)
        self.assertTrue(grew)
        self.assertTrue(any("shrink-only" in m for m in grew))

    def test_new_department_cannot_be_silently_introduced(self):
        """A brand-new unprotected department is not covered by any existing allowlist."""
        allow = {"pkg.scanner"}
        fresh = messages({NAKED: NO_SURFACE, "packages/np/departments/nd/main.lua": NO_SURFACE}, allow)
        self.assertTrue(any("np.nd" in m for m in fresh))

    def test_dept_id_parses_package_and_department(self):
        self.assertEqual(check.dept_id(PROTECTED), "pkg.worker")
        self.assertIsNone(check.dept_id("packages/pkg/core.lua"))

    def test_retry_regex_requires_a_spec_table_not_a_mention(self):
        """A `retry` mentioned in prose or an unrelated require must not count as a surface."""
        mention = 'local spec = { consumes = { "q" } }\nlocal ci_repair_retry = require("core.ci_repair_retry")\n'
        self.assertIsNone(check.RETRY_RE.search(mention))
        self.assertTrue(messages({NAKED: mention}, set()))


if __name__ == "__main__":
    unittest.main()
