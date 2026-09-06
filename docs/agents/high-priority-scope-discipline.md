# Operating Rules for `priority:high` Work

High-priority work optimizes for closing the demonstrated problem, not for satisfying every observation an automated reviewer can derive from the changed code.

**Automated review is a defect detector, not a scope authority.**

These rules are derived from a real failure. #1189 spent seventeen commits and ten review rounds on a fix for #1188. Findings per round ran 4, 1, 3, 1, 1, 6, 1, 2, 1 — rising, not converging — and roughly half of the later findings were interactions with rules added in the round before, including three regressions introduced in a single round. Every reviewer was correct every time. The error was converting each correct finding into an obligation instead of asking whether the guarantee being defended was one the issue required. #1189 was eventually closed unmerged and replaced by #1196, a one-word change.

Three rules here are load-bearing rather than advisory: **rule 3**, **rule 5**, and **rule 11**. Their enforcement is tracked in #1199.

## 1. Freeze the contract before implementation

Before opening a PR, write a short implementation contract containing:

- **Problem being fixed** — the observed failure or measured cost that makes the issue high priority.
- **Required outcome** — the smallest externally observable behavior that must change.
- **Invariants that must remain true** — existing safety properties the fix may not weaken.
- **Explicit non-goals** — adjacent guarantees this PR does not attempt to provide.
- **Acceptance evidence** — the tests, reproduction, measurement, or canary that proves the required outcome.
- **Stop condition** — what constitutes enough evidence to merge.

Once implementation begins, automated review may identify defects in satisfying this contract. It may not silently enlarge the contract.

## 2. Classify every review finding before changing code

Every automated-review finding must receive exactly one disposition.

### A. Required — fix in this PR

Fix only when the finding demonstrates that the current patch:

- does not satisfy an acceptance criterion;
- violates an invariant explicitly preserved by the issue;
- introduces a regression reachable because of this patch;
- creates a security or correctness failure on the changed execution path; or
- makes the proposed implementation internally inconsistent.

The burden is on the finding to connect itself to the frozen contract.

### B. Valid but adjacent — file or fold into follow-up

The finding may be correct, but fixing it would require:

- a stronger guarantee than the issue requires;
- support for an additional state, caller, configuration, concurrency model, or recovery path;
- a new abstraction or generalized framework;
- changes to unrelated existing behavior;
- hardening against a pre-existing condition not made worse by this PR; or
- materially new acceptance criteria.

Record it separately. Do not implement it merely because it was discovered during review.

### C. Rebutted

Record why the finding does not apply, is unreachable under the contract, mistakes a deliberate tradeoff for a defect, or asks for a guarantee explicitly listed as a non-goal.

A rebutted finding does not become required because another reviewer repeats it.

## 3. No new guarantee without an explicit scope decision

**Load-bearing.** If satisfying a finding requires adding words such as "always", "under arbitrary concurrency", "for every caller", "even if configuration is malformed", "across all interleavings", "atomically", "prove", "canonical", "authoritative", "fully close", or "prevent all" — stop.

Those phrases usually indicate that a local fix is being converted into a stronger system contract. Do not implement that stronger contract unless it was already part of the issue. File it separately, or obtain an explicit owner decision to expand scope.

The trigger is the finding's *disposition*, not the vocabulary of the codebase. Several of these words are ordinary technical vocabulary here — "canonical" describes propagation paths in dozens of files — so the rule fires when a finding using one is dispositioned **Required**, not whenever the word appears.

## 4. Prefer a bounded residual risk to an unbounded mechanism

A known residual failure mode is acceptable when all of these hold:

1. it is outside the issue's required contract;
2. its failure direction is understood;
3. it does not make the original defect worse;
4. it is documented;
5. it can be tracked separately if worth fixing.

Do not build serialization, state machines, watermarks, epochs, reconciliation protocols, generalized parsers, or new policy layers merely to eliminate a residual outside the contract.

#1189 is the canonical warning: attempts to establish stronger cross-invocation ordering generated new interactions faster than review eliminated them. Five successive mechanisms were built and removed — an evaluation-epoch marker, a clean-verdict watermark, a read-after-write reconciliation for the burial race that watermark created, evaluation-order arbitration, and a per-stage re-stamp. The correct move was to reduce the guarantee and separate the stronger concurrency problem into #1191.

