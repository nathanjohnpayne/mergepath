# Decision Records

> Canonical source: `mergepath/docs/agents/decision-records.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. Machine-local vendor files (e.g. a `~/GitHub/CLAUDE.md`, `~/.codex/AGENTS.md`) that mirror this convention must carry a `> Canonical source:` annotation pointing back here — see the canonical-source discipline rule in `docs/agents/documentation-rules.md`.
>
> Consumer maintainers: the sync delivers this file but does not announce it. Your repo does already carry two pointers to it, and both are incidental. The shared pull-request template's `## Path taken` stub sits inside an HTML comment, reaches only PR authors at the moment they open a PR, and covers only the change-level half; the narration carve-out in `docs/agents/shared-operating-rules.md` § *PR and issue titles/descriptions* names this file by path, but it is reached only by an agent already reading that rule, and it likewise speaks for the change-level half alone. Neither is an index entry, and nothing points at the issue-level half at all. Link this file from your repo's own agent-docs index (your `AGENTS.md` reading order or operating-rules equivalent) so agents discover both halves deliberately.

This convention is deliberately tech-stack-independent: it says nothing about languages, frameworks, or build tooling, only about where a decision gets written down so the next reader finds it. It applies identically in every repo that receives it.

## One discipline, three granularities

Work changes shape constantly. What makes that expensive is not the change — it is that the mechanics of changing course **erase the reasoning behind it**. A force-push replaces the branch history. A retitle overwrites the previous framing. A rewritten PR body drops the superseded rationale. An issue filed as "deferred" keeps its deferred framing after it has been done. Review comments left on the old version dangle against code that no longer exists. And a decision settled in comment 40 of a long issue is invisible to anyone who reads only the body.

The reader who arrives later — human or agent — then cannot tell whether an approach was *never considered*, *considered and rejected*, or *implemented and then removed for cause*. So they re-propose the rejected approach and re-litigate a trade-off that was already settled. Recording the disposition is what prevents that, and it is the same discipline at three granularities:

| Granularity | Unit | Recorded where | Vocabulary |
| --- | --- | --- | --- |
| **Finding** | one review comment | the resolved review thread, tagged by the resolve tooling | `addressed-elsewhere` / `canonical-coverage` / `deferred-to-followup` / `nitpick-noted` / `rebuttal-recorded` / `templated-render` / `verified-propagation` |
| **Change** | one pull request | a `## Path taken` section in the PR body | prose chronology — what survived, what was discarded, why |
| **Issue** | one issue | an `[!IMPORTANT]` callout at the top of the issue body, linked to a dated decision comment | `Decision` / `Decision recommendation` |

The finding level already has tooling behind it: `scripts/resolve-pr-threads.sh` writes a `[mergepath-resolve:<class>]` tag on every thread it resolves, and that tag — not the bare fact that the thread is now closed — is the disposition of record the follow-up automation reads. That script is the authority on the vocabulary: the seven classes above are the complete set it emits, so a record carrying any other class is non-conformant, and a record carrying a routing class (`canonical-coverage`, `templated-render`) or `verified-propagation` is as conformant as a fixed-or-rebutted one. Which resolve mode records which class is documented in your repo's `REVIEW_POLICY.md` § Pre-Merge Review Conversation Gate; it is not restated here.

The two coarser levels below are that same rule applied to a whole change and to a whole issue: **record the disposition truthfully, at the place a later reader will actually look, and never by deleting the state it replaced.**

## Change level: record the path taken when a PR reverses direction

### Triggers

Every trigger below is a reversal of a position that was already **recorded** — in the PR body, in the branch's own commits, in the acceptance criteria, in a review comment or thread on the change, or in the driving issue's stated disposition. Review comments are recorded positions in the full sense, and the reviewer-disagreement trigger below depends on it: two reviewers' contradicting positions are usually written down nowhere else, so the threads holding them *are* the record an arbitration overrides, and the path record is the only durable statement of why one prevailed. That premise is the whole test, and each trigger should be read with it in force. If nothing recorded was contradicted, no trigger fired, however far the result sits from what anyone first pictured.

