# Propagation wave ordering and change-handling

Status: **canonical, in-repo source of truth.** The order below is reviewed monthly; the dated review log lives on the repo wiki page [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log). See [§ Maintenance](#maintenance) for how the doc and that log stay in sync.

This is a **hub-only** doc — it governs how a canonical change is fanned out *from* mergepath *to* the 8 consumers via `scripts/sync-to-downstream.sh`. It is intentionally **not** in `.mergepath-sync.yml` (consumers don't run propagation waves). It complements [templated-propagation.md](templated-propagation.md) (the rendering engine) and the canary-first note in `.mergepath-sync.yml`.

Treat this as the default for every propagation wave unless a specific wave documents a reason to deviate in its own tracking issue.

## Default propagation order (riskiest → least, in pairs)

This is the **fan-out** order — the sequence in which consumer PRs are opened *after* the canary is green.

| Wave | Pair | Why this tier |
|---|---|---|
| **1 (riskiest)** | `overridebroadway` + `nathanpaynedotcom` | overridebroadway: historically special-cased ("CodeRabbit disabled" era), most bespoke `path_instructions`. nathanpaynedotcom: only consumer with a `tools.eslint.enabled: false` override (Astro) + highest churn. |
| **2** | `matchline` + `tadlockpsychiatry` | Both React+TS. matchline = well-trodden reference (deepest bot history); tadlockpsychiatry = quietest / least-observed. |
| **3** | `device-source-of-truth` + `friends-and-family-billing` | Recently touched by the ESLint-floor work. |
| **4 (safest)** | `device-platform-reporting` + `swipewatch` | Simplest surfaces; swipewatch is the documented ESLint canary. |

**Rationale:** the dominant failure mode for a wave is **per-consumer idiosyncrasy** (config divergence, local adaptations), not a uniform payload break. Front-loading the most divergent repos surfaces any check-vs-config interaction while attention is full; fixes land once at the source and later pairs become verification. Simplest repos last = cheap confirmation. (All 8 consumers are **public** as of 2026-07-06 — visibility was once an ordering factor, since a private repo's CI failures aren't readable without auth, but it no longer distinguishes the tiers; the axis is now divergence and churn.)

## Canary selection (always do ONE first)

Before any fan-out, sync ONE consumer and get its PR green:

```bash
# --repos narrows the --sync-all mode to a single consumer (it is a filter, not a mode)
scripts/sync-to-downstream.sh --sync-all --repos <canary>
```

Pick the canary by the **dominant risk of this change**:

- **Uniform manifest/payload gap** (the #264 class — a missing test / fixture / script the kit hard-requires) → cheapest to catch on the **simplest public** repo (`swipewatch`).
- **Per-consumer config idiosyncrasy** → the **most-divergent** repo (`nathanpaynedotcom` / `overridebroadway`), which then doubles as canary + first wave.

Only fan out (`--sync-all`) once the canary's `lint` is green **and the wave audit below has cleared (or is recorded as unavailable)**; the remaining consumers re-use the cleared invariant instead of each re-discovering the problem.

## Wave audit (one scoped review per wave, #662)

A verified mirror carries nothing unreviewed: every line already passed review on its upstream mergepath PR, and the propagation lane byte-verifies the mirror. So the wave's external review runs **once**, against the canary PR, scoped to the canonical range that has not been audited before — instead of CodeRabbit + Codex re-reading the same bytes on all 8 consumers:

```bash
# After the canary PR is open and lane-verified:
scripts/wave-audit.sh <canary-pr> --repo <owner>/<canary-repo>
# First audited wave only (no watermark yet): add --base <last-reviewed-sha>
```

The helper resolves base = the newest `wave-audit-pass/<sha>` watermark tag that is an ancestor of the wave head, head = the mergepath sha in the canary title, builds a curated diff over the audited-head manifest paths (minus `propagation_audit.scope_exclude_prefixes` — default `tests/`, `docs/`), and dispatches `scripts/phase-4b-review.sh --diff-file` under the `propagation_audit:` posture in `.github/review-policy.yml`. Paths **newly added to the manifest** in the range are diffed against the empty tree, so pre-existing bytes a wave newly delivers are audited in full rather than escaping as "unchanged". The curated diff is load-bearing, not just cheaper: `gh pr diff` refuses wave-sized sync PRs outright (HTTP 406 above 20k lines).

**Precondition (fail-closed):** the helper refuses to dispatch unless the canary's current head carries the head-pinned propagation-lane marker. The audit reviews canonical content and its APPROVED clears the canary via the Phase 4b substitute path — sound only over a byte-verified mirror, so an unverified or diverged canary exits 3 before any review runs.

Verdict contract — same golden rule as below, fix at the SOURCE:

- **APPROVED (exit 0):** the watermark advances (tag pushed to origin). Fan out with `sync-to-downstream.sh --sync-all --coderabbit-ignore` and post **no** `@codex review` on the mirrors — fan-out PRs merge on consumer CI + the lane byte-verification + the required reviewer approval only.
- **CHANGES_REQUESTED (exit 1):** fix at the mergepath source, re-cut the wave (`--recreate-existing`), re-run the audit on the fresh canary. The superseded canary takes its blocking review with it — no dismissal choreography. (This is the #651/#652 → #653 → re-cut cycle, minus the manual per-consumer triage.)
- **Reviewer unavailable (exit 4/5 — quota, timeout, automation off):** no watermark. The wave MAY proceed on CI + lane (fail-open, record it in the wave tracker); the un-audited range chains into the next wave audit automatically, because the watermark only advances on a posted APPROVED (or a scope-empty range).
- **Infrastructure/config failure (exit 3 — including a failed review POST):** hard stop, not a proceedable audit miss. No reliable verdict exists and the local setup or the GitHub write path is broken — fix it and rerun before fanning out.

The canary keeps the full advisory CodeRabbit pass — open it **without** `--coderabbit-ignore`.

## Procedure when changes are required

> **Golden rule: a sync PR is a verbatim mirror — fix at the SOURCE (mergepath), never the consumer copy.** Editing the consumer copy breaks the propagation-lane fingerprint (`branch_prefix` + `author_identity` + *every changed file on manifest surface*), drops the PR to a full Phase-4 review, and gets clobbered on the next sync.

1. **Canary fails → STOP the fan-out.** Investigate in that one PR before opening any others. Most failures are upstream manifest gaps that the `requires:` closure would have caught.
2. **Decide where the fix belongs:**
   - **Canonical source (common case):** fix in mergepath (script / workflow / manifest), land it, re-propagate. *Example: #482 — a test/check lockstep closure gap fixed in `.mergepath-sync.yml`, not in any consumer.*
   - **Genuinely consumer-specific:** use `.sync-overrides.yml` on the dest path, or a per-consumer `facts:` / `exclusions:` entry (with a `reason:`) in `.mergepath-sync.yml`. Do not hand-edit the propagated file.
3. **Bot findings on a consumer sync PR** (they re-flag against canonical content, so they classify `canonical-coverage` — a mergepath concern):
   - **Real** → fix in mergepath, re-propagate; resolve the thread (reviewer PAT).
   - **False positive** → post a substantive rebuttal reply, *then* resolve.
   - **Real but non-blocking P2** → file a `post-review,observation` follow-up issue before resolving (don't silently drop).
   - Codex App threads on an amended HEAD won't auto-resolve → use the identity-checked `resolveReviewThread` mutation (see REVIEW_POLICY.md § Operation-to-Identity Matrix).
4. **Re-propagation mechanics:** after the source fix merges, re-run the sync. **Never rerun a stale-payload run** (close/redo it). Some consumers auto-merge on approval; bootstrap-gated repos need a human break-glass.

## repo_lint.yml travels in waves (#601)

`.github/workflows/repo_lint.yml` is a **canonical, consumers-all** manifest entry as of #601 — it was previously seeded exactly once by the bootstrap template-mirror and never again, so consumers ran a bootstrap-era ~8-step workflow against the full, kit-propagated `scripts/ci/`. Wave implications:

- **Atomicity:** a new `scripts/ci/check_*` and its `run:` step land in the same mergepath PR, so the check + its wiring arrive at each consumer in the SAME sync PR and `check_ci_scripts_wired` stays green at every sync point. The `scripts/ci/` kit and `repo_lint.yml` `requires:` each other (bidirectionally, asserted by `check_sync_manifest`), so neither can fan out without the other.
- **Canary expectation on the FIRST #601 wave:** the consumer's `lint` job jumps from the bootstrap-era ~8 executed checks to the full wired set (~50). Expect a much longer lint run and read the log accordingly: hub-only checks must show `SKIP (consumer checkout: ...)` lines, not failures. A FAIL on a consumer that traces to a missing hub-only file is a consumer-safety gap in that check — fix at the source (add the `scripts/sync-to-downstream.sh` marker SKIP guard), never in the consumer copy. The hub-only `tests/test_repo_lint_consumer_safety.sh` net models exactly this and should have caught it first.
- **Pre-wave annex migration (matchline, and any consumer with local repo_lint edits):** consumer-local steps and consumer-local `WIRED-EXEMPT` lines sitting in a consumer's `repo_lint.yml` copy get **clobbered** by the first canonical overwrite. BEFORE fanning out the first #601 wave to such a consumer, move its local wiring into the never-propagated `.github/workflows/repo_lint_local.yml` annex (a real workflow file — it runs its own steps — and `check_ci_scripts_wired` scans the union of both files). matchline is the known carrier of consumer-local check wiring; audit each consumer's `repo_lint.yml` against the mergepath copy before its wave slot.

## Maintenance

- **This doc is canonical.** The [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log) wiki page is the **monthly review log**, not a competing source — on a material order change the doc and the log are kept in lockstep (below). The log lived in [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492) until 2026-07-06, when it moved to the wiki so the recurring review no longer needs an always-open issue.
- **Monthly review** (`propagation-order-monthly-review`, 1st of each month): re-measure per-consumer risk signals — config divergence (overrides / unique `facts`), churn (recent PR/line volume), recent propagation failures, framework/visibility changes.
  - **No change** → append a dated `No change — order holds (YYYY-MM-DD)` entry to the wiki review log.
  - **Material change** → update the wiki review log *and* open a PR re-syncing the order table above, so the canonical doc never lags the review.
- The order is a **soft heuristic** — only shift it on a real, defensible signal; don't churn it cosmetically.
