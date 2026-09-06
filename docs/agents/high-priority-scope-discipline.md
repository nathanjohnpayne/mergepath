# Operating Rules for `priority:high` Work

High-priority work optimizes for closing the demonstrated problem, not for satisfying every observation an automated reviewer can derive from the changed code.

**Automated review is a defect detector, not a scope authority.**

**This document explains; it does not mandate.** [REVIEW_POLICY.md](../../REVIEW_POLICY.md) and `.github/review-policy.yml` remain the sole authority for review behavior — identities, workflow, thresholds, tiers, disposition requirements, gates. Nothing here creates a required check, changes what a gate blocks on, or alters what disposition a finding needs, and where this file disagrees with the governing policy or with an enforcement control point, they win and this file is out of date. These rules are owner decision rights and author reporting obligations rather than review mechanics, and the control points intended to carry them are tracked, not built: contract ratification at PR open (#1202), mechanism lineage and the escalation menu during implementation (#1201), and reviewer-facing obligations at the review-request machinery (#1199). None of those exists yet; until one does, these rules bind nothing on their own.

The rules come from #1189, which spent twenty-one commits and twelve Codex review rounds implementing a contract nobody had agreed to buy, was closed unmerged, and was replaced by #1196 — a one-word change. Every reviewer was correct every time. The error was converting each correct finding into an obligation instead of asking whether the guarantee being defended was one the issue required.

## 1. Get the contract ratified, not merely frozen

Before opening a PR, write a short implementation contract containing:

- **Problem being fixed** — the observed failure or measured cost that makes the issue high priority.
- **Guarantees this implementation will provide** — named, one line each, each marked *asked for by the issue* or *added by this implementation*. Anchor the list to what the **issue** states, not to what the implementation finds natural; measuring against your own ambition makes any PR look restrained.
- **Required outcome** — the smallest externally observable behavior that must change.
- **Invariants that must remain true** — existing safety properties the fix may not weaken.
- **Explicit non-goals** — adjacent guarantees this PR does not attempt to provide.
- **Acceptance evidence** — the tests, reproduction, measurement, or canary that proves the required outcome.
- **Stop condition** — what constitutes enough evidence to merge.

**Freezing it is not enough. Somebody with authority has to agree to it before expensive review begins.**

> Given the issue's problem statement, are these the guarantees we actually intend to buy?

An agent can explain and freeze a coherent but unnecessary contract — #1189 did, in its first commit header, and was never asked whether that was the contract to buy. Explanation is not ratification, and a contract the author wrote and the author approved is not a control on the author. Ratification costs one exchange at PR open. Once ratified, review may identify defects in satisfying the contract; it may not silently enlarge it, and neither may the author.

## 2. Classify every review finding before changing code

Every automated-review finding receives exactly one disposition.

### A. Required — fix in this PR

Fix when the finding demonstrates that the current patch:

- does not satisfy an acceptance criterion;
- violates an invariant explicitly preserved by the issue;
- introduces a regression reachable because of this patch;
- creates a security or correctness failure on the changed execution path; or
- makes the proposed implementation internally inconsistent.

The burden is on the finding to connect itself to the ratified contract.

### B. Valid but adjacent — file, fold into follow-up, or accept as a residual

The finding may be correct, but fixing it would require:

- a stronger guarantee than the issue requires;
- support for an additional state, caller, configuration, concurrency model, or recovery path;
- a new abstraction or generalized framework;
- changes to unrelated existing behavior;
- hardening against a pre-existing condition not made worse by this PR; or
- materially new acceptance criteria.

Record it separately. Do not implement it merely because it was discovered during review. Accepting it as a known residual is also this disposition, and requires rule 4's conditions to hold.

**Which findings may be deferred is a policy question** — answered by `feedback_policy` in the governing `.github/review-policy.yml` and by REVIEW_POLICY.md § Feedback Disposition Policy, not restated here. What this rule adds is the consequence: where deferral is not permitted, a valid finding you do not intend to fix is a **scope decision**, and rule 3 applies. Rebut it as inapplicable, or obtain an owner decision. Do not route around it by filing an issue and calling it handled — otherwise "valid but adjacent" becomes a way to unilaterally downgrade any blocking finding, which is this document's own failure mode run in reverse.

### C. Rebutted

Record why the finding does not apply, is unreachable under the contract, mistakes a deliberate tradeoff for a defect, or asks for a guarantee explicitly listed as a non-goal. A rebutted finding does not become required because another reviewer repeats it.

## 3. No new guarantee without an explicit scope decision

If satisfying a finding requires adding words such as "always", "under arbitrary concurrency", "for every caller", "even if configuration is malformed", "across all interleavings", "atomically", "prove", "canonical", "authoritative", "fully close", or "prevent all" — stop. Those phrases usually mean a local fix is being converted into a stronger system contract. Do not implement that contract unless it was already part of the issue: file it separately, or obtain an explicit owner decision to expand scope.

The trigger is the finding's *disposition*, not the vocabulary of the codebase. Several of these words are ordinary technical vocabulary here — "canonical" describes propagation paths in dozens of files — so the rule fires when a finding using one is dispositioned **Required**, not whenever the word appears.

## 4. Prefer a bounded residual risk to an unbounded mechanism

A known residual failure mode is acceptable when all of these hold:

1. **it pre-dates this patch** — a pre-existing condition, not something this change introduced;
2. it is outside the issue's required contract;
3. its failure direction is understood;
4. it does not make the original defect worse;
5. it is documented **with its cost stated in product terms** — what a user or operator experiences if it fires, not what the code does;
6. it can be tracked separately if worth fixing.

Condition 1 is what keeps this rule from contradicting rule 2A: a regression introduced by this patch satisfies every other condition on the list, and rule 2A requires it fixed.

Do not build serialization, state machines, watermarks, epochs, reconciliation protocols, generalized parsers, or new policy layers merely to eliminate a residual outside the contract. #1189 is the warning — five successive ordering mechanisms were built and then removed, each closing one interleaving and opening another, when the correct move was to reduce the guarantee and separate the stronger problem into #1191.

## 5. Before repairing machinery, ask whether the machinery belongs

> When a finding requires additional machinery, ask first whether the machinery being repaired is necessary to satisfy the original contract. If not, remove or defer the machinery instead of repairing it.

The question is *what can we delete or defer while still satisfying the original issue?* — never *what additional guard makes this latest finding impossible?*

**Anchor "the original contract" to the issue's problem statement, not to the contract this PR chose.** If read against the PR's own contract, #1189's clearing arm is necessary by construction: the PR had decided to build one, so every piece of ordering machinery beneath it was load-bearing. Measured against #1188, which named a one-word option as the cheapest, none of it was.

The rule deliberately carries no threshold. Earlier drafts triggered on two consecutive findings in reviewer-induced code, or on three rounds without scope contraction; both were dropped because a count can be satisfied without anyone thinking. The question needs someone to look at the machinery and say whether the issue asked for it — this is where product judgment has to re-enter the loop, and it should not be automated into something that feels answered without anyone having thought.

## 6. Review does not get to generalize a local requirement

A fix for one concrete failure does not automatically need to become a reusable framework, a canonical parser, a fleet-wide abstraction, a generalized provenance system, a complete concurrency protocol, a new policy primitive, or protection against every theoretically related malformed state. Generalization requires independent evidence that the broader problem is worth solving now.

#1112 is the warning: recording the bootstrap source SHA did not require proving a broad canonical-source provenance contract. Once review began asking which sources were trustworthy, the PR stopped being attribution and became source validation.

## 7. Preserve failure polarity; do not demand completeness

For merge-safety work, distinguish:

- **unsafe false green** — generally must block;
- **safe false red** — may be acceptable residual friction;
- **availability failure** — fix when it is part of the issue's measured problem;
- **missing theoretical guarantee** — not automatically a defect.

Do not turn every safe false-red possibility into additional synchronization machinery for conceptual completeness. Likewise, do not accept a false green merely to reduce friction.

## 8. Test the contract, not the review history

Regression tests should prove that the original reproduction fails before the fix and passes after it, that explicit invariants remain intact, that boundary cases required by the contract work, and that the test is non-vacuous where appropriate.

Do not automatically add a permanent test for every speculative shape raised during review. If a test exists only because a reviewer invented an out-of-scope guarantee, the test itself is scope creep.

## 9. Keep the PR smaller than the issue

A high-priority issue may describe a large operational problem. Its first PR does not need to solve the entire subsystem. Prefer the smallest independently useful tranche that changes the measured failure, can be verified, and does not foreclose the rest of the issue.

For staged issues such as #937, a successful stage is a deliverable, and a failed canary can be a successful diagnostic outcome when the issue defines it that way.

## 10. Follow-up issues are a convergence mechanism

Filing a valid finding separately is not unfinished work. It is the preferred response when the finding would increase the current PR's contract.

A follow-up should state the newly discovered condition, whether it is reachable today, the failure direction, the evidence, why it is outside the current PR, and whether it changes the current PR's safety. Do not inherit the parent issue's `priority:high` automatically.

## 11. Re-review the same contract, not the enlarged implementation

Every review request after the first should tell reviewers:

> Review this PR against the stated contract and non-goals. Report defects that prevent the patch from satisfying that contract, or regressions introduced by the patch. Do not require stronger guarantees, generalized handling, or adjacent hardening as conditions of merge; identify those separately as follow-up findings.

If scope has deliberately changed, update the contract before requesting another review. Reviewers should never infer new scope from machinery a previous reviewer caused to be added.

## 12. Stop when the issue is proved

Merge when the ratified required outcome is satisfied, explicit invariants hold, required-tier findings against that contract are resolved or rebutted, acceptance evidence passes, and remaining findings are documented follow-ups or accepted residuals.

**This rule governs which findings you owe a fix, never which gates you owe a pass.** Stopping here means stopping the *addition of scope*. When a head is clear enough to merge is REVIEW_POLICY.md's question, and this document does not answer it.

Do not continue reviewing merely because another review might find something. The objective is risk reduction per unit time, not exhaustion of the possible finding space.

## The scope checkpoint

The artifact belongs in the PR template (#1202) — a checkpoint nobody is prompted for is a checkpoint nobody files. For every `priority:high` PR, after each substantive automated-review round, the author records, in the PR:

```
Contract changed?                            yes / no
Production code added because of this review: +N / -N lines
New concepts introduced:                      none / list
Finding disposition:                          contract defect / regression / adjacent / rebutted
Is the machinery this finding repairs
  required by the original contract?          yes / no / no machinery involved
Requires a stronger guarantee than the issue? yes / no
```

The machinery question is rule 5 in checkpoint form and is the one that most often changes the outcome. Answer it about the code the finding is *about*, not about the fix being proposed — a **no** means remove or defer that code, not repair it. If the last answer is **yes**, implementation stops until the stronger guarantee is explicitly accepted into scope.