Record a path when any of these happens:

- the change reverses an approach it had itself recorded — described in its body or committed on its branch;
- an approach is implemented and then removed within the same PR;
- the change's own scope materially narrows or widens after it was opened for review — an acceptance criterion is struck, or it takes on work it had said it would not cover;
- a reviewer disagreement is arbitrated — by the human tiebreaker, or by the change adopting one reviewer's position over a contradicting reviewer's;
- an issue's recorded disposition changes as a result of the work — deferred → done, or done → won't-do.

### The non-trigger — read this before the triggers

**Fixing a review finding and pushing again is not a reversal.** The trigger is a change of **direction**, not a change of **code**. None of the following earns a `## Path taken` section:

- addressing review findings and pushing fixes — however many rounds it takes, and however much the diff grows in the process;
- a force-push for a rebase, a fixup squash, or an update-branch merge;
- adding the tests, docs, or error handling a reviewer asked for;
- correcting wording in the title, body, or a commit message;
- **implementing an issue in a different shape than the issue imagined**, when the change lands that way from the outset. An issue states a problem; choosing a solution for it is the design work, not a reversal of it, and an issue that sketched a solution did not thereby record it as decided. Nothing recorded was contradicted, so no trigger fired — the change simply has a shape, and the body's ordinary rationale is where that shape gets explained. (If the issue's *title* is now misleading, that is placement 3 below — a retitle — not a path record.)

This non-trigger is the load-bearing half of the convention. The failure mode it exists to prevent is **ceremony**: if every PR carries the section, the section stops carrying signal and readers learn to skip it, which costs more than never having had it. An empty or perfunctory `## Path taken` is worse than none at all.

The test to apply: *would a competent reader six months from now otherwise re-propose something this change already rejected, or re-open a question this change already settled?* If no, leave the section out.

### Required content

A path-taken record is prose, not a form. It must cover four things:

1. **Chronology.** What was tried, in order, and what caused each pivot.
2. **What survived and what was discarded, with reasons.** This is the most load-bearing part — it is the only thing that stops the discarded approach being re-proposed. Name the discarded approach concretely enough that someone about to re-suggest it recognizes it.
3. **Who arbitrated, and on what grounds.** When the pivot came from a human tiebreak, a reviewer disagreement, or an owner instruction, say so and say what the reasoning was. "The owner overruled the scheduling call" is a fact a later reader needs and cannot recover from the diff.
4. **Struck acceptance criteria, left visible.** Criteria that no longer apply are struck through, never deleted — deleting them makes it look as though they were never asked for.

Strike a criterion in place, keeping the checkbox, and append the reason and date:

```markdown
- [ ] ~~Add a base-only delta predicate to the carry-forward script.~~ — Discarded 2026-07-27: the compare endpoint is three-dot, so the predicate broke rebase carry-forward and was provably vacuous. See the path-taken record.
```

### Where the record goes

Three placements, each doing a different job. Use all three that apply.

**1. A `## Path taken` section in the PR body.** This is the record itself. Heading exactly:

```markdown
## Path taken
```

Repos that receive the shared pull-request template already carry this heading as an optional stub, with a hint to delete it when the PR did not reverse direction. Deleting it is the expected outcome on most PRs.

**And not a violation of the narration ban.** `docs/agents/shared-operating-rules.md` § *PR and issue titles/descriptions: describe the work, not the session* bans narrating a session's path in a title or description, and that ban covers PR bodies. This section is its one named exception, so the two documents are not in tension: the ban exists so a cold reader is never handed a chronology only the session's participants can decode, and this section exists for the single case where the chronology is what stops a settled question being re-opened. The exception is as wide as this heading plus one annotation that § Required content deliberately keeps outside it — an acceptance criterion struck in place with its dated discard reason, which has to stay in the criteria list to do its job — and no wider: everything else in the body, and the title above all, stays under the ban. That is also why the non-trigger list is load-bearing in both directions: a `## Path taken` on a PR that never reversed direction is not an exempt record, it is the narration the rule forbids, wearing a heading.

