# Characterization digest audit

Date: 2026-08-10. Audited revision: `0ea3eb387686914e902a5b8404c7ba69530facf6`.

## Result

Nine of the campaign's 23 SHA-256 characterization digests were attempted. All nine are
**load-bearing** under the requested test-case criterion: a one-at-a-time production mutation
changed the pinned observable, the digest test failed, and no other test case in the complete
owning-package suite failed. None of the attempted digests was redundant or dead. The other 14
digests are unclassified; this audit does not extrapolate to them.

This result does not prove that the pinned bytes are the right behavioural contract. It proves only
that the ordinary owning-package suites did not independently reject the measured mutations. A
byte-identical reproduction on host and CI establishes determinism, not behaviour preservation. For
these nine digests, refreshing the expected hash after seeing only that reproduction would remove the
only failing test case observed here; maintenance therefore requires an independent semantic reason
for accepting the changed bytes.

## Method

The selection rule was breadth first: cover every merged campaign slice, spread attempts across the
owning packages, and then attempt additional digests where the producer was isolated in the already
loaded suite. Each package first passed its complete suite. Each measurement then changed production
code once, ran the same complete suite, counted failing test cases other than the named digest test,
and immediately reverted the mutation. Counts below are test-case counts, not assertion counts.

`T(P)` below abbreviates the exact command:

```sh
bash -c 'source scripts/run.sh; resolve_bin; cmd_test P'
```

The passing baselines were:

| `P` | Actual output |
| --- | --- |
| `github-devloop` | `1408 passed, 0 failed`; graph: `14 passed, 0 failed` |
| `github-devloop-decompose` | `20 passed, 0 failed`; graph: `1 passed, 0 failed` |
| `github-devloop-intake-default` | `44 passed, 0 failed`; graph: `3 passed, 0 failed` |
| `github-devloop-workflow` | `310 passed, 0 failed`; graph: `9 passed, 0 failed` |
| `github-devloop-integration` | `138 passed, 0 failed`; graph: `16 passed, 0 failed` |
| `github-devloop-pr` | `687 passed, 0 failed`; graph: `29 passed, 0 failed` |

## Verified classifications

Every row is **VERIFIED** by the stated mutation and command. `Other red` excludes the digest test
case itself.

| Digest and observable | Temporary production mutation | Command and actual output | Digest red | Other red | Classification |
| --- | --- | --- | --- | ---: | --- |
| `d6ef665abe1093bf511e344e5d7e6f1f5f263de28555712c2416d20b0dc8735f` - decompose prompt | Added one blank line in `packages/github-devloop-decompose/prompts/decompose.lua`; observed `28efe229...` | `T(github-devloop-decompose)`: `19 passed, 1 failed` | yes | 0 | load-bearing |
| `2eb948407b297ded9991b680828c40e9c7e0588d22c62c88905e5bbcc2dd69dc` - default intake prompt | Added a blank line before `END UNTRUSTED ISSUE DATA` in `libraries/devloop/intake/default.lua`; observed `359f9588...` | `T(github-devloop-intake-default)`: `43 passed, 1 failed` | yes | 0 | load-bearing |
| `63c005d7a03be403c0e192819b35e79afe3c1f47a8135ad66a401ee484df4ad5` - workflow intake prompt | Applied the same blank-line mutation to its actual producer, `libraries/devloop/intake/default.lua`; observed `642d9ab8a7937b72b6f93dfbe5ae3e998ef2bb591e7b12e11dfe7049f879ec9a` | `T(github-devloop-workflow)`: `309 passed, 1 failed` | yes | 0 | load-bearing |
| `d2d030bca6250f11038b0a459e08aba7b8ff8380e871e98ce1d90d88f2fdf709` - sync-conflict prompt | Changed final punctuation from `English.` to `English;`; observed `570aad119cc7f2f29a8ad0ae88df2f45b3dcf67cac3d7674cfd207ec3cc1cfe4` | `T(github-devloop-integration)`: `137 passed, 1 failed` | yes | 0 | load-bearing |
| `10ce8e9af825edc5912d66c7c5e8f5ea0ecb971eef611ae0d974f1f6b80ca861` - localized decompose comment corpus | Changed ` follow-up issue(s)` to ` follow-up issue(s).` in `libraries/devloop/strings.lua`; observed `4fd13a14537d6ac6ae3dd6d0db0fe65e8e034705d0406f8fa0707c2dfded29c3` | `T(github-devloop-decompose)`: `19 passed, 1 failed` | yes | 0 | load-bearing |
| `de2638a2ad7ccff538541e829aa1ad627d12d80b2b0b39dd035bb8a1cfb8c3a9` - intake enable trace | Swapped the label-request and execution-request raises in `raise_enable_successor`; observed `38bf37226740936c7fa1a2127122c85a24b99fc7510a8f171d9649d92385e78a` | `T(github-devloop-intake-default)`: `43 passed, 1 failed` | yes | 0 | load-bearing at test-case granularity |
| `fc3960eeb292e9aef975532b40d37b2e78efd8f71ce7db33a04fd504aacd18ad` - intake class-escalation trace | Added a blank line before `Source proposal:` in `packages/github-devloop-intake-default/core/intake_class.lua`; observed `017ac8906ddb270fbafc81ddc79dcaf2a0bf2776138b0aea28170102b43e9df5` | `T(github-devloop-intake-default)`: `43 passed, 1 failed` | yes | 0 | load-bearing |
| `c39d206fa7adc2288511db477c44fe65d2e8633f0b7ab790f61f0d30c6856bb1` - PR restart transition table | Reversed adjacent `merge-ready` lineage keys `merge-ready.version` and `merge-ready.pr`; observed `e26992ae83eb92da6840e0c00979c49df1bd8f708feb70e5d84595566bbc4d6b` | `T(github-devloop-pr)`: `686 passed, 1 failed` | yes | 0 | load-bearing |
| `f7530aed4eac534c06dc3d5a09901be69df333106323323c93b79f7cd07cf64c` - PR request payload corpus | Changed `\n\n` to `\n\n\n` before the review-convergence marker in `build_review_converge_round_comment_request`; observed `a4627a4340092b84aa5577a4e0bea4e2cc50449c6771ddd4786ffc9f51fb60a9` | `T(github-devloop-pr)`: `686 passed, 1 failed` | yes | 0 | load-bearing |

