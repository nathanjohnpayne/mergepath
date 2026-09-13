---
spec_id: pr_review_policy_recovery
---

# PR Review Policy Recovery Lane

`.github/workflows/pr-review-policy-recovery.yml` and `scripts/pr-review-policy-recovery.sh` are a **stand-in producer** for the two required contexts `.github/workflows/pr-review-policy.yml` reports — `Self-Review Required` and `Label Gate`. They exist because those two contexts had exactly one producer path, the `pull_request` event, while every sibling required context already carried a second way in. A delivery that never arrived left only these two at *"Expected — Waiting for status to be reported"*: branch protection blocks, no event can re-fire them, and there is no manual re-run path (#931).

This spec states the lane's behavioral contract. One source of truth: a change to its behavior belongs in this file, in `scripts/ci/check_pr_review_policy_recovery`, and in `tests/test_pr_review_policy_recovery.sh`, in the same diff.

## The guarantee

For every open PR, both contexts are re-derived from live PR state and reported on the PR head within 15 minutes of a missed delivery, and an operator can force that re-derivation immediately with a `repository_dispatch` of type `pr-review-policy-recheck`.

The interval is part of the guarantee, not an implementation detail, and the fence asserts it as a **property** rather than as the presence of a cron: the union of the schedule's unrestricted entries must select minutes no more than 15 apart, wrap included. `*/15 * * * *` and `0,15,30,45 * * * *` are equally acceptable; `0 3 * * *` is not, and neither is a cron the checker cannot evaluate.

## Ownership: stand-in, never owner

The event-driven producer always wins. The lane's job is to cover for it while it is absent and to get out of its way cleanly when it returns. Ownership is decided per `(head, context)` from the check runs on that head, and the two sides of the decision are read differently because they answer different questions.

| state of the check runs | decision | what the lane does |
|---|---|---|
| none | `absent` | publish the recovered verdict |
| only this lane's | `refresh` | re-derive and publish, keeping the verdict current |
| any native run present, and this lane's newest run is a verdict | `standdown` | publish one `neutral` run stamped with the retirement id, and stop |
| any native run present, and this lane's newest run is the retirement | `skip` | nothing |
| any native run present, and this lane has never published | `skip` | nothing |

**The native side is presence.** Any run on the head that carries neither of this lane's two `external_id` stamps means the real producer is working. There is no comparison against it in either direction. A rule of the form *"yield only when the native run is newer than mine"* leaves the lane's verdict overriding the real one whenever the ordering falls the other way, which is the same defect one step later.

**This lane's own side is recency**, and only to answer *"have I already stood down?"*. Check runs are append-only and their ids increase monotonically, so the retirement is in force exactly while it is the highest-numbered run this lane owns. Without that, the sweep would post a fresh `neutral` every interval forever.

Deciding the native side by presence of a *recovery* run was the original defect (#1240 Codex round 4): once the lane had published anything, it answered `refresh` permanently. The live consequence was concrete — `auto-clear-blocking-labels.yml` validly removes `needs-external-review`, the `unlabeled` event publishes a native green `Label Gate`, and the next sweep overwrote it with the lane's own stale red, every 15 minutes, wedging a PR that had been legitimately cleared.

### Why standing down needs a publication

Yielding silently is not enough. GitHub requires the newest run of **each** lineage to be green — measured on #828 and #835, and the cause of the strand on #1216 — so a recovery red left standing beside a later native green blocks exactly as hard as the original gap. A lineage can only be retired from inside, so the lane posts one run into its own with a `neutral` conclusion, which branch protection already treats as satisfied. The distinct `external_id` is what makes that terminal.

## Verdicts

Neither verdict is re-implemented. `Self-Review Required` routes through `scripts/validate-pr-body.sh --self-review-only`, the same entrypoint the event-driven job pipes the body into, with the body on stdin and never in argv; Dependabot's exemption is reproduced by publishing `skipped`. `Label Gate` uses `mergepath_blocking_labels_csv` from `scripts/lib/blocking-labels.sh`.

**A green `Label Gate` additionally requires the Phase 4 classification to be re-derived.** `needs-external-review` is applied by `pr-review-policy.yml`'s own `External Review Check` job, in the same workflow run as the two gates, so in exactly the case this lane covers, the classifier never ran either. An absent label is then a symptom of the missing delivery, not a clearance, and publishing green from it manufactures a Phase 4 bypass — total on consumers, where `codex.external_review_gate` keeps its documented default of disabled. The lane therefore asks `scripts/merge-clearance-gate.sh --derive-phase-4-requiredness`, which owns that calculation over the policy resolved from the PR's base commit. `true` with no blocking label publishes red; a non-boolean answer or a nonzero exit publishes red and reddens the sweep.

## Fences

Both verdict inputs — the body and the label list — are read immediately before the verdict that consumes them. The author is the only input read up front, because it is the only one that cannot change. Three fences then run immediately before every write:

1. **Head.** The head must still be the PR's head; verdicts are derived from live state and must not be pinned to a superseded SHA.
2. **Set membership.** The PR must still be the sole open PR carrying that head, or still not be — whichever the decision was taken under. A reopen or a force-push onto another open PR's head invalidates the duplicate-head set mid-sweep, and the head itself does not move when that happens.
3. **Compare-and-swap.** The check runs for that `(head, context)` must be exactly the set the decision was taken over.

A failed read at any fence withholds: unknown state is possibly-newer state. Overlapping passes are additionally serialized by the workflow's `concurrency` group. The residual window is the gap between the last fence and the POST, which is the floor without conditional writes.

A head carried by more than one open PR is published **red** on both contexts and evaluated for neither. One commit slot cannot honestly carry two PRs' verdicts, and red-until-disambiguated is the only verdict that cannot be wrong for either — the same posture `required-check-publisher.yml` takes for its per-commit slots.

## Budget, and its ceiling

`GITHUB_TOKEN` is rate-limited to **1,000 requests per hour per repository**, shared with every other Actions caller in that repository. A pass costs one listing plus, per open PR:

| per-PR cost | when |
|---|---|
| 2 reads | both contexts already reported natively — the steady state |
| 3 reads | plus the membership fence, on any head this lane publishes to |
| up to 8 reads | a head being recovered: author, body, labels, head re-read, membership, two CAS re-reads, and the Phase 4 derivation's own calls |

At `*/15` the steady state is therefore about `8 × open_PR_count` requests per hour. Two properties keep that honest rather than merely small:

- **Nothing is read that cannot change the outcome.** The author, body, label, membership and Phase 4 reads all happen inside the publish path, so a repository whose contexts are all healthy pays only the two check-run listings per PR.
- **The starting point rotates each pass**, derived from the clock rather than a stored cursor. If the allowance is exhausted mid-pass, the tail of the list would otherwise be the *same* PRs every time — silently never recovered. Rotation converts that into round-robin degradation.

**This is a bound, not a budget design.** Somewhere north of roughly 120 open PRs a repository cannot complete a pass, and the lane degrades rather than failing loudly. The structural fix is to fold these two contexts into `required-check-publisher.yml`, which already walks every open PR once and publishes three contexts, amortizing the listing across five instead of running a second independent sweep; that migration is staged in #845 and is out of scope here. Until then, the arithmetic above is the number to check before enabling the lane on a repository with a large open-PR population.

## What the fence pins

`scripts/ci/check_pr_review_policy_recovery` decides every workflow property over the **parsed** YAML, never a line grep — the block, quoted-key, quoted-`on:` and inline-mapping spellings of `workflow_dispatch` all resolve to the same trigger map, and a grep anchored to the unquoted key catches only the first. It pins the two recovery entrances, the 15-minute union property, the absence of `workflow_dispatch` on both this workflow and the gate workflow, the concurrency group, `checks: write` with no other write scope, a sweep job named for no required context, the trusted default-branch checkout, and the lockstep between the lane's two `external_id` constants, the Phase 4 query, and the gate workflow's job names.

It also pins that the recovery triggers stay in **this** file. Adding a `schedule` to `pr-review-policy.yml` would mean gating its three event-driven jobs to `pull_request`, and a skipped Actions job still materializes a check run under its own name; two of those names are required contexts and a skipped conclusion satisfies a required check. That is not hypothetical — a scheduled `coderabbit-severity-gate.yml` run leaves a skipped `CodeRabbit unresolved blocking findings` on this repository's own default-branch tip.
