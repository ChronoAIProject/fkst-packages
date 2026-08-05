#!/usr/bin/env python3
"""Canonical admission-trace artifact locations."""

from __future__ import annotations

from pathlib import Path


THINKING_OLD_CORPUS = "migration/intent_bounded_replay/corpus/thinking.json"
THINKING_NEW_TRACE = "r9-thinking-new-trace.json"
ISSUE_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/issue-reconcile.json"
ISSUE_RECONCILE_NEW_TRACE = "r9-issue-reconcile-new-trace.json"
LOOP_PLAIN_OLD_CORPUS = "migration/intent_bounded_replay/corpus/loop-plain.json"
LOOP_PLAIN_NEW_TRACE = "r9-loop-plain-new-trace.json"
IMPLEMENT_ACTIVATION_OLD_CORPUS = "migration/intent_bounded_replay/corpus/implement-activation.json"
IMPLEMENT_ACTIVATION_NEW_TRACE = "r9-implement-activation-new-trace.json"
AWAITING_PR_OLD_CORPUS = "migration/intent_bounded_replay/corpus/awaiting-pr.json"
AWAITING_PR_NEW_TRACE = "r9-awaiting-pr-new-trace.json"
TIMEOUT_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/timeout-reconcile.json"
TIMEOUT_RECONCILE_NEW_TRACE = "r9-timeout-reconcile-new-trace.json"
OBSERVE_ISSUE_ENTRY_OLD_CORPUS = "migration/intent_bounded_replay/corpus/observe-issue-entry.json"
OBSERVE_ISSUE_ENTRY_NEW_TRACE = "r9-observe-issue-entry-new-trace.json"
PR_REVIEW_RESULT_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-result.json"
PR_REVIEW_RESULT_NEW_TRACE = "r9-pr-review-result-new-trace.json"
PR_REVIEW_META_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-meta.json"
PR_REVIEW_META_NEW_TRACE = "r9-pr-review-meta-new-trace.json"
PR_FIX_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-fix.json"
PR_FIX_NEW_TRACE = "r9-pr-fix-new-trace.json"
PR_REVIEW_ACTIVATION_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-activation.json"
PR_REVIEW_ACTIVATION_NEW_TRACE = "r9-pr-review-activation-new-trace.json"
OBSERVE_PR_FIX_OLD_CORPUS = "migration/intent_bounded_replay/corpus/observe-pr-fix.json"
OBSERVE_PR_FIX_NEW_TRACE = "r9-observe-pr-fix-new-trace.json"
PR_REVIEW_LOOP_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-review-loop.json"
PR_REVIEW_LOOP_NEW_TRACE = "r9-pr-review-loop-new-trace.json"
PR_FIX_RECONCILE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-fix-reconcile.json"
PR_FIX_RECONCILE_NEW_TRACE = "r9-pr-fix-reconcile-new-trace.json"
PR_MERGE_OLD_CORPUS = "migration/intent_bounded_replay/corpus/pr-merge.json"
PR_MERGE_NEW_TRACE = "r9-pr-merge-new-trace.json"


ADMISSION_TRACE_SPECS = (
    (THINKING_OLD_CORPUS, THINKING_NEW_TRACE,
     "restart-thinking-trace.v1", "thinking", "github-devloop"),
    (ISSUE_RECONCILE_OLD_CORPUS, ISSUE_RECONCILE_NEW_TRACE,
     "restart-issue-reconcile-trace.v1", "issue-reconcile", "github-devloop"),
    (LOOP_PLAIN_OLD_CORPUS, LOOP_PLAIN_NEW_TRACE,
     "restart-loop-plain-trace.v1", "loop-plain", "github-devloop"),
    (IMPLEMENT_ACTIVATION_OLD_CORPUS, IMPLEMENT_ACTIVATION_NEW_TRACE,
     "restart-implement-activation-trace.v1", "implement-activation", "github-devloop"),
    (AWAITING_PR_OLD_CORPUS, AWAITING_PR_NEW_TRACE,
     "restart-awaiting-pr-trace.v1", "awaiting-pr", "github-devloop"),
    (TIMEOUT_RECONCILE_OLD_CORPUS, TIMEOUT_RECONCILE_NEW_TRACE,
     "restart-timeout-reconcile-trace.v1", "timeout-reconcile", "github-devloop"),
    (OBSERVE_ISSUE_ENTRY_OLD_CORPUS, OBSERVE_ISSUE_ENTRY_NEW_TRACE,
     "restart-observe-issue-entry-trace.v1", "observe-issue-entry", "github-devloop"),
    (PR_REVIEW_RESULT_OLD_CORPUS, PR_REVIEW_RESULT_NEW_TRACE,
     "restart-pr-review-result-trace.v1", "pr-review-result", "github-devloop-pr"),
    (PR_REVIEW_META_OLD_CORPUS, PR_REVIEW_META_NEW_TRACE,
     "restart-pr-review-meta-trace.v1", "pr-review-meta", "github-devloop-pr"),
    (PR_FIX_OLD_CORPUS, PR_FIX_NEW_TRACE,
     "restart-pr-fix-trace.v1", "pr-fix", "github-devloop-pr"),
    (PR_REVIEW_ACTIVATION_OLD_CORPUS, PR_REVIEW_ACTIVATION_NEW_TRACE,
     "restart-pr-review-activation-trace.v1", "pr-review-activation", "github-devloop-pr"),
    (OBSERVE_PR_FIX_OLD_CORPUS, OBSERVE_PR_FIX_NEW_TRACE,
     "restart-observe-pr-fix-trace.v1", "observe-pr-fix", "github-devloop-pr"),
    (PR_REVIEW_LOOP_OLD_CORPUS, PR_REVIEW_LOOP_NEW_TRACE,
     "restart-pr-review-loop-trace.v1", "pr-review-loop", "github-devloop-pr"),
    (PR_FIX_RECONCILE_OLD_CORPUS, PR_FIX_RECONCILE_NEW_TRACE,
     "restart-pr-fix-reconcile-trace.v1", "pr-fix-reconcile", "github-devloop-pr"),
    (PR_MERGE_OLD_CORPUS, PR_MERGE_NEW_TRACE,
     "restart-pr-merge-trace.v1", "pr-merge", "github-devloop-pr"),
)


def admission_trace_status(trace_root: Path | None) -> str:
    if trace_root is None:
        return "admission trace comparisons skipped: no explicit trace root"
    emitted = [
        new_relative
        for _, new_relative, _, _, _ in ADMISSION_TRACE_SPECS
        if (trace_root / new_relative).is_file()
    ]
    if not emitted:
        return "admission trace comparisons skipped: emitted traces are absent"
    return "admission trace comparisons executed by canonical artifact hash: " + ", ".join(emitted)
