# Codex review latency audit — mergepath, 2026-07

Study deliverable for [#623](https://github.com/nathanjohnpayne/mergepath/issues/623)
("Measure actual Codex review latency and retune every folklore-tuned wait
window from the data"). This document covers the **study** only; the retunes
land as separate follow-up PRs per the issue's guardrails, each citing the
percentile it is based on. No knob or `.github/review-policy.yml` value is
changed here.

**Headline: the folklore is wrong in both directions.**

- "Codex takes 15–40+ minutes" — measured trigger→verdict is **p50 3m37s,
  p90 7m6s, p99 10m30s, max 13m50s** (n=100). No completed round in the
  entire history took 15 minutes.
- The real failure mode is not slowness but **non-response**: ~19% of all
  historical `@codex review` triggers drew a "To use Codex here, create a
  Codex account…" not-connected marker instead of a review (the #570 dropped
  class), and rate-limited rounds produce no verdict at all rather than a
  slow one.
- The `*/15` and `*/5` gate crons **do not run at their configured cadence**:
  GitHub throttles scheduled events so hard that the median gap between
  consecutive scheduled runs is **~96–98 minutes for both workflows**. The
  event-driven re-check path (review-comment nudges, label events) is what
  actually carries clearance→merge latency today.
- Scheduled sweeps are **not** the dominant Actions cost of these workflows:
  they are 9% of run volume and ~10% of billed run-minutes; event-triggered
  runs are the other ~90%.

## Method

Fully retrospective, per the #623 hard constraint: every number below comes
from events already recorded on GitHub — issue comments, reviews, PR
metadata, commit committer dates, and Actions workflow-run records. No
synthetic PRs, no probe triggers, no simulated event streams; every
"what-if" is a replay over the recorded timestamps.

The committed, reproducible pipeline is `scripts/audit-codex-latency.sh`
(read-only; `gh api --paginate` on every listing call). For this pass the
raw records were mined through the session's read-only GitHub API access
into the same normalized-record schema the script's fetch phase emits, and
the script's own `--analyze-only` phase produced every table below from the
committed extract (see § Reproducibility).

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

Both workflows' run histories were mined to their first retained record and
persisted as JSONL (see § Reproducibility) because GitHub ages run records
out (~90-day retention) — the cron-queueing analysis stays replayable after
the live records expire.

## Findings

### Pair 3 — trigger → verdict (the `review_timeout_seconds` pair)

| segment | n | p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| ALL | 100 | 3m37s | 7m6s | 8m35s | 10m30s | 13m50s |

Only 2 of 100 completed rounds exceeded the 600s in-script wait. The
"15–40+ min" folk belief is contradicted by the entire recorded history.
Rate-limited rounds are absent from this table by construction: **a
rate-limited round produces no verdict on that trigger at all** (the 17
rate-limit markers all correspond to rounds that ended in a marker, not a
slow verdict) — the tail risk `review_timeout_seconds` guards against is
non-response, not slow response.

### Pair 2 — trigger → first inline finding

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 209 | 4m44s | 13m51s | 19m57s | 30m39s |

Measured from bot review submissions (inline findings become visible at
review submission; this session's access exposes review `submitted_at`
rather than per-inline-comment `created_at` — the committed script fetches
the inline-comment endpoint too when run with `gh api` access).

### Pair 5 — push → auto-review (no trigger)

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 119 | 4m12s | 11m22s | 33m1s | 36m1s |

Auto-reviews (Codex reviewing a push/open without an explicit trigger) run
at the same p50 as triggered rounds, with a fatter tail (~36 min worst
case). Anchor is the reviewed commit's committer date; rounds whose
verdict carries no `Reviewed commit:` line (the older verdict format) are
excluded for lack of a recorded push anchor.

### Pairs 1 and 4 — 👀 ack and 👍 clearance reactions: not measurable in this pass

Reaction **timestamps** live only on the per-comment reactions endpoint
(`/issues/comments/{id}/reactions`), which this session's GitHub access
does not expose. The committed script implements both pairs (it fetches
reactions for every trigger comment, paginated); **one run of
`scripts/audit-codex-latency.sh --repo nathanjohnpayne/mergepath` from any
environment with a normal PAT backfills both distributions** into the same
tables. The `ack_wait_seconds` disposition below is deferred on that
backfill rather than guessed.

### Trigger health (the #570 dropped-trigger class)

Of 400 historical trigger comments:

- 75 (~19%) drew a **not-connected marker** ("To use Codex here, create a
  Codex account and connect to github") within 5 minutes — the trigger was
  dropped, and no amount of waiting would have produced a review.
- 17 drew a **rate-limit marker** ("You have reached your Codex usage
  limits for code reviews…").
- 8 (2%) got **no bot response of any kind within 2 hours** — the truly
  silent drop the #419 ack gate exists for.

### Pair 6 — clearance → gate pass → merge

Clearance anchor: the last affirmative verdict comment before `merged_at`
(👍-reaction clearance times are pending the pair-4 backfill; PRs whose
only clearance signal was a 👍 or a findings-free review object are
conservatively excluded rather than approximated).

| metric | n | p50 | p90 | max |
|---|---|---|---|---|
| clearance → next `merge-clearance-gate` run that could sweep the PR | 33 | 1m16s | 42m32s | 1h29m |
| clearance → next `auto-clear-blocking-labels` run | 57 | 2m18s | 49m32s | 5h10m |
| gate run queue delay (`run_started_at − created_at`) | 90 | 0s | 0s | 0s |
| gate run duration (`updated_at − run_started_at`), merge-clearance | 33 | 13s | 30s | 43s |
| gate run duration, auto-clear | 57 | 14s | 25s | 1m17s |
| clearance → `merged_at` | 66 | 4m56s | 7h39m | 118h50m |

Split by what triggered the sweeping run (merge-clearance-gate):

| gate run trigger | n | p50 | max |
|---|---|---|---|
| `pull_request_review` (the nudge pattern) | 20 | 54s | 5m13s |
| `pull_request` (label events etc.) | 5 | 4m48s | 25m39s |
| `pull_request_review_comment` | 2 | 4m3s | 4m3s |
| `schedule` (the `*/15` cron) | 6 | 61m36s | 89m12s |

Two structural results:

1. **Queue delay is zero.** `run_started_at == created_at` on every one of
   the 10,664 mined runs. The #613 "cron queued ~27 min" observation was
   not queueing after creation — it was the cron *firing late* (below).
2. **The crons do not run at their spec.** Measured gaps between
   consecutive scheduled runs:

| workflow | spec | n gaps | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| merge-clearance-gate (`*/15`) | 15m | 277 | 96m16s | 4h14m | 5h53m | 6h20m |
| auto-clear-blocking-labels (`*/5`) | 5m | 689 | 98m1s | 3h58m | 5h21m | 61h11m |

GitHub throttles `schedule` events severely; both crons deliver a median
effective cadence of ~1.6 hours regardless of whether the spec says 5 or
15 minutes. Clearances get swept fast **only because event-triggered runs
(review submissions, label changes) fire within ~1 minute** — 27 of the 33
paired clearances were swept by an event run, not the cron.

### Actions cost split

| workflow | event-triggered | scheduled |
|---|---|---|
| auto-clear-blocking-labels | 7,381 runs / 1,565 run-min | 690 runs / 157 run-min |
| merge-clearance-gate | 2,315 runs / 556 run-min | 278 runs / 71 run-min |

Scheduled sweeps are ~10% of these workflows' billed run-minutes. The
"sweeps are ~60% of monthly spend" belief does not hold for these two
workflows — event-triggered runs are the cost driver, so retuning cron
cadence has limited direct cost leverage; de-duplicating event triggers has
more.

## Knob dispositions (data-backed; retunes land as separate PRs)

| Knob | Default | Measured | Disposition |
|---|---|---|---|
| `codex.review_timeout_seconds` | 600s | verdict p90 = 426s, p99 = 630s, max = 830s; 2/100 rounds over 600s | **Confirm ~600s, or raise to 900s to cover the recorded max (830s).** The foreground wait is nearly right-sized for rounds that complete; timeouts are dominated by rounds that will *never* complete (dropped/rate-limited triggers, ~21% historically), so `--trigger-only` + event-driven pickup remains the right escape path, not a longer wait. |
| `codex.ack_wait_seconds` × `max_ack_retries` | 60s × 1 | pair-1 ack distribution pending the reactions backfill (one local script run) | **Deferred, with a concrete backfill step.** Bounding context from measured pairs: verdicts land p50 3m37s after the trigger; not-connected markers land within ~10–60s. The "~4 min no-👀 = dropped" runbook heuristic sits right at p50(verdict) and is almost certainly too slow as an ack test — but the retune must cite p99(ack), which requires the backfill. |
| `codex.reaction_freshness_window_seconds` | 1800s | 29/33 clearances were swept inside 1800s — but only because event runs land p50 ≈ 54s; the cron path alone lands p50 ≈ 62m, far outside the window | **The window is only viable because of the event-driven path.** Widening it to cover the cron path would need ≥ ~5400s (cron p50+) and weakens staleness protection; the data supports finishing the event-driven re-arm (#620) so the window's role keeps shrinking, and otherwise leaving 1800s in place. |
| Sweep cadences (`*/15`, `*/5`) | cron | effective median cadence ~96–98 min for BOTH specs; scheduled runs are ~10% of run-minutes; 27/33 clearances swept by event runs | **The cadence knob barely does anything.** GitHub throttling makes `*/5` and `*/15` deliver the same ~1.6h median; the replay for candidate cadences should model the measured firing behavior, not the spec. Slowing to `*/30` would cut a small, mostly-idle cost slice with negligible latency impact *given the event triggers stay*; the higher-leverage retune is event-trigger dedup. |

Runbook/docs references to the folklore numbers ("15–40 min", "~4 min
no-👀") should be replaced with the measured ones (p50 3m37s / p90 7m6s /
p99 10m30s verdict; ack pending backfill) — that lands with the retune PRs.

## Known gaps and exclusions (all fail-closed)

- **Pairs 1/4** (reaction timestamps): not exposed to this session's GitHub
  access; the committed script fetches them; one local run backfills.
- **👍-only and review-object-only clearances** are excluded from pair 6
  rather than approximated (COMMENTED review state carries no
  affirmative/negative signal without finding-tier evaluation).
- **Old-format verdicts** (no `Reviewed commit:` line — the line was added
  to Codex's verdict template mid-history) pair by time for pair 3 but are
  excluded from pair 5 for lack of a recorded push anchor.
- **Run-retention guard**: clearances older than the oldest retained run of
  a workflow are excluded from that workflow's pair-6 rows instead of
  mis-pairing with the oldest survivor.
- **Segment cells with tiny n** (per-hour, per-weekday) are in the full
  generated tables in the data directory; treat n<10 cells as anecdote.

## Follow-ups

- Backfill pairs 1 and 4 by running the script with normal `gh` access;
  then retune `ack_wait_seconds`/`max_ack_retries` citing p99(ack).
- Retune PRs for the four knob rows above, each citing this document.
- Cadence replay over the recorded clearance timestamps using the measured
  (throttled) cron firing behavior — never live trials.
- **Consumer-repo sweep** (same script, `--repo` per consumer) is a possible
  follow-up; this pass is mergepath-only by scope.

## Reproducibility

- Script: `scripts/audit-codex-latency.sh` (this PR). Live re-mine:
  `scripts/audit-codex-latency.sh --repo nathanjohnpayne/mergepath`.
- Committed extract (this study's inputs and outputs):
  `docs/audits/data/codex-latency-2026-07/`
  - `runs.jsonl` — the trimmed Actions workflow-run records (the
    retention-critical extract #623 requires persisting)
  - `events.jsonl` — the full normalized event stream (PRs, commits,
    triggers, verdicts, markers, reviews, runs)
  - `pairs.jsonl` — one record per measured event-pair instance
  - `summary.md` — the full generated percentile tables, all segments
- Recompute everything from the extract without touching the API:
  place `runs.jsonl` (and the other raw inputs) under `<out>/raw/` per the
  script header, or reuse the committed `events.jsonl`/`pairs.jsonl`
  directly — the tables in this document are `summary.md` rendered from
  `pairs.jsonl` by the script's summarize step.
