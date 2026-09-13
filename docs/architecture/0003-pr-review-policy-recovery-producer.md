# 0003: PR review policy recovery—nudge the canonical producer, do not become one

## Status

Accepted for [#931](https://github.com/nathanjohnpayne/mergepath/issues/931). Supersedes the design implemented in [#1240](https://github.com/nathanjohnpayne/mergepath/pull/1240), which is closed unmerged.

Recorded as an ADR rather than as a spec because its useful content is a rejection. `scripts/pr-review-policy-nudge.sh` needs almost no specification: it edits a PR body and publishes nothing. What a later reader needs is the reason it is that small, and the bill that comes with the obvious alternative. Without this record the next person to look at #931 reads its suggested fix, sees that the repository already solved the same problem three times with a scheduled sweep, and re-proposes the architecture that was measured and rejected here.

## Date

2026-09-13

## Context

`.github/workflows/pr-review-policy.yml` produces two branch-protection required contexts, `Self-Review Required` and `Label Gate`, and it triggers on `pull_request` only. Every sibling gate that produces a required context carries a second way in: `codex-p1-gate.yml` and `coderabbit-severity-gate.yml` have a `*/15` schedule, `merge-clearance-gate.yml` has a schedule and a `repository_dispatch`. This one does not, so a missed or dropped delivery leaves both contexts at "Expected—Waiting for status to be reported" with no path back. #931 was filed off an incident on `nathanjohnpayne/gaycruisebingo` where `pull_request` delivery ran 6-32 minutes behind and then self-resolved; had the event been dropped rather than delayed, three of the four gates would have recovered on their own and these two would not have.

The obvious fix is the sibling pattern, and it does not transfer.

## The constraint that rules out the sibling pattern

The siblings add a trigger to a workflow whose verdict comes from a script the new trigger can also run. `pr-review-policy.yml` has no such script: both verdicts are produced by inline steps of its jobs, one of them an `actions/github-script` block. Adding a `schedule` or `workflow_dispatch` entrance therefore means gating the three event-driven jobs to `pull_request`, and on a non-`pull_request` run those jobs are then *skipped*.

A skipped Actions job still materializes a check run under the job's `name`, and `skipped` satisfies a required check. This is observable on this repository's own default-branch tip: `ffe6c22` carries `skipped` check runs named `CodeRabbit unresolved blocking findings` and `Merge clearance gate`, both required contexts, left by scheduled runs of workflows whose jobs were gated off for that event.

A dispatch entrance on the gate workflow would therefore hand anyone who can dispatch it a way to place satisfying `skipped` runs for `Self-Review Required` and `Label Gate` on an arbitrary head. The recovery mechanism would be a bypass for the thing it recovers.

## Options considered

| | Option | Disposition |
| --- | --- | --- |
| A | Add `schedule` / `workflow_dispatch` to `pr-review-policy.yml` | Rejected: the skipped-job bypass above |
| B | An independent recovery producer that re-derives and publishes both contexts | Rejected: see below. Implemented and measured in #1240 |
| C | Fold both contexts into `required-check-publisher.yml` | Preferred end-state; already PR 5 of the #845 plan, blocked on the fleet wave tracked in [#979](https://github.com/nathanjohnpayne/mergepath/issues/979) |
| D | Make recovery cause the canonical producer to re-evaluate | **Adopted** |

## Why the independent producer was rejected

#1240 built option B: a scheduled workflow and a 652-line script that re-derive both verdicts and publish them under the same context names, standing down when the native producer returns.

It drew 29 findings across six review rounds. The finding count is weak evidence by itself, and a clean round would not have been evidence that the next one would also be clean. What settled the disposition was sorting the findings by kind: ordinary implementation bugs tapered as expected, but **every P1, in every round, was a newly-discovered obligation of the design** rather than a mistake in implementing it. The design was still generating requirements at round six.

The inventory below is that design's bill, preserved because it is the part a re-proposal will not anticipate. None of it exists for the event-driven producer, and none of it exists for option D.

**Ownership arbitration between two producers of one context.** Decided per `(head, context)` from the check runs on the head, with the two sides read asymmetrically: the native side by *presence* (any run that is not the stand-in's means the real producer is working), the stand-in's own side by *recency* (only to answer "have I already stood down?"). Reading the native side by recency instead leaves the stand-in's verdict overriding the real one whenever the ordering falls the other way. Reading the stand-in's own side by presence was the original defect: once it had published anything it answered "refresh" permanently, and every sweep overwrote a legitimately-cleared native green with its own stale red.

**Lineage retirement requires a publication.** Yielding silently is not enough, because GitHub requires the newest run of *each* lineage to be green. A recovery red left standing beside a later native green blocks exactly as hard as the original gap. A lineage can only be retired from inside, so the stand-in has to post one terminal `neutral` into its own with a distinct `external_id`.

**Three pre-write fences, and a window that cannot be closed.** Head equality; duplicate-head set membership, which must filter `commits/{sha}/pulls` on `.head.sha` because that endpoint also lists stacked PRs whose branch merely contains the commit; and a compare-and-swap on the check-run set the decision was taken over. Each needs a withhold-on-failed-read rule, and the gap between the last fence and the POST is a residual window with no conditional-write primitive to close it.

**Re-deriving the Phase 4 classification.** `needs-external-review` is applied by `pr-review-policy.yml`'s own `External Review Check` job, in the same workflow run as the two gates. In exactly the case recovery covers, the classifier never ran either, so an absent label is a symptom of the missed delivery rather than a clearance, and publishing a green `Label Gate` from it manufactures a Phase 4 bypass—total on consumers, where `codex.external_review_gate` keeps its documented default of disabled.

**A budget ceiling.** `GITHUB_TOKEN` is limited to 1,000 requests per hour per repository, shared with every other Actions caller there. A steady-state pass costs two reads per open PR; a pass that actually recovers one costs eleven reads and two writes plus the Phase 4 query's own surface. Somewhere north of roughly 120 open PRs a pass cannot complete, and the sweep degrades rather than failing loudly—which then needs a rotating start offset so the degradation is round-robin instead of silently starving the same tail every time.

Each of those is a guarantee the recovery lane would own permanently. The adopted option does not answer them better; it does not raise them.

## Decision

Recovery is an operator-invoked action that mutates the PR in a way the canonical workflow already listens for, so the trusted producer runs and reports its own verdicts. The mechanism publishes neither context.

`scripts/pr-review-policy-nudge.sh` edits the PR body, replacing a single inert provenance marker. `edited` is in the workflow's trigger list, so all three jobs re-run—including `External Review Check`, which is why the Phase 4 obligation above disappears rather than moving. A label toggle would not do: `labeled` and `unlabeled` are also in the trigger list, but the classifier job is explicitly gated off for those two actions, so a toggle recovers the two gates and leaves the classification unrecovered.

Five constraints bind the implementation, and `scripts/ci/check_pr_review_policy_nudge` pins the two of them that could be lost silently.

1. **It publishes nothing.** No check-run create, update, or conclusion, for either context. Its only output is one PR body edit. Pinned by the wrapper.
2. **Operator-invoked; no scheduled scanner.** If automatic recovery is justified later, it must be built as *detection plus a canonical nudge*, never detection plus independent verdict publication. A scheduled second producer re-acquires the whole inventory above.
3. **The marker is provenance, not an audit record.** One marker, replaced rather than appended, recording only the most recent nudge. Its timestamp is load-bearing rather than decorative: GitHub emits no `edited` event for an unchanged body, so a repeat inside the same second would report success having fired nothing. The script asserts the body actually changed instead of assuming it.
4. **Non-introduction, not validity.** The nudge must not introduce a body mutation that itself makes an otherwise valid PR fail Self-Review validation. This is deliberately narrower than "a nudge must never turn a pending context red": producing the honest verdict is the point, and a canonical red must remain reachable. So the check is a delta—whatever the original body passes, the nudged body must pass too—and an already-invalid body is still nudged, because reporting that failure is the producer's job and not the nudge's.
5. **Refuse on presence, not on success.** If both contexts already have check runs on the current head, the script declines. A red `Label Gate` is the canonical producer having run and having decided, which is the outcome the script exists to bring about. Consulting the conclusion instead would make this a generic "re-run my failing checks" button. There is no `--force` escape hatch; one gets added when a concrete operational case demands it, not before. The refusal matches check-run names against the workflow's job names, so the wrapper pins those two strings in lockstep—a rename would make the refusal silently vacuous and turn the script into the unconditional re-run button it must not be.

The script is hub-only. It takes `<PR#> [owner/repo]`, so one copy run from the hub recovers a stuck PR anywhere in the fleet, and the author credential it needs lives on the operator's machine rather than in any consumer checkout. Running it cross-repo is sound even though the body validator resolves the hub's own review policy: constraint 4 compares two exit statuses from the same validator, so a policy that is wrong for the target repo is wrong identically on both sides and the delta still holds.

## Consequences

Recovery is now a human action rather than an automatic one. That is a real reduction in coverage against the incident #931 describes: a PR whose delivery is dropped while nobody is looking stays stuck until somebody notices. The trade accepted here is that the automatic version costs the obligation inventory above, and an automatic mechanism that is subtly wrong about ownership is worse than a manual one that is right—the concrete failure #1240 shipped and then fixed was a sweep that overwrote a legitimately-cleared green with a stale red every fifteen minutes.

The mechanism carries no state, no schedule, no concurrency group, and no API budget worth modelling: at most five reads and one body edit per invocation, by a human. A run that nudges costs a PR read, a check-run listing, and a pre-write PR re-read; a run that refuses costs the first two plus a head re-read and a shared-head check.

It does carry one fence, and two checks that look like fences and are not. The distinction matters because the rejected design's fences are half the reason it was rejected. Those existed because it *published verdicts*: they arbitrated ownership between two producers of one context, over a check-run set, with a compare-and-swap and a residual write window that no available primitive could close. This one is an ordinary lost-update guard—the body write replaces the whole description, so it is re-read immediately beforehand and the run aborts if it moved. Every tool that rewrites a whole PR body needs that, verdicts or not, and it is one read and one comparison rather than a three-fence protocol. It aborts rather than rebuilding, because rebuilding would re-run the validators and reopen the same window one layer down.

The two that are not fences guard the *refusal*, not the write, and they fail in the opposite direction. Check runs attach to a commit rather than a PR, so two open PRs on one head share one set and the first PR's contexts would satisfy the second's presence test; and the presence answer is pinned to a SHA read before the listing, which a `synchronize` can supersede. Both would produce "nothing to recover" about a PR that has plenty to recover. So where the refusal cannot establish its own premise—the head moved, the head is shared, either answer is unreadable—it nudges and says why.

That direction is the whole difference. A fence withholds a publication because acting on a stale premise could be wrong. These release a nudge because *not* acting on an uncertain premise is what would be wrong: nudging a PR that did not need it costs one workflow run, and refusing one that did defeats the tool. Nothing here has to be right about ownership, because nothing here publishes a verdict.

It also narrows the window rather than closing it, and the record should say so plainly: GitHub exposes no conditional write for the pull-request update endpoint, so an edit landing between the re-read and the write is still lost. That is the same residual the rejected design documented for its own compare-and-swap—the floor for any whole-body write without conditional requests—and it is accepted here rather than solved. What the check buys is the large, self-inflicted part of the window: the four validator invocations and the check-run listing, leaving only the round trip.

Option A remains available to a future reader only if the skipped-job bypass is addressed first. Nothing in this change prevents someone adding `workflow_dispatch` to `pr-review-policy.yml`; this record is what should stop them.

## Deferred end-state

**Option C is the structural answer.** `required-check-publisher.yml` already walks every open PR once and publishes three contexts. Folding these two into it amortizes one listing across five contexts instead of standing up a second independent sweep, and it puts every required context behind a single publisher with one ownership model—which is the same reason the inventory above exists: a second ownership model is the expensive part, not a second sweep.

C is deferred, not rejected, and it is already the plan's own next-but-one step: extracting `Label Gate` and `Self-Review Required` into the publisher is **PR 5** of the #845 migration, marked optional there and explicitly sequenced after PR 4.

That sequence is blocked on propagation rather than on implementation. #979 measured it on 2026-08-13: `required-check-publisher.yml` present on the hub and absent from all nine consumers then surveyed, whose `merge-clearance-gate.yml` copies are byte-identical to one another—one frozen pre-#843 snapshot rather than a wave caught mid-flight. Flipping branch protection onto the publisher, or removing the native producers, would point required contexts at a producer nine repositories do not have; PR 4 in particular would leave a required context with no producer at all and no partial degradation to warn anyone. Consolidating #931's two contexts into a publisher in that state would couple this issue's fix to a fleet wave.

The nudge is compatible with C and is not a step away from it: it adds no producer for C to absorb, and when PR 5 lands the nudge is either still useful as a manual re-evaluation or deleted outright.