**Not the title.** A PR title describes the change's end state for a reader who never saw the session that produced it; "pivoted from X" describes the session, and X is a phrase only that session's participants can decode. A pivot marker in the title would also outlive its usefulness in the worst place — on a squash merge the title becomes the permanent commit subject, so every future reader of `git log --oneline` pays for a note that helps almost none of them. The record belongs in the PR body, where it has room to be intelligible, and `git log` still reaches it: the squash subject carries the `(#NN)` PR reference, and searching merged PR bodies for `## Path taken` enumerates the pivots directly. Retitle a PR when a pivot changes *what the change is* — to describe the new end state, never to announce that a pivot happened.

**2. A comment on the driving issue,** so the pivot is discoverable from the issue rather than only from the PR. Use the same shape as the issue-level decision callout below — a hidden idempotency marker, then a dated heading:

```markdown
<!-- path-taken-ISSUE-YYYY-MM-DD-SLUG -->
## Path taken — YYYY-MM-DD

<chronology, what survived and what was discarded, who arbitrated>
```

`ISSUE` is the issue number, `YYYY-MM-DD` the date the pivot was recorded, and `SLUG` a short kebab-case phrase naming the abandoned approach. The marker matches the decision-comment marker below, and `SLUG` is there for the same reason: a date alone does not separate two pivots recorded on one day. Match it the same way too — § 4 below governs this marker as well: search on `<!-- path-taken-ISSUE-` with the date wildcarded and the slug required, qualify the slug up front when the issue is returning to an approach it pivoted away from once before rather than inferring that from whatever the search happens to hit, and on a retry reuse the date already in the marker rather than recomputing it from `now`.

**3. A retitle of the driving issue,** when its framing is now stale — an issue titled "Defer X" that ended up doing X is actively misleading in a list view.

Retitling and re-editing churn notifications for everyone watching. **Do it once, at the end**, when the direction has actually settled — not incrementally as the work moves. One correct retitle is cheap and high-value; five successive ones train people to mute the repo.

## Issue level: surface a comment-recorded decision from the issue body

RFC and investigation issues accumulate their conclusion in a later comment while the body keeps presenting the original open questions. A reader arriving from search, a project board, or a direct link then misses the settled direction and repeats work that is already done. This half of the convention makes the current decision visible at the issue's entrypoint without rewriting its history.

### Trigger

A material decision or recommendation is recorded in an issue comment. "Material" means it changes what someone should do next: a chosen option among alternatives, an accepted trade-off, a scoping call, a go/no-go.

### 1. Post a structured decision comment

Preserve the full rationale in the comment. Hidden marker first, then a dated heading:

```markdown
<!-- decision-ISSUE-YYYY-MM-DD-SLUG -->
## Decision — YYYY-MM-DD

<decision, rationale, and implementation guardrails>
```

Use `Decision recommendation` in the heading when the comment records a recommendation awaiting final acceptance rather than a settled decision.

### 2. Prepend a linked callout to the issue body

Do not rewrite the historical problem statement — the body's original framing is part of the record. Prepend, above everything else:

```markdown
<!-- decision-comment-ISSUE-YYYY-MM-DD-SLUG -->
> [!IMPORTANT]
> **Decision recorded:** <one-sentence decision summary>. See the [full decision and implementation guardrails](COMMENT_PERMALINK).
```

Match the status language to the comment: use `**Decision recommendation recorded:**` and link text `full recommendation and implementation guardrails` when the comment is a recommendation.

In both markers, `ISSUE` is the issue number, `YYYY-MM-DD` is the decision date, and `SLUG` is a short kebab-case phrase naming the decision itself — the same shape the change-level `path-taken-` marker uses, for example `revert-and-defer` or `accept-recommendation`. The two markers for one decision then differ only by the `-comment` infix, and the pair is greppable. Reproduce the formats above byte-for-byte; a paraphrased callout defeats the point of a fleet-wide convention, because the marker is what later tooling and later agents match on.

