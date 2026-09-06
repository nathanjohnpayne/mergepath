# Operating Rules for `priority:high` Work

High-priority work optimizes for closing the demonstrated problem, not for satisfying every observation an automated reviewer can derive from the changed code.

**Automated review is a defect detector, not a scope authority.**

## This is a design document, not a normative source

**Owner decision, 2026-09-06.** Read this before treating anything below as a rule you must follow.

> The mistake would be to turn the lesson into a new scope-discipline constitution sitting beside REVIEW_POLICY.md. That would reproduce a pattern Mergepath already struggles with: two documents describing overlapping behavior, followed by machinery to detect which one drifted.

So this document explains and does not mandate. It is the reasoning and the evidence; the obligations live at the control points below, and if this file and a control point ever disagree, **the control point wins and this file is out of date**. [REVIEW_POLICY.md](../../REVIEW_POLICY.md) and `.github/review-policy.yml` remain the sole authority for review behavior — identities, workflow, thresholds, tiers, disposition requirements, gates. Nothing here creates a required check, changes what a gate blocks on, or alters what disposition a finding needs.

### Where each rule actually lives

The governing principle is that these are **distinct decision rights with distinct actors**, and bundling them into one document merely because they were discovered together is itself the error:

> Don't bundle distinct decision rights into one mechanism merely because they were discovered together. Owner scope decisions, authoring requirements, and reviewer obligations have different actors and should live at their respective control points.

