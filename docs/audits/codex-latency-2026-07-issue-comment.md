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
| 2. trigger → first inline finding | 206 | 4m42s | 13m46s | 19m57s | 30m39s |
| 3. trigger → verdict comment | 100 | 3m37s | 7m6s | 10m30s | 13m50s |
| 4. trigger → 👍 clearance | — pending reactions backfill | | | | |
| 5. push → auto-review | 119 | 4m12s | 11m22s | 33m1s | 36m1s |
| 6a. clearance → next merge-clearance-gate run | 27 | 59s | 25m39s | — | 1h1m |
| 6b. clearance → next auto-clear-blocking-labels run | 48 | 1m17s | 30m1s | — | 1h35m |
| 6c. gate run queue delay (created→started) | 75 | 0s | 0s | 0s | 0s |
| 6d. clearance → merged | 66 | 4m56s | 7h39m | — | 118h50m |

Segmented tables (diff size, round number, hour, weekday, rate-limited) are in `docs/audits/data/codex-latency-2026-07/summary.md`.

### The folklore vs the record

- **"Codex takes 15–40+ min"**: no completed round in the entire history took 15 minutes. p50 is 3m37s; the recorded max is 13m50s. Only 2/100 rounds exceeded the 600s in-script wait.
- **The real failure mode is non-response, not slowness**: 75/400 triggers (~19%) drew a not-connected marker ("To use Codex here…", the #570 class), 17 drew a rate-limit marker (those rounds produce **no verdict at all**, not a slow one), 8 (2%) got no response of any kind within 2h.
- **The crons don't run at their spec**: GitHub throttles `schedule` events so hard that both the `*/15` and the `*/5` cron fire with a **median gap of ~96–98 minutes** (p99 ≈ 5–6h). The #613 "queued ~27 min" was cron lateness — measured queue-after-created is 0s on all 10,664 runs. Clearances get swept fast only because event-triggered runs (`pull_request_review` nudges: p50 37s) carry the load — 25/27 measured clearances were swept by an event run, not the cron.
- **"Sweeps are ~60% of Actions spend"**: for these two workflows, scheduled runs are ~9% of run volume and ~10% of run-minutes; event-triggered runs are the cost driver.

### Knob dispositions

| Knob | Default | Measured | Disposition |
|---|---|---|---|
| `codex.review_timeout_seconds` | 600 | verdict p90 426s / p99 630s / max 830s | Confirm ~600s (or raise to 900s to cover the recorded max). The tail to engineer for is dropped/rate-limited triggers (~21%), not slow verdicts — `--trigger-only` + event-driven pickup stays the escape path. Retune PR to cite p99=630s. |
| `codex.ack_wait_seconds` × `max_ack_retries` | 60×1 | pair-1 pending reactions backfill | Deferred on backfill: reaction timestamps aren't readable from this session's API access; one run of the script with a normal PAT fills pairs 1+4. The "~4 min no-👀" runbook heuristic sits at p50(verdict) and is almost certainly too slow as an ack test. |
| `codex.reaction_freshness_window_seconds` | 1800 | 25/27 clearances swept ≤1800s — but only via event runs (p50 37s); schedule-only path p50 ≈ 43m | Keep 1800s; finish the event-driven re-arm (#620) instead of widening. Covering the cron path would need ≥5400s and weakens staleness protection. |
| Sweep cadences `*/15` / `*/5` | cron | both deliver ~1.6h median effective cadence; sweeps ≈10% of run-minutes | The cadence spec barely matters under GitHub throttling. Cadence replay must model measured firing behavior, not the spec; higher-leverage retune is event-trigger dedup. Slowing to `*/30` ≈ free given event triggers stay. |

Artifacts: audit script `scripts/audit-codex-latency.sh` (offline-reproducible via `--analyze-only`), full write-up `docs/audits/codex-latency-2026-07.md`, committed extracts (runs/events/pairs/summary) in `docs/audits/data/codex-latency-2026-07/`.