The slug is not decoration: the date alone is not a unique key. An issue can carry two material decisions in one day, and a recommendation is very often accepted on the day it was posted — which § 5 counts as a supersession. Without the slug both records expand to the identical marker, and § 4's "if the marker is present, edit in place" would then treat the second decision as a retry of the first and overwrite the rationale that § 5 requires be preserved. Derive the slug from the decision you are about to write, never from a counter: a counter cannot be recomputed by an agent retrying after a crash, so it would post a duplicate instead of matching its own earlier write. The date is the counter's twin — it too cannot be recomputed by a retry, because a retry that straddles midnight computes a different one. That is why § 4 matches on the slug and wildcards the date rather than the other way round: the slug is the half a retrying agent can reconstruct. Reconstructible is not the same as unique, though — an issue that re-adopts a decision it once superseded would derive the same slug again — which is why § 4 has you qualify the slug against the issue's recorded history *before* you search, rather than trusting a bare slug to name one adoption.

### 3. Link the exact comment, not the issue

`COMMENT_PERMALINK` is the permalink to the specific comment — the `#issuecomment-<id>` form, obtained from the comment's own `html_url`. A link to the issue alone sends the reader back to the same wall of comments the callout exists to shortcut. Keep the body callout to one sentence and leave the full rationale in the comment; a body that grows a second copy of the rationale drifts out of sync with the comment on the first edit.

### 4. Idempotency and live readback

Both writes are retried by agents that crash, time out, or run twice. The hidden markers are what make a retry safe:

