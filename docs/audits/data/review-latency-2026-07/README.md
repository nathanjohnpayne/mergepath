# Review-cycle wait-window retune — measured dataset (#623)

Committed extract behind the review-cycle wait-window retune in #623. It
supplies the two latency distributions the earlier Codex-only study
(`docs/audits/data/codex-latency-2026-07/`, #629) did not mine, so every knob
in the #623 table is retuned from a measured percentile rather than folklore:

- **CodeRabbit review latency** → `coderabbit.max_wait_seconds`
- **Phase-4b adapter latency** → corroborates `codex.review_timeout_seconds`

The Codex App pairs (👀 ack, verdict, 👍 clearance) that back
`codex.ack_wait_seconds` and `codex.review_timeout_seconds` are **not**
re-mined here — they are already committed under
`docs/audits/data/codex-latency-2026-07/` and are cited below by reference.

## Provenance

Produced by `scripts/audit-review-latency.sh` — read-only and fully
retrospective (the #623 method constraint): the only GitHub calls are
`gh api` GETs, nothing is posted, and no event stream is simulated. Every
number is a pre-existing GitHub record or a locally-recorded phase-4b loop
log.

```
scripts/audit-review-latency.sh \
  --repos nathanjohnpayne/swipewatch,nathanjohnpayne/matchline,nathanjohnpayne/nathanpaynedotcom,nathanjohnpayne/overridebroadway,nathanjohnpayne/tadlockpsychiatry,nathanjohnpayne/device-source-of-truth,nathanjohnpayne/friends-and-family-billing,nathanjohnpayne/device-platform-reporting \
  --since 2026-05-15 \
  --loops-dir .mergepath/phase-4b-loops
```

(This is also the script's default `--repos`.)

- **CodeRabbit** is mined across all eight CodeRabbit-active consumer repos
  (the hub, mergepath, does not run CodeRabbit auto-review), which is the
  sampling frame where `coderabbit-wait.sh` actually runs.
- **Phase-4b** adapter latency is read from the local
  `.mergepath/phase-4b-loops/*.jsonl` loop logs (gitignored runtime
  artifacts); only the body-free `.loop` fields are extracted here — never
  the `.details` finding text.

### Files

| File | Contents |
|---|---|
| `events.jsonl` | Normalized, **body-free** event stream (`commit` / `cr_review` / `cr_ratelimit` / `pr` / `p4b_round`). Safe to commit; replayable. |
| `pairs.jsonl` | One record per measured latency instance. |
| `summary.md` | `n / p50 / p90 / p99 / max` per distribution, segmented by repo / diff size / rate-limited / weekday / hour. |

Reproduce the analysis offline (after GitHub ages the live records out — the
same replay guarantee as the Codex study):

```
scripts/audit-review-latency.sh --analyze-only \
  --out-dir docs/audits/data/review-latency-2026-07
```

## What CodeRabbit review latency measures

`cr_review_latency = review.submitted_at − committer_date(review.commit_id)`,
for the **earliest body-bearing review per commit**. CodeRabbit review objects
are immutable and carry the reviewed `commit_id`, so each pairs unambiguously
with the commit it reviewed. Two deliberate exclusions:

- **Empty (body-less) review objects** — CodeRabbit emits these when resolving
  threads or replying to interactions, not when reviewing a push (observed on
  swipewatch#80: one 5.6 KB review at +689s, then six empty objects at +1090s).
- **The PR-level summary comment** is *not* used: CodeRabbit posts it as an
  early walkthrough placeholder (~37s) and then edits it in place, so neither
  its `created_at` nor its `updated_at` is a clean measure of when the review
  landed.
- **Rate-limited rounds** (a CodeRabbit rate-limit notice between the commit
  and the review) segment out as `rate_limited=true` — those are the
  `coderabbit-wait.sh` retry path, not the `max_wait_seconds` budget.

## Distributions

### CodeRabbit review latency (rate_limited=false, n=142, all 8 consumers)

| p50 | p90 | p99 | max |
|---|---|---|---|
| 414s (6m54s) | 861s (14m21s) | 1136s (18m56s) | 1219s (20m19s) |

Mined across **all eight** CodeRabbit-active consumers (every consumer ships
`coderabbit.enabled: true`; see `docs/agents/coderabbit-audit.md`). An earlier
5-repo pass understated the max at 1136s — the slowest observed review (1219s)
is in `device-source-of-truth`, one of the three repos that pass omitted.

The "typical ~2–3 min review" folklore encoded in `coderabbit.max_wait_seconds`
was wrong by ~2×: the real p50 is ~6 min, and the tail reaches ~19 min.

### Phase-4b adapter latency (from the loop logs)

| pair | n | values (s) |
|---|---|---|
| `a_p4b_adapter_review` (verdict-producing) | 11 | 188, 261, 296, 447, 547, 582, 616, 626, 699, 750, 782 |
| `a_p4b_adapter_abort` (UNAVAILABLE — quota/connection) | 5 | 2, 2, 4, 8, 116 |

Both live `*.jsonl` and rotated `*.jsonl.archive` loop logs are scanned — the
Phase-4b accounting hook empties a live log into its `.archive` sibling once an
approval/fallback posts, so a live-only scan would drop every completed round
(this fix lifted the review sample from 4 to 11). Still a small sample
(phase-4b automation is recent), reported for corroboration only. Every real
CLI review completed in 188–782s, comfortably under the phase-4b adapter's own
900s timeout — an independent confirmation that a real Codex review takes
~3–13 min, **not** the "15–40 min" folk belief, consistent with the Codex App
verdict distribution below.

### Codex App pairs (by reference — `docs/audits/data/codex-latency-2026-07/`)

| pair | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| trigger → 👀 ack | 14 | 9s | 11s | 13s | 13s |
| trigger → verdict | 100 | 217s | 426s | 630s | 830s |

## Retune dispositions

| Knob | Was | Now | Basis |
|---|---|---|---|
| `codex.ack_wait_seconds` (script default) | 60 | **30** | ack p99=13s (n=14); 30s ≈ 2.3× p99. Aligns the script fallback to the policy value already shipped in #647. |
| `codex.max_ack_retries` | 1 | **1** (confirmed) | Ack latency sizes the *window*, not the retry *count*; unchanged. |
| `codex.review_timeout_seconds` | 600 | **840** | verdict p99=630s / max=830s (n=100); 👍-clearance p99=829s (n=60, #646). 600 sat below p99. 840 = 56×15s poll intervals, covers the full clean-verdict tail, < the 900s phase-4b ceiling. |
| `coderabbit.max_wait_seconds` | 300 | **1245** | full-fleet review p50=414s / p90=861s / p99=1136s / max=1219s (n=142, all 8 consumers). 300 sat below even p50 → >50% of PRs raced past CodeRabbit (#136). 1245 = 83×15s poll intervals = one interval beyond the observed max (1219s), so the slowest observed review still gets a poll scan before the top-of-loop timeout check (#688); it is a ceiling (returns when the review lands). Consumer per-repo `max_wait_seconds: 300` overrides are migrated in a sync-wave follow-up (#690). |
| `coderabbit.status_probe_wait_seconds` / `wallclock_freshness_window_seconds` / rate-limit + status-flip grace | — | unchanged (confirmed) | Not review-latency constants; the review-latency data does not contradict them (review p99 1136s < the 1800s freshness floor). |

No gate is weakened: every retune only lengthens an advisory/foreground wait or
tightens a fail-fast window, preserving fail-closed semantics. The
dropped/rate-limited non-response tail (Codex #570) is out of scope for the
foreground timeouts by design — `--trigger-only` + event-driven pickup remains
its escape path.
