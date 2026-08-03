# Thinking Redrive Delivery Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every over-budget `thinking` redrive reaches the consensus receiver as a fresh durable delivery while preserving the logical consensus lineage.

**Architecture:** Treat `dedup_key` as the delivery identity and `effect_version` as the logical workflow identity, following at-least-once delivery with idempotent effects. The liveness replay will derive an attempt-specific delivery key only after the real-execution check; `consensus_call.reach()` will normalize that delivery payload back to the logical identity before invoking the source-agnostic consensus library.

**Tech Stack:** Lua packages and workspace libraries, `fkst.test` department tests, production-shaped `testkit.graph` delivery traces.

---

### Task 1: Reproduce repeated thinking redrives

**Files:**
- Create: `packages/github-devloop/tests/thinking_redrive_delivery_identity_test.lua`
- Modify: `packages/github-devloop/tests/thinking_dispatch_live_run_test.lua`

- [ ] **Step 1: Write the failing multi-tick test**

Drive the same trusted `thinking` marker through two over-budget observations. Feed the first emitted `timeout-attempt:v2` marker into the second observation, then assert:

```lua
t.eq(first_request.payload.effect_version, logical_version)
t.eq(second_request.payload.effect_version, logical_version)
t.is_true(first_request.payload.dedup_key ~= logical_version)
t.is_true(second_request.payload.dedup_key ~= first_request.payload.dedup_key)
```

Deliver both emitted requests through `testkit.graph` and require the production receiver boundary:

```lua
local step = graph.require_delivery(trace, {
  queue = "github-devloop.devloop_consensus_request",
  consumer = "github-devloop.consensus_result",
})
t.eq(step.exit_code, 0)
```

- [ ] **Step 2: Run the focused package test and verify RED**

Run:

```bash
scripts/run.sh test github-devloop
```

Expected: FAIL because both redrives currently reuse the logical proposal `dedup_key` and omit `effect_version`.

### Task 2: Separate delivery identity from logical effect identity

**Files:**
- Modify: `libraries/devloop/payloads/shared.lua`
- Modify: `libraries/devloop/payloads/builders.lua`
- Modify: `libraries/devloop/validators/ready.lua`
- Modify: `libraries/devloop/replay_thinking_convergence.lua`
- Modify: `libraries/devloop/consensus_call.lua`
- Modify: `packages/github-devloop/tests/integration_implement_liveness_test.lua`
- Modify: `packages/github-devloop/tests/consensus_call_test.lua`

- [ ] **Step 1: Generalize the existing issue redrive key helper**

Rename `ready_redrive_delivery_dedup_key` to `issue_redrive_delivery_dedup_key` without a compatibility alias. Keep the existing validation of `proposal_id`, logical version, generation key, and positive integer attempt.

- [ ] **Step 2: Attach a fresh delivery identity after the live-run check**

In `replay_thinking_convergence.replay()`, retain the canonical proposal key for `dispatch_live_run()`. When no receiver is live and `facts.redrive_delivery` is present, set:

```lua
proposal.effect_version = proposal.dedup_key
proposal.redrive_delivery = {
  generation_key = facts.redrive_delivery.generation_key,
  attempt = facts.redrive_delivery.attempt,
}
proposal.dedup_key = payloads_shared.issue_redrive_delivery_dedup_key(
  proposal_id,
  proposal.effect_version,
  proposal.redrive_delivery
)
```

Revalidate the mutated proposal and fail loudly if the program-generated payload violates its contract.

- [ ] **Step 3: Normalize the consensus call to logical identity**

When `effect_version` is present, `consensus_call.reach()` must pass a copy with `dedup_key = effect_version` to `consensus.reach()`. This keeps result memoization, convergence keys, and returned result lineage stable while the outer event retains its fresh delivery key.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
scripts/run.sh test github-devloop
```

Expected: PASS with both redrive requests delivered to `github-devloop.consensus_result`, distinct delivery identities, and one logical effect version.

### Task 3: Verify and checkpoint

**Files:**
- Verify all files changed above.

- [ ] **Step 1: Run the configured local gate**

Run exactly:

```bash
scripts/run.sh test-affected
```

Expected: exit 0 with every affected package passing.

- [ ] **Step 2: Inspect the final repository state**

Run:

```bash
git diff --check
git status --porcelain
```

Expected: no whitespace errors and visible implementation changes in the isolated worktree.

- [ ] **Step 3: Commit only coherent buildable checkpoints**

Use English imperative commit subjects and do not push or modify GitHub state.
