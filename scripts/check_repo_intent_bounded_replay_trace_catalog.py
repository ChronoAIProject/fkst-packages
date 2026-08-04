#!/usr/bin/env python3
"""Canonical admission-trace artifact locations."""

from __future__ import annotations

from pathlib import Path


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
PR_REVIEW_ACTIVATION_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-activation.json"
PR_REVIEW_ACTIVATION_NEW_TRACE = ".fkst/run/r9-pr-review-activation-new-trace.json"
OBSERVE_PR_FIX_OLD_CORPUS = "migration/intent_bounded_replay/corpus/observe-pr-fix.json"
OBSERVE_PR_FIX_NEW_TRACE = ".fkst/run/r9-observe-pr-fix-new-trace.json"
PR_REVIEW_LOOP_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-loop.json"
PR_REVIEW_LOOP_NEW_TRACE = ".fkst/run/r9-pr-review-loop-new-trace.json"
PR_FIX_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-fix-reconcile.json"
PR_FIX_RECONCILE_NEW_TRACE = ".fkst/run/r9-pr-fix-reconcile-new-trace.json"
PR_MERGE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-merge.json"
PR_MERGE_NEW_TRACE = ".fkst/run/r9-pr-merge-new-trace.json"


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
            PR_REVIEW_ACTIVATION_NEW_TRACE,
            OBSERVE_PR_FIX_NEW_TRACE,
            PR_REVIEW_LOOP_NEW_TRACE,
            PR_FIX_RECONCILE_NEW_TRACE,
            PR_MERGE_NEW_TRACE,
        )
        if (Path(root) / relative).is_file()
    ]
    if not emitted:
        return "admission trace comparisons skipped: emitted traces are absent"
    return "admission trace comparisons executed by canonical artifact hash: " + ", ".join(emitted)