- **Before writing, search for the marker — and never search on a date you computed.** The body search key is the *undated, unslugged* prefix `<!-- decision-comment-ISSUE-`, trailing hyphen included so that issue 702 does not match a callout for issue 7020. Any hit means this issue already carries a callout, whatever date and slug it bears: edit it in place when you are retrying the same decision, replace it when you are superseding one (§ 5). Never prepend a second. Searching for the full **dated and slugged** body marker is the bug to avoid — on a superseding write it matches nothing, and § 2's "prepend, above everything else" then produces exactly the two-callout state § 5 forbids. The **comment** search key is narrower but still undated: `<!-- decision-ISSUE-`, then any `YYYY-MM-DD`, then `-SLUG -->` — slug required, date wildcarded. As a regular expression over issue 702's `revert-and-defer` decision, that is `<!-- decision-702-[0-9]{4}-[0-9]{2}-[0-9]{2}-revert-and-defer -->`.
- **Why the two keys differ, and why neither carries a date.** Requiring the slug on the comment is what keeps a supersession distinct: a superseding decision is a *new* comment carrying a *different* slug, and the earlier comment stays untouched as history, so matching on the slug means only a record of *this* decision matches — your own retry of it, or, until the next bullet has you qualify the slug, an earlier adoption of it — and a same-day supersession posts its own comment instead of overwriting the one it supersedes. Wildcarding the date is what makes the retry work at all: `YYYY-MM-DD` in the marker you are hunting for was computed by the run that wrote it, and an agent that crashes before midnight and retries after it computes a different one from `now`. A search for the freshly computed date then matches nothing, the agent concludes it never wrote the comment, and it posts a second copy of the same decision — the precise failure the markers exist to prevent. The body key drops the slug too because § 5 allows only one active callout regardless of which decision it names; the comment key keeps it because comments accumulate.
- **A slug can repeat, so qualify it *before* you search — do not let the search decide what you are doing.** The slug is derived from the decision, so an issue that returns to a decision it once superseded — `use-postgres`, then `use-dynamo`, then `use-postgres` again — would derive the *same* slug the second time, and a search on that bare slug hits the first adoption's comment. Treating that hit as a retry is the failure: the date bullet below would take its date from a marker written before the decision it now supersedes, and § 2's "edit it in place" would overwrite the first adoption's rationale with the third's, losing exactly the chronology § 5 exists to keep. Settle it at the source instead. Which case you are in is a fact about the issue's *recorded* history rather than about your own write, and it is readable before you search: a decision this issue has never recorded keeps the bare slug, while a return to one it recorded and then moved away from takes a qualified slug per the re-adoption bullet below. The search key is then unique to this adoption, and the search is left answering only the question it is good at — have I already written *this* record?
- **Ask whether the issue moved on across both marker families, not just your own.** What carried an issue away from a decision is not always another `decision-` comment: placement 2 above puts a change-level pivot in a `path-taken-` comment, and a switch recorded there alone produces no decision comment at all. So when you check whether the issue has moved off the decision your slug names, scan the records posted after it under **both** the `decision-` and `path-taken-` markers. Scoping that scan to your own family is the bug this bullet exists to prevent: a `use-postgres` decision superseded by a path record alone still reads as the issue's latest `decision-` comment, so a later re-adoption keys on the bare slug, inherits the pre-supersession date, and edits the first adoption's rationale away — the same loss, one family over.
- **A return to a superseded decision is a re-adoption, so re-key it.** § 5 then applies in full — post a new comment, replace the single body callout — and the slug must be qualified so it names *this* adoption distinctly: `use-postgres-after-dynamo`, derived from the record it supersedes, never `use-postgres-2`. The derivation matters for the same reason the base slug's does: a counter cannot be recomputed by an agent retrying after a crash, while "the slug of the record this one supersedes" is durable data already on the issue, so a retry of the qualified write re-derives the same qualified slug, searches on it, finds its own comment, and correctly recognizes itself.
- **Ordering corroborates authorship, it does not prove it, and a concurrent writer inverts it.** With a single writer on the issue the arithmetic looks clean — a crashed run's own record is the last one posted, and a superseded record never is — which makes it tempting to read the ordering as a test of whose write you matched. It is not one. Let another agent record a decision on the same issue between your crash and your retry, and its comment is newer than yours; re-derived against that changed history, your own unfinished first adoption reads exactly like an earlier adoption something later superseded, so you qualify a slug you should not have qualified and post a second comment for a decision you already posted — the duplicate these markers exist to prevent, entered from the other side. Content is the anchor the ordering cannot be: before posting any re-adoption, read the record you are about to key away from. If it already states the decision you are about to record — the same one, carrying the rationale you were going to write, not a related earlier one — it is your own unfinished write however much has been posted since, so edit it in place under its existing slug and date and post nothing. Post the qualified comment only when the record you matched states the *earlier* decision, which is what a genuine re-adoption supersedes. If even that leaves it genuinely ambiguous, take the branch that cannot duplicate: leave the matched record standing, write nothing, and surface the conflict. This narrows the concurrent-writer race the way the fresh-read-then-write bullet below narrows the body race — it does not close it, and nothing available here does.
- **Take the date from the record, not from the clock.** `YYYY-MM-DD` is the date the decision was *recorded*, so it is fixed by the first successful write and every later retry inherits it. When the slug-keyed search finds an existing comment *and the bullets above have established it is your own write rather than an earlier adoption*, read the date out of the marker you matched and use *that* date for the comment heading, for the body callout's marker, and for the callout's wording; recompute from `now` only for a decision being written for the first time, which a re-adoption is. This is what keeps the `decision-` and `decision-comment-` markers a matched pair across a retry that straddles midnight — recomputing on one side alone splits the pair whose greppability § 2 promises.
- **Build the body you write from a read taken immediately before writing it.** The API replaces the entire body and offers no compare-and-swap, so a write assembled from a copy read earlier in the run silently erases everything another actor changed in between. Re-read, apply the callout to *that* text, and send it back as the very next call; if the fresh read differs from the text your callout was drafted against, rebuild against the fresh one rather than writing the stale copy. This narrows the exposure to a single round trip — it does not close it, and nothing available here does.
- **After writing, verify by positive readback.** Re-read the live issue body and the live comment through the API and confirm all four: the comment exists under the expected author identity and carries its marker; the permalink in the callout resolves to that comment's id; the body carries exactly one marker under the `<!-- decision-comment-ISSUE-` prefix — counted by that prefix, so a second callout bearing a different date or slug is caught; and the callout's wording states the current decision. A write call that returned without an error is not verification: it does not prove the comment is reachable at the permalink you published, nor that the body came out with exactly one callout rather than two.
- **Know what the readback does not prove.** It does not detect a lost update. All four checks run against the body *you* just wrote, so if your write clobbered a concurrent edit to unrelated content, every check still passes and the overwritten text leaves no trace in any of them. Treat the readback as proof that your own write landed intact and unduplicated, and the fresh-read-then-write discipline above — not the readback — as the mitigation for the race.