## 5. A finding caused by the previous finding's fix is a stop signal

**Load-bearing.** If an automated review finds a new defect in machinery introduced solely to satisfy an earlier review finding, do not immediately fix it. Reassess the abstraction first.

After **two consecutive findings in reviewer-induced machinery**, default to removing that machinery and returning to the smallest implementation that satisfies the original contract.

After **three substantive review rounds without decreasing scope**, the PR must undergo a scope review before another code change.

The question becomes *what can we delete or defer while still satisfying the original issue?* — not *what additional guard makes this latest finding impossible?*

## 6. Review does not get to generalize a local requirement

A fix for one concrete failure does not automatically need to become a reusable framework, a canonical parser, a fleet-wide abstraction, a generalized provenance system, a complete concurrency protocol, a new policy primitive, or protection against every theoretically related malformed state.

Generalization requires independent evidence that the broader problem is itself worth solving now.

#1112 is the warning here: recording the bootstrap source SHA did not inherently require proving a broad canonical-source provenance contract. Once review started asking which sources were trustworthy, the PR stopped being attribution and became source validation.

## 7. Preserve failure polarity; do not demand completeness

For merge-safety work, distinguish:

- **unsafe false green** — generally must block;
- **safe false red** — may be acceptable residual friction;
- **availability failure** — fix when it is part of the issue's measured problem;
- **missing theoretical guarantee** — not automatically a defect.

Do not turn every safe false-red possibility into additional synchronization machinery merely for conceptual completeness. Likewise, do not accept a false green merely to reduce friction.

## 8. Test the contract, not the review history

Regression tests should prove that the original reproduction fails before the fix and passes after it, that explicit invariants remain intact, that known boundary cases required by the contract work, and that the test is non-vacuous where appropriate.

Do not automatically add a permanent test for every speculative shape raised during review. If a test exists only because a reviewer invented an out-of-scope guarantee, the test itself is scope creep.

## 9. Keep the PR smaller than the issue

A high-priority issue may describe a large operational problem. Its first PR does not need to solve the entire subsystem.

Prefer the smallest independently useful tranche that changes the measured failure, can be verified, and does not foreclose the rest of the issue.

For staged issues such as #937, a successful stage is a deliverable. A failed canary can also be a successful diagnostic outcome when the issue defines it that way.

## 10. Follow-up issues are a convergence mechanism

Filing a valid finding separately is not unfinished work. It is the preferred response when the finding would increase the current PR's contract.

A follow-up should state the newly discovered condition, whether it is reachable today, the failure direction, the evidence, why it is outside the current PR, and whether it changes the current PR's safety.

Do not inherit the parent issue's `priority:high` automatically. Prioritize the follow-up independently.

## 11. Re-review the same contract, not the enlarged implementation

**Load-bearing.** Every review request after the first should tell reviewers:

> Review this PR against the stated contract and non-goals. Report defects that prevent the patch from satisfying that contract, or regressions introduced by the patch. Do not require stronger guarantees, generalized handling, or adjacent hardening as conditions of merge; identify those separately as follow-up findings.

If scope has deliberately changed, update the contract before requesting another review. Reviewers should never infer the new scope from machinery that a previous reviewer caused to be added.

## 12. Stop when the issue is proved

Merge when the frozen required outcome is satisfied, explicit invariants hold, required-tier findings against that contract are resolved or rebutted, acceptance evidence passes, and remaining findings are documented follow-ups or accepted residuals.

Do not continue reviewing merely because another review might find something. The objective for `priority:high` work is risk reduction per unit time, not exhaustion of the possible finding space.

## Mandatory scope checkpoint

For every `priority:high` PR, after each substantive automated-review round, record:

```
Contract changed?                            yes / no
Production code added because of this review: +N / -N lines
New concepts introduced:                      none / list
Finding disposition:                          contract defect / regression / adjacent / rebutted
Requires a stronger guarantee than the issue? yes / no
```

If the last answer is **yes**, implementation stops until the stronger guarantee is explicitly accepted into scope.

If two successive rounds increase implementation size or conceptual surface without changing the original acceptance evidence, default to reverting the reviewer-induced expansion and filing the stronger requirement separately.
