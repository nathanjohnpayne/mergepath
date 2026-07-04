<!--
Posted to issue #623 on 2026-07-04 (nathanpayne-claude). This file mirrors
the published comment, completed with the pair-1/2/4 reactions backfill.
Full analysis: docs/audits/codex-latency-2026-07.md.
-->

## Latency study results (mergepath)

Produced by the committed read-only `scripts/audit-codex-latency.sh` (merged in #629), fully retrospective — no probe PRs, no synthetic events; every what-if is a replay over recorded GitHub timestamps. Full write-up: `docs/audits/codex-latency-2026-07.md`; committed extracts under `docs/audits/data/codex-latency-2026-07/`.

Two passes are reported: the original study window (2026-04-15 → 2026-07-02, 270 PRs) and a **fresh re-run with reaction + inline-comment access** (2026-05-01 → 2026-07-04, 293 PRs) that fills the pairs the first pass had to defer. The core distributions are stable across both windows (verdict max 13m50s is identical).

### Distributions (n / p50 / p90 / p99 / max)

| Event pair | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| 1. trigger → 👀 ack | 14 | 9s | 11s | 13s | 13s |
| 2. trigger → first inline finding | 208 | 5m16s | 13m46s | 19m57s | 30m39s |
| 3. trigger → verdict comment | 100 | 3m37s | 7m6s | 10m30s | 13m50s |
| 4. trigger → 👍 clearance | — | unmeasured — wrong endpoint (see below) | | | |
| 5. push → auto-review | 128 | 4m12s | 11m10s | 33m1s | 36m1s |
| 6a. clearance → next merge-clearance-gate sweep | 13 | 30s | 1m3s | — | 1m16s |
| 6b. clearance → next auto-clear-blocking-labels sweep | 14 | 30s | 1m16s | — | 28m52s |
| 6c. gate run queue delay (created→started) | 27 | 0s | 0s | 0s | 0s |
| 6d. clearance → merged (head-anchored verdicts) | 17 | 1m43s | 9m26s | — | 39m57s |

Segmented tables (diff size, round, hour, weekday, rate-limited) are in `docs/audits/data/codex-latency-2026-07/summary.md` (original) and `docs/audits/data/codex-latency-2026-07/summary-backfill-2026-07-04.md` (backfill run).

### The folklore vs the record

- **"Codex takes 15–40+ min"**: no completed round in the entire history took 15 minutes. Verdict p50 is 3m37s; the recorded max is 13m50s. Only 2/100 rounds exceeded the 600s in-script wait.
- **The real failure mode is non-response, not slowness**: ~19% of triggers drew a not-connected marker ("To use Codex here…", the #570 class), rate-limited rounds produce **no verdict at all** rather than a slow one, and ~2% got no response of any kind within 2h.
- **The crons don't run at their spec**: GitHub throttles `schedule` events so hard that both the `*/15` and the `*/5` cron fire with a **median gap of ~96–98 minutes** (p99 ≈ 5–6h). Queue-after-created is 0s on 10,653 of 10,664 retained runs. Clearances get swept fast only because event-triggered runs (`pull_request_review` nudges: p50 ≈ 28–30s) carry the load — every head-anchored clearance was swept by an event run; the cron swept none.
- **"Sweeps are ~60% of Actions spend"**: for these two workflows, scheduled runs are ~9% of run volume and ~10% of run-minutes; event-triggered runs are the cost driver.

### Backfill: ack + first-finding + the 👍 non-signal (fresh re-run)

- **Ack is fast and extremely tight**: every healthy ack in the record landed in 6–13s (p50 9s, p99 13s, max 13s, n=14). The "~4 min no-👀 = dropped" runbook heuristic is ~18× the measured p99 — far too slow as a dropped-trigger test.
- **First inline finding** (n=208): p50 5m16s, p90 13m46s, p99 19m57s, max 30m39s — the longer tail vs the verdict comment is expected (inline findings only exist on rounds that *have* findings, which skew to larger diffs / later rounds).
- **Pair 4 (👍 clearance) is NOT resolved — the audit measures the wrong object.** The script reads a `+1` on the *trigger comment*, but the merge gate (`codex-review-check.sh`) reads the clearance 👍 from the *PR issue* (`repos/$REPO/issues/$PR_NUMBER/reactions`). The 0 trigger-comment `+1`s found is an endpoint artifact, **not** evidence that 👍 clearance is unused — gate (b) branch 2 depends on those 👍s (they expire after 30 min). 👍-clearance latency is therefore unmeasured; a follow-up fixes the script's pair-4 definition and re-measures.

### Knob dispositions

| Knob | Default | Measured | Disposition |
|---|---|---|---|
| `codex.review_timeout_seconds` | 600 | verdict p90 426s / p99 630s / max 830s; 2/100 rounds > 600s | **✅ Confirm ~600s.** The tail to engineer for is dropped/rate-limited triggers (~21%), not slow verdicts; `--trigger-only` + event-driven pickup stays the escape path for the ~2% that exceed 600s. |
| `codex.ack_wait_seconds` × `max_ack_retries` | 60×1 | **ack p99 = 13s** (backfilled) | **🔧 Retune → 30s** (2.3× p99, zero misfire risk on healthy acks), cutting dropped-trigger failover from 120s to ~30s. Separate PR citing p99(ack)=13s; runbook "~4 min no-👀" → "healthy ack p99=13s; treat >30s with no 👀 as dropped." |
| `codex.reaction_freshness_window_seconds` | 1800 | all head-anchored clearances swept ≤1800s, all via event runs (p50 ≈ 28–30s); cron effective gap ≈ 96m | **✅ Keep 1800s.** Finish the event-driven re-arm (#620) instead of widening; covering the cron path would need ≥5400s and weaken staleness protection. |
| Sweep cadences `*/15` / `*/5` | cron | both deliver ~1.6h median effective cadence; sweeps ≈10% of run-minutes | **🔧 Slow to `*/30`** — the cadence spec barely matters under GitHub throttling and event triggers carry clearance latency. Separate PR (workflow files are propagated → lands in a propagation wave). |

**Status:** 2 knobs **confirmed** (no change, percentile cited) and 2 pending **retune PRs** (ack_wait → 30s; cron cadences → `*/30`, plus the "15–40 min" comment in `agent-review.yml:501`). Those two touch `.github/` protected paths / propagated workflow surfaces, so per this issue's own "changes land as separate PRs" guardrail they ship as separate Phase-4 / wave PRs.

Artifacts: `scripts/audit-codex-latency.sh` (offline-reproducible via `--analyze-only`), `docs/audits/codex-latency-2026-07.md`, committed extracts in `docs/audits/data/codex-latency-2026-07/`.
