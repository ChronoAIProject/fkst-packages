# Library error-class debt — spec

Status: ACTIVE
Scope: the 721 entries in `migration/library-error-class.allowlist`.
Out of scope: Rust engine work (belongs to `fkst-substrate`).

## 0. How this was produced

Six isolated seats (`teleology`, `parsimony`, `fidelity`, `natural-ownership`,
`proportional-containment`, `worth`) each measured the debt read-only and returned a verdict without
seeing each other. They produced **41 candidate items and 38 distinct rejections**. Verdicts: one
`propose`, five `revise` — no seat accepted the naive framing.

A previous round (`docs/superpowers/specs/2026-08-04-refactor-campaign-spec.md` §6 row 1) rejected
clearing this debt 5:1. The user then asked for it explicitly. This spec is neither a re-refusal nor
a rubber stamp: it is what the measurements say is actually true.

**Three of my own premises were refuted during intake and are recorded here rather than quietly
dropped** — see §5.

## 1. What the debt actually is

`scripts/check_repo.py:66` decides "classified":

```python
ERROR_CLASS_PREFIX_RE = re.compile(r"^[a-z0-9][a-z0-9-]*: [a-z0-9][a-z0-9-]*:")
                                     subsystem              error class
```

Composition of the 721, measured by reading every source line:

| count | share | what it lacks |
|---|---|---|
| 664 | 92% | one namespace segment, **no error class** — `error("contract.convergence_identity: missing proposal")` |
| 42 | 5% | no prefix at all — `error("restart kernel: ops must be a table")` |
| 6 | <1% | **already two segments**, rejected only because segment 1 contains a dot |
| 9 | 1% | line no longer readable (other work moved it) |

By library: devloop 539, testkit_internal 78, forge 65, workflow_internal 13, contract 10,
workflow 5, testkit 2. 712 readable sites → 561 distinct messages.

## 2. The root cause — seven grammars, not 721 missing words

There **is** a runtime consumer. `libraries/devloop/logging.lua:20-29` defines
`error_class_from_message(message)`, which pattern-matches message text to extract a class and falls
back to `"caught-failure"`. It has **23 call sites**, one per package pipeline error handler, reached
through `wrap_pipeline_failure`'s `pcall(fn, event)` — so **any** error raised beneath a pipeline
arrives there.

But there is not one parser. There are **six**, each hardcoding its own namespace:

```
libraries/devloop/logging.lua                      "github-devloop:"
libraries/consensus/core.lua                       "consensus:"
packages/autochrono/core.lua                       "autochrono:"
packages/github-proxy/core/error_facts.lua
packages/github-external-pr-intake/core.lua
packages/github-ratchet-migration-slicer/core.lua
```

plus a seventh grammar in the gate itself, `scripts/check_repo.py:66`:
`^[a-z0-9][a-z0-9-]*: [a-z0-9][a-z0-9-]*:`.

**Seven independent definitions of what an error class is.** The checker declares 721 sites
"unclassified" using grammar #7 while runtime extraction uses grammars #1–#6, which disagree with it
and with each other. That is a duplicated source of truth, and it means **the debt count itself is not
a trustworthy number** — it measures conformance to one grammar that no consumer uses verbatim.

### 2.1 Why the obvious split is circular — recorded because I proposed it

My first ruling was: classify the 234 sites in the `github-devloop:` namespace because a parser
already consumes that namespace, and defer the other 478 as having no consumer.

**A cross-model review rejected that as circular, and the measurement confirms it.** The 478 are not
unreachable — they are *refused by a hardcoded prefix list*:

```
wrap_pipeline_failure wraps the entire pipeline in pcall, so any error beneath it arrives
devloop.restart_edges                    (116 debts)  required by 15 package files
devloop.restart_owner_pending_projection  (33 debts)  required by 41 package files
```

Those errors do reach the same 23 handlers. They collapse to `caught-failure` **because the parser
does not recognise their prefix**, not because they are semantically out of scope. Using that
limitation as the criterion for which sites deserve classification is using the defect under
examination as the evidence for the remedy.

### 2.2 What classification actually buys — stated honestly

It does **not** improve fingerprint discrimination. `contract/error_facts.lua:38`:

```lua
F.error_fingerprint(error_class, queue, dept, message)
  = stable_hash(class .. "|" .. queue .. "|" .. dept .. "|" .. normalized_message(message))
```

`class` is computed *from* `message`, and `normalized_message` only rewrites timestamps, SHAs, paths
and whitespace — it **preserves the prefix**. `class` is therefore a deterministic function of another
input to the same hash: marginal contribution to discrimination **exactly zero**.

It also unlocks no program branch. Every one of the 25 `error_class` mentions that look like branches
is a length/nil check in `github-devloop-ops/core/error_facts.lua` — formatting, not routing.

**The value is observability**: `error_class=` stops being `caught-failure` and becomes a narrow,
greppable token that L2 triage codex and operators can aggregate. That is real and it is what
CLAUDE.md's three-tier model asks for. **It is not a routing unlock, and this spec does not claim the
stronger thing** — a cross-model review flagged that exact overclaim as fatal, correctly.

## 3. Scheduled work

The order matters: fix the definition before paying to conform to it.

