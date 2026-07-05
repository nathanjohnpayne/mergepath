# Codex review latency audit — mergepath, 2026-07

Study deliverable for [#623](https://github.com/nathanjohnpayne/mergepath/issues/623) ("Measure actual Codex review latency and retune every folklore-tuned wait window from the data"). This document covers the **study** only; the retunes land as separate follow-up PRs per the issue's guardrails, each citing the percentile it is based on. No knob or `.github/review-policy.yml` value is changed here.

**Headline: the folklore is wrong in both directions.**

- "Codex takes 15–40+ minutes" — measured trigger→verdict is **p50 3m37s, p90 7m6s, p99 10m30s, max 13m50s** (n=100). No completed round in the entire history took 15 minutes.
- The real failure mode is not slowness but **non-response**: ~19% of all historical `@codex review` triggers drew a "To use Codex here, create a Codex account…" not-connected marker instead of a review (the #570 dropped class), and rate-limited rounds produce no verdict at all rather than a slow one.
- The `*/15` and `*/5` gate crons **do not run at their configured cadence**: GitHub throttles scheduled events so hard that the median gap between consecutive scheduled runs is **~96–98 minutes for both workflows**. The event-driven re-check path (review-comment nudges, label events) is what actually carries clearance→merge latency today.
- Scheduled sweeps are **not** the dominant Actions cost of these workflows: they are 9% of run volume and ~10% of billed run-minutes; event-triggered runs are the other ~90%.

## Backfill addendum (2026-07-04)

The original pass deferred pairs 1 and 4 (👀 ack / 👍 clearance reactions) because that session could not read the per-comment reactions endpoint. The committed `scripts/audit-codex-latency.sh` was re-run with reaction + inline-comment access (window 2026-05-01 → 2026-07-04, 293 PRs); the supplementary extract is `docs/audits/data/codex-latency-2026-07/summary-backfill-2026-07-04.md` with the load-bearing ack samples under `backfill-2026-07-04/`. This resolves pair 1 (ack) and pair 2 (first finding) and completes the `ack_wait_seconds` disposition. Pair 4 (👍 clearance) needed an endpoint fix — the first backfill read the trigger comment, not the PR issue; #645 corrected the audit and re-measured it (n=60, p99 13m49s). The pair-2 and pairs-1/4 sections further down are updated to match:

| Event pair | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| 1. trigger → 👀 ack | 14 | 9s | 11s | 13s | 13s |
| 2. trigger → first inline finding | 208 | 5m16s | 13m46s | 19m57s | 30m39s |
| 4. trigger → 👍 clearance | 60 | 3m35s | 7m26s | 13m49s | 13m49s |

- **Ack is fast and extremely tight** — every healthy ack landed in 6–13s (p99 13s, max 13s). The "~4 min no-👀 = dropped" heuristic is ~18× the measured p99, far too slow as a dropped-trigger test.
- **Pair 4 (👍 clearance) — measured after the #645 fix**: n=60, p50 3m35s, p90 7m26s, p99 13m49s, max 13m49s. The first backfill read `+1` on the *trigger comment* (`issues/comments/{id}/reactions`) and found 0 — an endpoint bug, since the merge gate (`scripts/codex-review-check.sh`) reads the clearance 👍 from the *PR issue* (`repos/$REPO/issues/$PR_NUMBER/ reactions`). #645 fixed the audit to read that endpoint (fix in #646). The 👍-clearance distribution tracks the verdict latency (pair 3) closely, as expected — the 👍 IS Codex's clean-verdict signal. Gate (b) branch 2 relies on these PR-issue 👍s (they expire after 30 min), so 👍 clearance is real and now measured — NOT verdict-only.
- **Completed `ack_wait_seconds` disposition** — with p99(ack)=13s, the ack gate's per-wait budget of 60s is already 4.6× p99, and the full failover path (one 60s wait, one repost, a second 60s wait) is up to 120s. A healthy ack always lands inside the first wait (13s ≪ 30s), so **retune ack_wait → 30s**: still 2.3× p99 per wait with no misfire risk, halving dropped/ rate-limited failover from ≤120s to ≤60s. Replace the runbook "~4 min no-👀" with "healthy ack p99=13s; treat >30s with no 👀 as dropped." Lands as a separate PR per the guardrail below.

Study results were posted to #623 on 2026-07-04.

## Method

Fully retrospective, per the #623 hard constraint: every number below comes from events already recorded on GitHub — issue comments, reviews, PR metadata, commit committer dates, and Actions workflow-run records. No synthetic PRs, no probe triggers, no simulated event streams; every "what-if" is a replay over the recorded timestamps.

The committed, reproducible pipeline is `scripts/audit-codex-latency.sh` (read-only; `gh api --paginate` on every listing call). For this pass the raw records were mined through the session's read-only GitHub API access into the same normalized-record schema the script's fetch phase emits, and the script's own `--analyze-only` phase produced every table below from the committed extract (see § Reproducibility).

Event pairs measured (definitions from #623):

| # | Pair | Anchor → response |
|---|---|---|
| 1 | trigger → 👀 ack | trigger comment `created_at` → bot `eyes` reaction |
| 2 | trigger → first finding | → earliest bot inline/review submission in the round |
| 3 | trigger → verdict | → the bot's `Codex Review: …` **issue comment** (#567) |
| 4 | trigger → 👍 clearance | → bot `+1` reaction on the trigger comment |
| 5 | push → auto-review | reviewed-commit committer date → verdict/review, trigger-less rounds |
| 6 | clearance → gate → merge | clearance → next gate-workflow run → `merged_at` |

## Data inventory

| Record class | n | Window |
|---|---|---|
| PRs mined (all state=all PRs since Codex adoption at PR #53) | 270 | 2026-04-15 → 2026-07-02 |
| `@codex review` trigger comments | 400 | same |
| Codex verdict issue comments (`Codex Review: …`) | 104 | same |
| Codex review objects (COMMENTED submissions) | 325 | same |
| Codex rate-limit marker comments | 17 | same |
| Codex not-connected markers ("To use Codex here…") | 107 | same |
| `merge-clearance-gate.yml` runs (complete retained history) | 2,593 | 2026-06-09 → 2026-07-02 |
| `auto-clear-blocking-labels.yml` runs (complete retained history) | 8,071 | 2026-05-03 → 2026-07-02 |

Both workflows' run histories were mined to their first retained record and persisted as JSONL (see § Reproducibility) because GitHub ages run records out (~90-day retention) — the cron-queueing analysis stays replayable after the live records expire.

## Findings

### Pair 3 — trigger → verdict (the `review_timeout_seconds` pair)

| segment | n | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| ALL | 100 | 3m37s | 7m6s | 8m35s | 10m30s | 13m50s |

Only 2 of 100 completed rounds exceeded the 600s in-script wait. The "15–40+ min" folk belief is contradicted by the entire recorded history. Rate-limited rounds are absent from this table by construction: **a rate-limited round produces no verdict on that trigger at all** (the 17 rate-limit markers all correspond to rounds that ended in a marker, not a slow verdict) — the tail risk `review_timeout_seconds` guards against is non-response, not slow response.

### Pair 2 — trigger → first inline finding

Backfilled 2026-07-04 (see the addendum above): **n=208, p50 5m16s, p90 13m46s, p99 19m57s, max 30m39s.** Rigorous pair 2 requires the bot's inline review comments — a clean, inline-less review submission is not a finding and must not count (the script enforces that: a review only qualifies when it carries ≥1 inline comment). The pair 2b proxy below (any first review response) remains a useful strict upper bound.

What this pass CAN measure rigorously is **pair 2b — trigger → first review response of any kind** (findings-bearing or clean review submission), a strict upper-bound-free proxy:

| segment (pair 2b) | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 197 | 4m45s | 13m51s | 21m13s | 30m39s |

Pair-2/2b windows close at failure markers exactly as verdict pairing does (a rate-limited or not-connected round produces no first-response sample; the later response is a new round's auto-review) — the 9 rounds this excludes are the same 9 pair 5 recovered above.

### Pair 5 — push → auto-review (no trigger)

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 128 | 4m12s | 11m10s | 33m1s | 36m1s |

Auto-reviews (Codex reviewing a push/open without an explicit trigger) run at the same p50 as triggered rounds, with a fatter tail (~36 min worst case). Responses arriving after a failed trigger (a rate-limit or not-connected marker consumed it) count here, not as trigger→verdict — binding them to the dead trigger would inflate pair 3 with exactly the non-response cases this audit measures. Anchor is the reviewed commit's committer date; rounds whose verdict carries no `Reviewed commit:` line (the older verdict format) are excluded for lack of a recorded push anchor.

### Pairs 1 and 4 — 👀 ack and 👍 clearance reactions

**Pair 1 (👀 ack) backfilled 2026-07-04**: n=14, p50 9s, p99 13s, max 13s. The ack lands on the trigger comment, and the script measures it there correctly — this pair is now sound and drives the `ack_wait_seconds` retune.

**Pair 4 (👍 clearance) — fixed in #645.** The script originally read a `+1` on the *trigger comment* (`issues/comments/{id}/reactions`), but the merge gate (`scripts/codex-review-check.sh`, lines ~933/1081) reads the clearance 👍 from the *PR issue* (`repos/$REPO/issues/$PR_NUMBER/reactions`). The first backfill therefore found 0 trigger-comment `+1`s — an endpoint artifact, not evidence that 👍 clearance is unused (gate (b) branch 2 depends on it). #645 corrected the audit to read that endpoint (fix in #646) and re-measured: **n=60, p50 3m35s, p90 7m26s, p99 13m49s, max 13m49s** — tracking the verdict latency (pair 3) closely, since the 👍 is Codex's clean-verdict signal.

### Trigger health (the #570 dropped-trigger class)

Of 400 historical trigger comments:

- 75 (~19%) drew a **not-connected marker** ("To use Codex here, create a Codex account and connect to github") within 5 minutes — the trigger was dropped, and no amount of waiting would have produced a review.
- 17 drew a **rate-limit marker** ("You have reached your Codex usage limits for code reviews…").
- 8 (2%) got **no bot response of any kind within 2 hours** — the truly silent drop the #419 ack gate exists for.

### Pair 6 — clearance → gate pass → merge

Clearance anchor: the last affirmative verdict comment before `merged_at` (👍-reaction clearance times are pending the pair-4 backfill; PRs whose only clearance signal was a 👍 or a findings-free review object are conservatively excluded rather than approximated). The verdict must be ANCHORED ON THE MERGE HEAD (`Reviewed commit` sha prefixes the PR's final head) — the merge gate treats a pre-push verdict as stale (#567/#600), so sha-mismatched and sha-less old-format verdicts are excluded fail-closed. The same head anchor applies to 👍-reaction clearances once the backfill supplies their timestamps: a reaction older than the merge-head committer date is stale by the gate's own `reaction_threshold` rule, so it is excluded fail-closed rather than mis-anchored (inert in this pass — the extract carries no reaction timestamps — but load-bearing post-backfill). That exclusion is itself a finding: only 17 of 66 merges carried a head-anchored affirmative verdict comment as their recorded clearance; the rest cleared via 👍 reactions or review-object paths whose timestamps are pending the pairs-1/4 backfill. A paired gate run must have concluded `success` (a skipped/failed run cannot clear labels or satisfy the required check) and have been created before `merged_at` — clearances whose first eligible run postdates the merge are censored, not mis-paired.

These rows measure clearance → next **eligible sweep run** (a successful, pre-merge run that could have evaluated this PR) — an opportunity-to-clear time. Whether that specific sweep actually cleared THIS PR's gate is not derivable from run records alone (the auto-clear workflow exits 0 even when it leaves the label in place; scheduled merge-clearance can post a per-PR failure while the workflow stays green) — per-PR check-run mining is a follow-up.

| metric | n | p50 | p90 | max |
|---|---|---|---|---|
| clearance → next eligible `merge-clearance-gate` sweep | 13 | 30s | 1m3s | 1m16s |
| clearance → next eligible `auto-clear-blocking-labels` sweep | 14 | 30s | 1m16s | 28m52s |
| gate run queue delay (`run_started_at − created_at`) | 27 | 0s | 0s | 0s |
| gate run duration (`updated_at − run_started_at`), merge-clearance | 13 | 12s | 17s | 19s |
| gate run duration, auto-clear | 14 | 15s | 25s | 26s |
| clearance → `merged_at` | 17 | 1m43s | 9m26s | 39m57s |

(Head-anchoring shrank these tables sharply AND cleaned them: the previous 7h39m p90 / 118h50m max on clearance→merge was stale-verdict noise — verdicts from long-superseded pushes mis-anchoring the clock.)

Split by what triggered the sweeping run (merge-clearance-gate):

| gate run trigger | n | p50 | max |
|---|---|---|---|
| `pull_request_review` (the nudge pattern) | 12 | 28s | 1m16s |
| `pull_request_review_comment` | 1 | 47s | 47s |
| `schedule` (the `*/15` cron) | 0 | — | — |

Not one head-anchored clearance was swept by the cron: all 13 were picked up by event-triggered runs within ~1 minute.

Two structural results:

1. **Queue delay is near-zero, and zero on every paired gate run.** All 75 runs paired in the tables above started the second they were created. Across the full 10,664 retained runs, 11 (0.1%, all event-triggered) had non-zero `run_started_at − created_at`, max 35m29s — so runner queueing exists but is rare; the dominant dead-time mechanism behind the #613 "cron queued ~27 min" observation is the cron *firing late* (below), not post-creation queueing.
2. **The crons do not run at their spec.** Measured gaps between consecutive scheduled runs:

| workflow | spec | n gaps | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| merge-clearance-gate (`*/15`) | 15m | 277 | 96m16s | 4h14m | 5h53m | 6h20m |
| auto-clear-blocking-labels (`*/5`) | 5m | 689 | 98m1s | 3h58m | 5h21m | 61h11m |

GitHub throttles `schedule` events severely; both crons deliver a median effective cadence of ~1.6 hours regardless of whether the spec says 5 or 15 minutes. Clearances get swept fast **only because event-triggered runs (review submissions, label changes) fire within ~1 minute** — every one of the 13 paired head-anchored clearances was swept by an event run, not the cron.

### Actions cost split

| workflow | event-triggered | scheduled |
|---|---|---|
| auto-clear-blocking-labels | 7,381 runs / 1,565 run-min | 690 runs / 157 run-min |
| merge-clearance-gate | 2,315 runs / 556 run-min | 278 runs / 71 run-min |

Scheduled sweeps are ~10% of these workflows' billed run-minutes. The "sweeps are ~60% of monthly spend" belief does not hold for these two workflows — event-triggered runs are the cost driver, so retuning cron cadence has limited direct cost leverage; de-duplicating event triggers has more.

## Knob dispositions (data-backed; retunes land as separate PRs)

| Knob | Default | Measured | Disposition |
|---|---|---|---|
| `codex.review_timeout_seconds` | 600s | verdict p90 = 426s, p99 = 630s, max = 830s; 👍-clearance p99 = 829s (#646); 2/100 rounds over 600s | **Retuned → 840s** (realizing this row's own "raise to cover the recorded max" option). 600 sat below p99(verdict)=630, so the slowest ~1% of clean rounds (and the 830s max) timed out to Phase 4b needlessly. 840 = 56 × the 15s poll interval covers the full clean-verdict / 👍 tail and stays under the 900s phase-4b adapter ceiling. The dropped/rate-limited non-response tail (~21%) is still out of scope by design — `--trigger-only` + event-driven pickup is its escape path, not a longer wait. |
| `codex.ack_wait_seconds` × `max_ack_retries` | 60s × 1 | **ack p99 = 13s** (backfilled 2026-07-04, n=14; see addendum) | **Retune → 30s.** Healthy acks land in 6–13s, so 60s × 1 (120s) is 4.6× p99 — safe but slow to fail over on the ~19% dropped/rate-limited class. 30s stays 2.3× p99 with no misfire risk and cuts dropped-trigger failover from 120s to ~30s. Replace the "~4 min no-👀" runbook heuristic with "healthy ack p99=13s; treat >30s with no 👀 as dropped." **Policy value shipped in #647; the retune PR aligns the `codex-review-request.sh` fallback default (60→30) to match.** |
| `codex.reaction_freshness_window_seconds` | 1800s | 13/13 head-anchored clearances were swept inside 1800s — all by event runs (p50 ≈ 28s); no cron sweep ever carried one, and the measured cron gap (p50 ≈ 96m) sits far outside the window | **The window is only viable because of the event-driven path.** Widening it to cover the cron path would need ≥ ~5400s (cron p50+) and weakens staleness protection; the data supports finishing the event-driven re-arm (#620) so the window's role keeps shrinking, and otherwise leaving 1800s in place. |
| Sweep cadences (`*/15`, `*/5`) | cron | effective median cadence ~96–98 min for BOTH specs; scheduled runs are ~10% of run-minutes; 13/13 head-anchored clearances swept by event runs | **The cadence knob barely does anything.** GitHub throttling makes `*/5` and `*/15` deliver the same ~1.6h median; the replay for candidate cadences should model the measured firing behavior, not the spec. Slowing to `*/30` would cut a small, mostly-idle cost slice with negligible latency impact *given the event triggers stay*; the higher-leverage retune is event-trigger dedup. |

Runbook/docs references to the folklore numbers ("15–40 min", "~4 min no-👀", CodeRabbit "~2–3 min") are replaced with the measured ones in the retune PR (the `codex-review-request.sh` and `coderabbit-wait.sh` headers + the `.github/review-policy.yml` knob comments). The CodeRabbit review-latency and phase-4b adapter distributions that back the `coderabbit.max_wait_seconds` retune live in a sibling extract, `docs/audits/data/review-latency-2026-07/`.

## Known gaps and exclusions (all fail-closed)

- **Pair 1 (👀 ack)**: backfilled 2026-07-04 (n=14, p99 13s). **Pair 4 (👍 clearance)**: fixed in #645 to read the PR-issue reactions (the gate's endpoint); re-measured n=60, p50 3m35s, p99 13m49s.
- **👍-only and review-object-only clearances** are excluded from pair 6 rather than approximated (COMMENTED review state carries no affirmative/negative signal without finding-tier evaluation).
- **Old-format verdicts** (no `Reviewed commit:` line — the line was added to Codex's verdict template mid-history) pair by time for pair 3 but are excluded from pair 5 for lack of a recorded push anchor.
- **Run-retention guard**: clearances older than the oldest retained run of a workflow are excluded from that workflow's pair-6 rows instead of mis-pairing with the oldest survivor.
- **Segment cells with tiny n** (per-hour, per-weekday) are in the full generated tables in the data directory; treat n<10 cells as anecdote.

## Follow-ups

- **Fix pair 4's endpoint — DONE (#645 / #646)**: the audit now reads the clearance 👍 from `repos/$REPO/issues/$PR_NUMBER/reactions` (the PR issue, the gate's endpoint); re-measured n=60, p50 3m35s, p99 13m49s.
- Retune status for the four knob rows above: `ack_wait_seconds` → 30 shipped in #647 (script fallback aligned in the current retune PR); `review_timeout_seconds` → 840 in the current retune PR; `coderabbit.max_wait_seconds` → 1155 in the current retune PR (see `docs/audits/data/review-latency-2026-07/`); the sweep-cadence `*/30` retune remains a propagation-wave follow-up.
- Cadence replay over the recorded clearance timestamps using the measured (throttled) cron firing behavior — never live trials.
- **Consumer-repo sweep** (same script, `--repo` per consumer) is a possible follow-up; this pass is mergepath-only by scope.

## Reproducibility

- Script: `scripts/audit-codex-latency.sh` (this PR). Live re-mine: `scripts/audit-codex-latency.sh --repo nathanjohnpayne/mergepath`.
- Committed extract (this study's inputs and outputs): `docs/audits/data/codex-latency-2026-07/`
  - `runs.jsonl` — the trimmed Actions workflow-run records (the retention-critical extract #623 requires persisting)
  - `events.jsonl` — the full normalized event stream (PRs, commits, triggers, verdicts, markers, reviews, runs)
  - `pairs.jsonl` — one record per measured event-pair instance
  - `summary.md` — the full generated percentile tables, all segments
- Recompute everything from the extract without touching the API: place `runs.jsonl` (and the other raw inputs) under `<out>/raw/` per the script header, or reuse the committed `events.jsonl`/`pairs.jsonl` directly — the tables in this document are `summary.md` rendered from `pairs.jsonl` by the script's summarize step.