### 5. Supersession

The body carries **exactly one active callout**. When a decision is superseded:

- post the new decision comment — the old comment stays exactly where it is, as history. Its marker carries a new slug, and a new date only if the day has in fact changed; the slug is what keeps the two markers distinct when the supersession happens on the same day as the decision it replaces, which is the ordinary case when a pending recommendation is accepted in the same working session;
- **replace** the existing callout in the body with one pointing at the new comment, rather than adding a second. Two callouts leave the reader to guess which is current, which is the failure this convention exists to prevent;
- if the new decision **changes direction** rather than refining the previous one, also record a path taken per the change-level half above. Accepting a pending recommendation is a supersession of the recommendation callout, not a direction change.

### Reference example

`nathanjohnpayne/mergepath#702` is the canonical worked example: a structured decision comment holding the complete rationale, and a top-of-body `[!IMPORTANT]` callout in the recommendation wording linking to that exact comment.

- Decision comment: <https://github.com/nathanjohnpayne/mergepath/issues/702#issuecomment-5104563868>
- Issue body: <https://github.com/nathanjohnpayne/mergepath/issues/702>

## Enforcement: convention-only, deliberately

**Decision: this is convention-only. No CI check requires a `## Path taken` section or a body callout, and none should be added as a required gate.** The decision is recorded here rather than left implicit, because "we never got around to it" and "we considered it and declined" are exactly the two states this document exists to distinguish.

The reasoning:

- **No CI-visible artifact distinguishes the trigger from the non-trigger.** The trigger is semantic — a change of direction. Every mechanical signal a check could read is dominated by the non-trigger: a force-push is the normal mechanism for a rebase, a fixup squash, and an update-branch; a title or body edit is normal for fixing a typo; a growing diff is the normal result of addressing review findings. A check built on any of them would flag mostly ordinary iteration.
- **A required gate that guesses wrong blocks correct work.** Failing closed is the right posture for a gate that can be *right*; a gate that must infer intent from a force-push cannot be. The cost of a false positive here is a blocked PR and an agent looking for the incantation that unblocks it.
- **Enforcement would manufacture the ceremony the convention is designed to avoid.** A required section is satisfied by pasting an empty heading. That trains every agent to paste the heading, at which point the section's presence carries no information and its absence carries none either — strictly worse than the unenforced version, where the section appears only when someone had something to say.
- **The real enforcement point is review.** A reviewer who can see the PR's history is the only reader positioned to judge whether a reversal happened, and flagging a missing path record is a normal review comment. This is the same enforcement posture as `docs/agents/worktree-placement.md`, which is likewise explicit that it has no CI gate and should not acquire one.

**When to revisit.** The objection above is to *inferring* a pivot from mechanical noise, not to checking a record against itself. The `<!-- path-taken-ISSUE-YYYY-MM-DD-SLUG -->` comment marker is a deliberate artifact — nothing emits it by accident — so once it is in routine use an **advisory** check becomes defensible: one that comments "the driving issue carries a path-taken record but this PR body has no `## Path taken` section" and blocks nothing. It reads a positive signal someone chose to write rather than guessing intent from a force-push. That is the only form worth reconsidering; a required gate is not.