The enable-trace digest assertion precedes ordinary order assertions in the same test case. The suite
therefore verifies zero *other failing test cases*, but does not establish assertion-level
independence for that digest.

## Honest coverage

The following 14 campaign digests were **not attempted** and remain **UNKNOWN**, not load-bearing,
redundant, or dead:

| Digest | Observable | Reason skipped |
| --- | --- | --- |
| `5df806db725a7eebc27aa952a212ff8b1c44f2c47ce3fce82821b43dd306794f` | implement prompt | Bounded breadth-first sample stopped before the remaining prompt digests. |
| `a1fad069781ea718c89d3bd31665a0cf4eb2599cde9491f60871e02baa494e1e` | PR fix prompt | Bounded breadth-first sample stopped before the remaining prompt digests. |
| `d7e296412e758cbf32e9c48855d90f29e58cad128320d5918d369fb2ff664193` | PR review-meta prompt | Bounded breadth-first sample stopped before the remaining prompt digests. |
| `59e30fff3e994b8657a00ba57a1750ba1d1a6776856a2b075e8d9ae2c11f2a80` | issue restart transition table | Bounded sample exercised the other restart table. |
| `c29d3b53f8cc9bc15c3d001d50071260a3817c3e52bba956690330bb448027ba` | reviewing-validator acceptance matrix | Bounded sample exercised localization from the same campaign slice. |
| `b7f5638206551caa67c63a58c69be879dd5d574aed408711d8a7c9c0a1637915` | issue-parser result corpus | Bounded sample exercised localization from the same campaign slice. |
| `fc7bb7b9ac64411d4e52bedb359a2f560bce2daa1eafaddf527452968b049a2d` | ready-validator acceptance matrix | Bounded sample exercised localization from the same campaign slice. |
| `f51e9b0f732887649173d3642ead28ea02c3d35853818a580b0e67b8f735aca4` | devloop localized-comment corpus | Bounded sample exercised the decompose localization corpus. |
| `9d6561d34992b6dcd34295fb701cc9c50afb8c70d5222596e3313e7d673eef1d` | context-bundle corpus | Bounded sample exercised a request corpus from the same campaign slice. |
| `1ecdbd4c8bbbcb8eacdf1f834bb899ef7ae6361a6d275eab98fdbc6fef52104c` | issue request/payload corpus | Bounded sample exercised the PR request corpus. |
| `10823adbf044aca0a76a1d0be0f97f65201263f02b4a57eddd4f707ca7a5d434` | autonomy-ledger record | Bounded sample exercised two intake traces from the same campaign slice. |
| `1f39664eb997003f5e5cf6b11ae1d0a777d2d3cf16a8b3d062fb889c14f479f7` | execution-start effects | Bounded sample exercised two intake traces from the same campaign slice. |
| `be5afe5026b67c60fbdd933fb972144e686143fd1cb05c3e80a1cf031023b27e` | fork issue-create request | Bounded sample exercised two intake traces from the same campaign slice. |
| `c155d8e9228dccab1f318eff16cf0fd9cd8ba7fcbd58186fe5052a27da6cae95` | convergence marker bytes and round accounting | Absent from audited `HEAD`; found only in non-ancestor commit `39006693`, so no current production mutation was available. |

## Notes and inference boundary

**VERIFIED:** two initial workflow-prompt mutations in `prompts/workflow_select.lua` left the suite
fully green; source tracing then identified `libraries/devloop/intake/default.lua` as the producer and
the qualifying mutation above turned the digest red.

**VERIFIED non-qualifying probes:** swapping restart-index rows was rejected as an unsorted registry
before the digest assertion (`12 passed, 120 failed`). Swapping restart entitlement-ID order changed
the digest to `58d64cc3...` and produced `685 passed, 2 failed`, including one ordinary entitlement-order
test. Adding a newline to a reviewing-comment request changed its digest to `6c570bbe...` and produced
`685 passed, 2 failed`, including one ordinary old-behaviour observation test. These probes do not
alter the classifications because each classified digest also has the isolated witness recorded in
the table.

**INFERRED:** the nine isolated witnesses show that digest refreshes for these exact observables need
semantic review beyond determinism. The audit did not decide whether any measured byte change is
semantically acceptable, did not test assertion-level independence except where separate test cases
made it observable, and makes no claim about the 14 skipped digests.

No redundant digest was measured, so this audit supplies no evidence-based removal recommendation.
Any digest later shown redundant should be removed rather than maintained: unenforced ceremony that
looks like evidence is worse than no evidence.

⟦AI:FKST⟧
