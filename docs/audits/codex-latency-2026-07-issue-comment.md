<!--
Ready-to-paste comment for issue #623. Prepared by the study PR; NOT
posted automatically — a human (or an explicitly authorized agent session)
pastes it. Full analysis: docs/audits/codex-latency-2026-07.md.
-->

## Latency study results (mergepath, 2026-04-15 → 2026-07-02)

Produced by the committed read-only `scripts/audit-codex-latency.sh` over 270 PRs (#53–#628), 400 `@codex review` triggers, 104 verdict comments, 325 Codex review objects, and the **complete retained run history** of both gate workflows (2,593 + 8,071 runs, persisted as JSONL in `docs/audits/data/codex-latency-2026-07/` before retention ages them out). Fully retrospective — no probe PRs, no synthetic events; every what-if is a replay over recorded timestamps.

### Distributions (n / p50 / p90 / p99 / max)

| Event pair | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| 1. trigger → 👀 ack | — pending reactions backfill (see below) | | | | |
| 2. trigger → first inline finding | — pending inline-comment backfill (same run as pairs 1/4) | | | | |
| 2b. trigger → first review response (proxy: clean or findings) | 197 | 4m45s | 13m51s | 21m13s | 30m39s |
| 3. trigger → verdict comment | 100 | 3m37s | 7m6s | 10m30s | 13m50s |
| 4. trigger → 👍 clearance | — pending reactions backfill | | | | |
| 5. push → auto-review | 128 | 4m12s | 11m10s | 33m1s | 36m1s |
| 6a. clearance → next eligible merge-clearance-gate sweep | 13 | 30s | 1m3s | — | 1m16s |
| 6b. clearance → next eligible auto-clear-blocking-labels sweep | 14 | 30s | 1m16s | — | 28m52s |
| 6c. gate run queue delay (created→started), paired runs | 27 | 0s | 0s | 0s | 0s |
| 6d. clearance → merged (head-anchored verdicts) | 17 | 1m43s | 9m26s | — | 39m57s |

Pair-6 clearances are anchored on the merge head (a pre-push verdict is stale per #567/#600); "next eligible sweep" = successful pre-merge run — whether that sweep cleared THIS PR's gate isn't derivable from run records (green auto-clear runs can leave the label), so 6a/6b measure opportunity-to-clear.

Segmented tables (diff size, round number, hour, weekday, rate-limited) are in `docs/audits/data/codex-latency-2026-07/summary.md`.

### The folklore vs the record

- **"Codex takes 15–40+ min"**: no completed round in the entire history took 15 minutes. p50 is 3m37s; the recorded max is 13m50s. Only 2/100 rounds exceeded the 600s in-script wait.
- **The real failure mode is non-response, not slowness**: 75/400 triggers (~19%) drew a not-connected marker ("To use Codex here…", the #570 class), 17 drew a rate-limit marker (those rounds produce **no verdict at all**, not a slow one), 8 (2%) got no response of any kind within 2h.
- **The crons don't run at their spec**: GitHub throttles `schedule` events so hard that both the `*/15` and the `*/5` cron fire with a **median gap of ~96–98 minutes** (p99 ≈ 5–6h). The #613 "queued ~27 min" was cron lateness — queue-after-created is 0s on 10,653 of 10,664 retained runs (the 11 exceptions are event-triggered runs, max 35m29s), and 0s on every paired gate run. Clearances get swept fast only because event-triggered runs (`pull_request_review` nudges: p50 28s) carry the load — all 13 head-anchored clearances were swept by event runs; the cron swept none.
- **"Sweeps are ~60% of Actions spend"**: for these two workflows, scheduled runs are ~9% of run volume and ~10% of run-minutes; event-triggered runs are the cost driver.

### Knob dispositions

| Knob | Default | Measured | Disposition |
|---|---|---|---|
| `codex.review_timeout_seconds` | 600 | verdict p90 426s / p99 630s / max 830s | Confirm ~600s (or raise to 900s to cover the recorded max). The tail to engineer for is dropped/rate-limited triggers (~21%), not slow verdicts — `--trigger-only` + event-driven pickup stays the escape path. Retune PR to cite p99=630s. |
| `codex.ack_wait_seconds` × `max_ack_retries` | 60×1 | pair-1 pending reactions backfill | Deferred on backfill: reaction timestamps aren't readable from this session's API access; one run of the script with a normal PAT fills pairs 1+4. The "~4 min no-👀" runbook heuristic sits at p50(verdict) and is almost certainly too slow as an ack test. |
| `codex.reaction_freshness_window_seconds` | 1800 | 13/13 head-anchored clearances swept ≤1800s — all via event runs (p50 ≈ 28s); the cron swept none, and its measured gap (p50 ≈ 96m) is far outside the window | Keep 1800s; finish the event-driven re-arm (#620) instead of widening. Covering the cron path would need ≥5400s and weakens staleness protection. |
| Sweep cadences `*/15` / `*/5` | cron | both deliver ~1.6h median effective cadence; sweeps ≈10% of run-minutes | The cadence spec barely matters under GitHub throttling. Cadence replay must model measured firing behavior, not the spec; higher-leverage retune is event-trigger dedup. Slowing to `*/30` ≈ free given event triggers stay. |

Artifacts: audit script `scripts/audit-codex-latency.sh` (offline-reproducible via `--analyze-only`), full write-up `docs/audits/codex-latency-2026-07.md`, committed extracts (runs/events/pairs/summary) in `docs/audits/data/codex-latency-2026-07/`.
