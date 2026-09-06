# Operating Rules for `priority:high` Work

High-priority work optimizes for closing the demonstrated problem, not for satisfying every observation an automated reviewer can derive from the changed code.

**Automated review is a defect detector, not a scope authority.**

These rules are derived from a real failure. #1189 spent **twenty-one commits** and **twelve Codex review rounds** on a fix for #1188, plus three CodeRabbit rounds. Codex inline findings per round, in order, were **4, 1, 3, 1, 1, 6, 1, 2, 1, 2, 1, 3** — twenty-six findings that never trended toward zero. The point is not that the count rose; it is that it never fell. The largest round was the sixth, the final round still produced three findings, and there was no round after which the next one was reliably quieter. Under a fix-every-finding policy that series has no natural end, because roughly half of the later findings were interactions with rules added in the round before — including three regressions introduced in a single round.

Every reviewer was correct every time. The error was converting each correct finding into an obligation instead of asking whether the guarantee being defended was one the issue required. #1189 was eventually closed unmerged and replaced by #1196, a one-word change.

*(Counts are re-derivable: inline comments on #1189 authored by `chatgpt-codex-connector[bot]`, grouped by posting minute; commits from that PR's commit list.)*

Three rules here are load-bearing rather than advisory: **rule 3**, **rule 5**, and **rule 11**. Enforcement is tracked in #1199 — but rule 5 is load-bearing *without* being automatable, and #1199 records why the mechanical version of it was withdrawn.

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

**Deferral is available at discretionary tier only.** REVIEW_POLICY.md § Feedback Disposition Policy is explicit: a disposition is a fix, a rebuttal, or — *for a discretionary-tier finding only* — a deferral reply linking a follow-up issue. **A required-tier (P0/P1) finding must be fixed or rebutted.** The one exception is the summary-only ack path, for findings that have no review thread.

So this classification resolves differently by tier:

- **Discretionary (P2/P3/nitpick).** File the follow-up, post the deferral reply linking it, resolve the thread. This is the ordinary path and needs nobody's permission.
- **Required (P0/P1).** You may not self-defer. Either the finding is genuinely inapplicable under the frozen contract, in which case **rebut** it and say why — a rebuttal is a substantive disposition, not a dodge — or it is applicable and valid, in which case it is a **scope decision, and rule 3 applies**: stop and obtain an explicit owner decision. Do not route around a valid required-tier finding by filing an issue and calling it handled.

That boundary is the whole safeguard. Without it, "valid but adjacent" becomes a way for an agent to unilaterally downgrade any blocking finding it would rather not fix — which is the failure this document exists to prevent, run in the opposite direction.

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

## 5. Before repairing machinery, ask whether the machinery belongs

**Load-bearing.**

> When a finding requires additional machinery, ask first whether the machinery being repaired is necessary to satisfy the original contract. If not, remove or defer the machinery instead of repairing it.

That is the whole rule. The question is *what can we delete or defer while still satisfying the original issue?* — never *what additional guard makes this latest finding impossible?*

**Anchor "the original contract" to the issue's problem statement, not to the contract this PR chose.** Rule 1 has you freeze a contract before implementing, and that frozen contract is what review is judged against — but it is not what *this* question is judged against, because the PR's contract is itself the thing that can be too big. Read literally against the PR's own contract, #1189's clearing arm is "necessary" by construction: the PR had decided to build a clearing arm, so every piece of ordering machinery under it was load-bearing. Measured against #1188's problem statement — which listed publishing a non-blocking conclusion as the cheapest option — none of it was. Ask the question against the issue and the answer inverts.

It is deliberately not a threshold. An earlier draft of this rule carried two: remove the machinery after **two consecutive findings in reviewer-induced code**, and force a scope review after **three substantive rounds without decreasing scope**. Both were dropped by owner decision on 2026-09-06, and the reason matters more than the rules did.

Reflexive findings — a reviewer finding a defect in the fix for its own previous finding — are an ordinary background rate on PRs that merge perfectly well, not a distress signal. A hand classification of five PRs against this document's rule-2 taxonomy puts them at roughly 20% of findings on #1176 and 33% on #1139, both merged — and at **15% on #1189, which did not**. The failed PR had a *lower* reflexive rate than the healthy ones. So "two in a row" does not merely fire too often on good PRs; as a distress signal it points the wrong way. A threshold that trips on the normal case and stays quiet on the failing one is worse than no threshold at all.

(Single-rater classification, counts ±2, reported by a sibling session; the direction of the comparison is what matters here and it should be confirmed by a second rater before anything mechanical keys on the rates themselves — see #1199.)

Round counting fails for a related reason, now measured rather than assumed: #1176 merged at 11 rounds and 26 findings, #1179 at 8 and 13, #1139 at 11 and 19. #1189 died at 12 rounds and 26 findings. Volume does not separate the healthy case from the failing one, so a rule keyed on volume cannot either.

What separates them is **disposition** — whether the code a finding is about was ever required — and there is direct evidence for the rule in the same classification. Every one of the three heavily-reviewed PRs that merged converged at the point its author *deleted a mechanism* rather than patching it again: #1176 at round 6 (`08bea90`, recorded in the commit as "removing the thing that produced this finding rather than patching it a fourth time"), #1139 at round 13 (`0df6c7f`), #1084 at round 14 (`3cf8e80` / `c60a1d7`, "deleting the mechanism that caused them"). #1112 never removed anything and grew 61× — the only PR in the fleet at that ratio; the largest among merged PRs with eight or more rounds is 14×.

**Removal is not sufficient on its own, which is the anchor point again.** #1189 removed twice (`aae979e`, `74acba0`) and still failed, because it removed reviewer-induced machinery while keeping the design that made the machinery necessary. Its growth from open to close was 4.3×, unremarkable for this fleet; the scope problem was *issue-to-open* — 275 lines in the first commit, before any review, for a problem whose issue named a one-word option. Deleting the right thing requires asking the question against the issue.

That question has no reliable mechanical form. It needs someone to look at the machinery and say whether the issue asked for it, which is exactly the point: this rule marks the place where product judgment has to re-enter the loop, and it should not be automated into something that feels answered without anyone having thought.

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

**This rule governs which findings you owe a fix, never which gates you owe a pass.** It grants no exemption from the standard merge path: a fix push still requires a fresh review invocation and HEAD-anchored clearance on the *current* head, exactly as REVIEW_POLICY.md Phase 4 specifies. A verdict on superseded code satisfies nothing. Rule 12 says stop *adding scope*; the gates decide when the head is clear.

Do not continue reviewing merely because another review might find something. The objective for `priority:high` work is risk reduction per unit time, not exhaustion of the possible finding space.

## Mandatory scope checkpoint

For every `priority:high` PR, after each substantive automated-review round, record:

```
Contract changed?                            yes / no
Production code added because of this review: +N / -N lines
New concepts introduced:                      none / list
Finding disposition:                          contract defect / regression / adjacent / rebutted
Is the machinery this finding repairs
  required by the original contract?          yes / no / no machinery involved
Requires a stronger guarantee than the issue? yes / no
```

The machinery question is rule 5 in checkpoint form, and it is the one that most often changes the outcome. Answer it about the code the finding is *about*, not about the fix being proposed — a **no** means remove or defer that code, not repair it.

If the last answer is **yes**, implementation stops until the stronger guarantee is explicitly accepted into scope.

If two successive rounds increase implementation size or conceptual surface without changing the original acceptance evidence, default to reverting the reviewer-induced expansion and filing the stronger requirement separately.