| Rule | Control point | Actor |
|---|---|---|
| **1** — contract ratified against the issue, with named guarantees and residual costs visible | PR authoring / open | **Owner** ratifies |
| **The checkpoint** — original ask, named additional guarantees, relevant failure costs | The PR template carries the artifact | Author reports |
| **3, 5** — mechanism lineage and scope delta reported whenever a finding would strengthen a guarantee; escalation offers fix / reduce-defer / remove / recut / accept residual | During implementation and escalation (#1201) | Author reports, owner decides |
| **2, 11** — what constitutes an in-contract blocking finding, and how adjacent findings are recorded | The review request machinery, or REVIEW_POLICY.md | Reviewer — *this is genuinely review behavior and belongs under the existing authority* |

PR authoring/open is where #1189 should have been stopped, and no amount of doctrine in a `docs/agents/` file would have stopped it.

**While that distribution is being built, this document is explanatory only.** Rules 3, 5 and 11 were earlier marked load-bearing here; they remain load-bearing as *decisions*, but the load is carried at the control points above, not by this file.

These rules are derived from a real failure. #1189 spent **twenty-one commits** and **twelve Codex review rounds** on a fix for #1188, plus three CodeRabbit rounds. Codex inline findings per round, in order, were **4, 1, 3, 1, 1, 6, 1, 2, 1, 2, 1, 3** — twenty-six findings that never trended toward zero. The point is not that the count rose; it is that it never fell. The largest round was the sixth, the final round still produced three findings, and there was no round after which the next one was reliably quieter. Under a fix-every-finding policy that series has no natural end, because roughly half of the later findings were interactions with rules added in the round before — including three regressions introduced in a single round.

Every reviewer was correct every time. The error was converting each correct finding into an obligation instead of asking whether the guarantee being defended was one the issue required. #1189 was eventually closed unmerged and replaced by #1196, a one-word change.

*(Counts are re-derivable: inline comments on #1189 authored by `chatgpt-codex-connector[bot]`, grouped by posting minute; commits from that PR's commit list.)*

### What happened to this document under review

Recorded because the document argues for measuring, and its own numbers were asserted before they were checked.

I told the owner across three separate reports that every review round had made this file *smaller*. That was false, and nobody measured it until the owner asked for it to be preserved on the record. Measured (`git show <sha>:<this file> | wc -w`):

| | words | delta |
|---|---|---|
| initial commit `2e480aa` | 1583 | — |
| after review round 1 `d696980` | 1835 | +252 |
| after review round 2 `ab04106` | 1948 | +113 |
| owner rule-5 change `9fd26ec` | 2285 | +337 |
| evidence re-measurement `7ca225e` | 2652 | +367 |
| after review round 3 `69de1f7` | 2878 | +226 |
| evidence correction `a4d6be2` | 3221 | +343 |
| owner rule-1 change `0a42275` | 3513 | +292 |
| framing correction `d4ef45c` | 3652 | +139 |

**The document grew 131%** — 160 to 268 lines, 1583 to 3652 words. It never shrank in any commit. The rule count stayed at twelve throughout. (The PR as a whole stands at +295/-2 across three files; the figures above are this file alone.)

The accurate word is **narrower, not smaller**. Every commit reduced what this document *claims the authority to do* — thresholds dropped from rule 5, a tier-mechanics paragraph removed rather than repaired a third time, review authority explicitly disclaimed, and finally the rules distributed to their control points so this file stopped being normative at all. Authority contracted monotonically while length grew monotonically. "We narrowed it" and "we made it smaller" are different statements, and only the first is true.

There were **three** automated review rounds on this PR, not four — three Codex review submissions, at 05:17, 05:29 and 05:50 UTC. That count was also misreported before it was checked.

The attribution is worth more than the total. **The three review rounds account for +591 words. Owner decisions and evidence corrections account for +1478** — two and a half times as much. Automated review was not the main source of growth in a document about automated review causing growth; the main source was correcting claims this document had made about itself, and absorbing decisions that changed what it is for.

That is the fourth unmeasured claim caught in this file, and the fifth counting the round count. The first three were caught by a reviewer or a peer. This one was caught only because the owner asked for it to be preserved in writing — which is the general case worth noting: **a claim becomes checkable at the moment someone asks to record it**, and every one of these survived unchecked precisely as long as it was only being asserted.

Enforcement is tracked in #1199 (rules 2 and 11, at the review-request machinery) and #1201 (rules 3 and 5, at the escalation surface). Rule 5 is load-bearing *without* being automatable, and #1199 records why the mechanical version of it was withdrawn.

## 1. Get the contract ratified, not merely frozen

Before opening a PR, write a short implementation contract containing:

- **Problem being fixed** — the observed failure or measured cost that makes the issue high priority.
- **Guarantees this implementation will provide** — named, one line each, each marked as either *asked for by the issue* or *added by this implementation*. Anchor the list to the guarantees the **issue** states, not to the ones the implementation finds natural; a broadly-scoped issue legitimately asks for many, and measuring against the implementation's own ambition makes any PR look restrained.
- **Required outcome** — the smallest externally observable behavior that must change.
- **Invariants that must remain true** — existing safety properties the fix may not weaken.
- **Explicit non-goals** — adjacent guarantees this PR does not attempt to provide.
- **Acceptance evidence** — the tests, reproduction, measurement, or canary that proves the required outcome.
- **Stop condition** — what constitutes enough evidence to merge.

**Freezing it is not enough. Somebody with authority has to agree to it before expensive review begins.**

> Given the issue's problem statement, are these the guarantees we actually intend to buy?

That is the control, and it is a decision right rather than better agent documentation. #1189 is the proof that the weaker version fails: `af513e9`'s commit header already explained and froze the choice to publish a `failure` conclusion and build a path back to green, in preference to publishing `neutral`. The contract was coherent, written down, and adhered to. It was also unnecessary — #1188 had named the one-word option as the cheapest — and **nobody with authority was asked to agree with it before round one**. Twelve review rounds then argued about how to implement it correctly, which was never the question.

An agent can explain and freeze a coherent but unnecessary contract. Explanation is not ratification, and a contract the author wrote and the author approved is not a control on the author.

Ratification is cheap and belongs before the expensive part: it costs one exchange at PR open, against the twelve rounds #1189 spent defending a guarantee nobody had agreed to buy. Once ratified, automated review may identify defects in satisfying that contract. It may not silently enlarge it, and neither may the author.

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

**Deferral is available at discretionary tier only, and which tiers those are is a configuration question.** Resolve the required set from `feedback_policy` in the governing `.github/review-policy.yml` — it is per-repo, and `mode: address-all` or a per-tier override can make any tier required. Do not assume the default map. REVIEW_POLICY.md § Feedback Disposition Policy is the authority for what a disposition is; this document does not restate it.

What this rule adds is only the consequence for classification B:

- **A finding in a discretionary tier** may be deferred to a follow-up. Ordinary path, nobody's permission needed.
- **A finding in a required tier may not be self-deferred.** Either it is genuinely inapplicable under the frozen contract, in which case **rebut** it and say why — a rebuttal is a substantive disposition, not a dodge — or it is applicable and valid, in which case it is a **scope decision and rule 3 applies**: stop and obtain an explicit owner decision. Do not route around a valid required-tier finding by filing an issue and calling it handled.

That boundary is the whole safeguard. Without it, "valid but adjacent" becomes a way for an agent to unilaterally downgrade any blocking finding it would rather not fix — this document's own failure mode, run in reverse.

### C. Rebutted

Record why the finding does not apply, is unreachable under the contract, mistakes a deliberate tradeoff for a defect, or asks for a guarantee explicitly listed as a non-goal.

A rebutted finding does not become required because another reviewer repeats it.

## 3. No new guarantee without an explicit scope decision

**Load-bearing.** If satisfying a finding requires adding words such as "always", "under arbitrary concurrency", "for every caller", "even if configuration is malformed", "across all interleavings", "atomically", "prove", "canonical", "authoritative", "fully close", or "prevent all" — stop.

Those phrases usually indicate that a local fix is being converted into a stronger system contract. Do not implement that stronger contract unless it was already part of the issue. File it separately, or obtain an explicit owner decision to expand scope.

The trigger is the finding's *disposition*, not the vocabulary of the codebase. Several of these words are ordinary technical vocabulary here — "canonical" describes propagation paths in dozens of files — so the rule fires when a finding using one is dispositioned **Required**, not whenever the word appears.

## 4. Prefer a bounded residual risk to an unbounded mechanism

A known residual failure mode is acceptable when all of these hold:

1. **it pre-dates this patch** — it is a pre-existing condition, not something this change introduced;
2. it is outside the issue's required contract;
3. its failure direction is understood;
4. it does not make the original defect worse;
5. it is documented **with its cost stated in product terms** — what a user or operator experiences if it fires, not what the code does;
6. it can be tracked separately if worth fixing.

Condition 1 is not optional and is the one that keeps this rule from contradicting rule 2A. A regression *introduced by this patch* satisfies every other condition on the list — understood polarity, does not worsen the original defect, documentable, trackable — and rule 2A requires it to be fixed. Without condition 1 the two rules hand an agent opposite dispositions for the same finding, and the agent gets to pick.

Do not build serialization, state machines, watermarks, epochs, reconciliation protocols, generalized parsers, or new policy layers merely to eliminate a residual outside the contract.

#1189 is the canonical warning: attempts to establish stronger cross-invocation ordering generated new interactions faster than review eliminated them. Five successive mechanisms were built and removed — an evaluation-epoch marker, a clean-verdict watermark, a read-after-write reconciliation for the burial race that watermark created, evaluation-order arbitration, and a per-stage re-stamp. The correct move was to reduce the guarantee and separate the stronger concurrency problem into #1191.

## 5. Before repairing machinery, ask whether the machinery belongs

**Load-bearing.**

> When a finding requires additional machinery, ask first whether the machinery being repaired is necessary to satisfy the original contract. If not, remove or defer the machinery instead of repairing it.

That is the whole rule. The question is *what can we delete or defer while still satisfying the original issue?* — never *what additional guard makes this latest finding impossible?*

**Anchor "the original contract" to the issue's problem statement, not to the contract this PR chose.** Rule 1 has you get a contract ratified before implementing, and that contract is what review is judged against — but it is not what *this* question is judged against, because even a ratified contract can drift, and an unratified one is exactly the thing that can be too big. Read literally against the PR's own contract, #1189's clearing arm is "necessary" by construction: the PR had decided to build a clearing arm, so every piece of ordering machinery under it was load-bearing. Measured against #1188's problem statement — which listed publishing a non-blocking conclusion as the cheapest option — none of it was. Ask the question against the issue and the answer inverts.

It is deliberately not a threshold. An earlier draft of this rule carried two: remove the machinery after **two consecutive findings in reviewer-induced code**, and force a scope review after **three substantive rounds without decreasing scope**. Both were dropped by owner decision on 2026-09-06, and the reason matters more than the rules did.

**The reason is not that the counts are noisy.** It is that a count can be satisfied without anyone thinking. #1112 is the demonstration: seventeen of its author's replies quote round or finding counts, and not one names a mechanism — while the three heavily-reviewed PRs that merged quote counts once, once and never, and instead record things like "fifth instance of one root cause" and "sixth way". Count-shaped instrumentation was available on #1112 throughout and was routed around by the framing. A threshold is more count-shaped instrumentation.

**The measurements do not rescue the thresholds, and they do not condemn them either.** Reflexive findings — where the defect is in code that did not exist at PR open and was added to satisfy an earlier finding in the same PR — run 20% on #1176, 18% on #1084 and 33% on #1139 (all merged), against 22% on #1189 and 37% on #1112 (both closed unmerged). The ranges overlap, so reflexive share does not separate the healthy case from the failing one, and a threshold keyed on it is not the discriminator it was assumed to be.

But it would be dishonest to claim more than that. The same data shows the two-consecutive-findings rule would have **fired usefully** on #1139 — at round 6, seven rounds before the author split the guard out at round 13 — and on #1176 the author acted at the fourth instance anyway. The threshold was dropped because it can be satisfied mechanically, not because it was shown to misfire.

*(Single rater, counts ±2, from the API; the reflexive definition above is the one counted, and it is narrower than a reviewer's own "fresh evidence beyond the resolved…" phrasing, which also appears on genuinely new findings. **No second rater is scheduled**, so these figures stay provisional unless one is commissioned — #1199 holds the standing obligation.)*

**Round counting fails on its own evidence.** By Codex review-submission count: #1176 merged at 11 rounds and ~30 findings, #1084 at 19 and ~66, #1139 at 11 and ~21 — while #1189 died at 12 and ~27 and #1112 at 19 and ~51. Merged and closed PRs occupy the same ranges on both axes. Volume does not separate them, so a rule keyed on volume cannot either.

**Neither does in-contract share**, which is worth stating because it is the intuitive candidate and it is wrong: findings that were inside the PR's contract run 67% on #1176, 44% on #1084 and 10% on #1139 (merged) against 59% on #1189 and 8% on #1112 (closed). Fully overlapping.

**What does separate them, in that classification, is two things — and both are rule 5.**

*How many stronger-guarantee findings were accepted into scope.* The merged PRs implemented one, one and three; #1189 implemented five and #1112 about ten. The quality of them differs as much as the count: #1084's three are input edge cases (a symlink path, a dot-prefixed repo name, a file cap), while #1189's five are ordering mechanisms. Accepting a handful of bounded edge cases is not the same act as accepting five new invariants.

*Whether the author deleted a mechanism in-PR.* All three merged PRs did, and each converged at that point: #1176 at round 6 (`08bea90`, "removing the thing that produced this finding rather than patching it a fourth time"), #1139 at round 13 (`0df6c7f`), #1084 at round 14 (`3cf8e80` / `c60a1d7`, "deleting the mechanism that caused them"). #1112 never deleted anything and grew 61× — the only PR in the fleet at that ratio, against a 14× maximum among merged PRs with eight or more rounds.

**Removal is not sufficient on its own, which is the anchor point again.** #1189 removed twice (`aae979e`, `74acba0`) and still failed, because it removed reviewer-induced machinery while keeping the design that made the machinery necessary. Its growth from open to close was 4.3×, unremarkable for this fleet; the scope problem was *issue-to-open* — 275 lines in the first commit, before any review, for a problem whose issue named a one-word option. Deleting the right thing requires asking the question against the issue.

That question has no reliable mechanical form. It needs someone to look at the machinery and say whether the issue asked for it, which is exactly the point: this rule marks the place where product judgment has to re-enter the loop, and it should not be automated into something that feels answered without anyone having thought.

A note on how these numbers got here, because it bears on how much weight to put on them. Two earlier drafts of this section argued from figures that did not survive checking — first a reflexive rate of about 40%, then a claim that the failed PR's rate sat below every healthy one. Both were corrected by re-measurement, in a document whose thesis is that you should measure before accepting an obligation. Treat the surviving numbers as single-rater and provisional, and prefer the argument that does not depend on them: a count can be satisfied without anyone thinking.

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

## The scope checkpoint

The artifact belongs in the **PR template**, not in a separate doctrine — the template is the control point, and a checkpoint nobody is prompted for is a checkpoint nobody files. For every `priority:high` PR, after each substantive automated-review round, the author records — in the PR, where the owner and the other reviewers can see it:

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