### E1 — Regenerate the ledger from the authoritative scan *(no behaviour change)*
Nine rows point at lines other work has moved or deleted. My first draft hand-picked two of them and
left seven unexplained; a cross-model review caught that. Regenerate the whole ledger from
`check_repo.py`'s own classifier rather than editing rows by hand, so every row is derived, not
curated. Gate: the regenerated set differs from the current one only by rows whose source line no
longer contains an unclassified `error()`.

### E2 — One grammar, one owner *(the root-cause fix)*
`contract.error_facts` owns the error-envelope grammar: a single `error_class_from_message` with a
generic anchored two-segment rule, no hardcoded product namespace. The six runtime parsers delegate to
it. `scripts/check_repo.py` validates against the same grammar.

This is the item that makes everything else meaningful: after it, "unclassified" means one thing, and
classifying any namespace is consumed by every handler rather than only the one whose prefix was
hardcoded.

- The grammar accepts hierarchical subsystems (`a.b`, `a_b`), which resolves the 6 entries that are
  **already correctly classified** and rejected only for containing a dot. `fidelity` measured **431**
  readable entries using dotted/underscored namespaces, so the narrow regex would otherwise force a
  rename cascade far beyond those six.
- **Required controls**: a one-segment dotted message (`a.b: prose`) must still FAIL; each of the six
  migrated parsers must return the same class as before for its existing fixtures; leading/trailing/
  repeated dots must be rejected.
- **Objection recorded** (`worth`, and a cross-model review): widening the grammar could admit shapes
  that should fail. The controls above exist to falsify that, and the item does not ship without them
  going red first on the old grammar.

### E3 — Classify by measured value, in file-owned slices *(behaviour change, staged)*
Only after E2. Slice selection is by **error volume and triage value**, not by which prefix a parser
happened to hardcode.

- Each slice: insert `class: ` after the existing subsystem; **preserve remaining message text
  verbatim** — `worth` measured 26 direct test assertions on that text.
- Per-slice gate: package suite green, plus a before/after assertion that the unified parser returns
  the intended class for every touched literal.
- **Cost, plainly**: independent semantic decisions across the whole debt measured at **505 / 600 /
  601** by three seats using three methods. This is not a mechanical edit and must not be scheduled as
  one.
- **Stopping rule**: this spec does not promise 721 → 0. It promises that every entry has a
  disposition and that the remaining ones carry a machine-checked reason. A cross-model review called
  an open-ended grandfather list "an unsupported temporal asymmetry" — so any entry not classified
  must name why, and E2 is what makes "no consumer" a false reason.

## 4. Explicitly not doing

| # | Candidate | Why not |
|---|---|---|
| 1 | Derive the class from the leading word (`invalid` → `invalid`) | **Rejected by 4 seats.** `invalid` covers 184 sites but **152 distinct expressions**; `owner_edges` covers 26 sites across 5 predicates. One class over them violates the narrow-class rule and hands L2 a *false* route — worse than no class. |
| 2 | Delete the G-LIB-ERROR-CLASS gate entirely | `teleology` proposed it on skipped-purpose grounds. Rejected: the gate's live value is blocking **new** unclassified errors, which survives every criticism of its backlog. |
| 3 | A repo-wide error-class taxonomy / enum | `natural-ownership` and `proportional-containment` both reject: no cross-library recovery dispatch exists (`failure_triage.lua:556-569` renders classes, never branches on them). Speculative generality binding every future raiser. |
| 4 | Exempt `testkit`/`testkit_internal` by directory name | **Rejected by 2 seats.** `libraries/testkit/fkst.toml:13-24` declares a publishable host surface, so external consumers are ASSUMED-UNVERIFIED. A name-based checker exemption is a leaked abstraction. |
| 5 | Re-key the ledger by message or hash | **Rejected by 2 seats.** Message keys are non-injective — the prior round measured 31% of sites sharing literals. And after E1–E3 only a handful of rows remain, so an identity rewrite has no recurring payoff. |
| 6 | Split the gate per library | **Rejected by 2 seats.** Seven policy surfaces, same proxy, no stronger truth. Paths already provide library scoping. |
| 7 | A typed error constructor / tagged errors | Attractive shape, but the L2 dead-letter class is assigned in `fkst-substrate` `failure_fact.rs`, and Rust work belongs to that repo. |
| 8 | One 721-site rewrite PR | 600 semantic decisions plus 718 observable text changes in a single live-pipeline diff. |

## 5. Premises of mine that were refuted during intake

Recorded because a corrected premise that is not written down gets re-adopted.

1. **"Nothing consumes these error strings."** I searched with a pattern keyed on variable names
   (`err|error|msg|message|reason`) and found nothing. Five seats independently found
   `error_class_from_message`, whose local variable is `text`. My filter assumed the shape of what it
   was looking for. **The consumer exists** and it is what makes E3 worth doing at all.
2. **"The leading-word histogram shows high repetition, so this is largely mechanical."** False.
   Same leading word ≠ same error class: `invalid` is 152 distinct expressions. The real decision count
   is 505–601.
3. **"Classifying improves fingerprint dedup."** False, and provably so — see §2.1. `class` is a
   function of `message`, which is already in the hash.

⟦AI:FKST⟧
