# Propagation wave ordering and change-handling

Status: **canonical, in-repo source of truth.** The order below is reviewed
monthly and tracked in [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492);
see [§ Maintenance](#maintenance) for how the doc and that issue stay in sync.

This is a **hub-only** doc — it governs how a canonical change is fanned out
*from* mergepath *to* the 8 consumers via `scripts/sync-to-downstream.sh`. It
is intentionally **not** in `.mergepath-sync.yml` (consumers don't run
propagation waves). It complements [templated-propagation.md](templated-propagation.md)
(the rendering engine) and the canary-first note in `.mergepath-sync.yml`.

Treat this as the default for every propagation wave unless a specific wave
documents a reason to deviate in its own tracking issue.

## Default propagation order (riskiest → least, in pairs)

This is the **fan-out** order — the sequence in which consumer PRs are opened
*after* the canary is green.

| Wave | Pair | Why this tier |
|---|---|---|
| **1 (riskiest)** | `overridebroadway` + `nathanpaynedotcom` | overridebroadway: private, historically special-cased ("CodeRabbit disabled" era), most bespoke `path_instructions`. nathanpaynedotcom: only consumer with a `tools.eslint.enabled: false` override (Astro) + highest churn. |
| **2** | `matchline` + `tadlockpsychiatry` | Both private React+TS. matchline = well-trodden reference (deepest bot history); tadlockpsychiatry = quietest / least-observed. |
| **3** | `device-source-of-truth` + `friends-and-family-billing` | Both public (failures readable without auth), recently touched by the ESLint-floor work. |
| **4 (safest)** | `device-platform-reporting` + `swipewatch` | Both public, simplest surfaces; swipewatch is the documented ESLint canary. |

**Rationale:** the dominant failure mode for a wave is **per-consumer
idiosyncrasy** (config divergence, local adaptations), not a uniform payload
break. Front-loading the private/divergent repos surfaces any check-vs-config
interaction while attention is full; fixes land once at the source and later
pairs become verification. Public/simple repos last = cheap confirmation.

## Canary selection (always do ONE first)

Before any fan-out, sync ONE consumer and get its PR green:

```bash
# --repos narrows the --sync-all mode to a single consumer (it is a filter, not a mode)
scripts/sync-to-downstream.sh --sync-all --repos <canary>
```

Pick the canary by the **dominant risk of this change**:

- **Uniform manifest/payload gap** (the #264 class — a missing test / fixture /
  script the kit hard-requires) → cheapest to catch on the **simplest public**
  repo (`swipewatch`).
- **Per-consumer config idiosyncrasy** → the **most-divergent** repo
  (`nathanpaynedotcom` / `overridebroadway`), which then doubles as canary +
  first wave.

Only fan out (`--sync-all`) once the canary's `lint` is green; the remaining
consumers re-use the cleared invariant instead of each re-discovering the
problem.

## Procedure when changes are required

> **Golden rule: a sync PR is a verbatim mirror — fix at the SOURCE (mergepath),
> never the consumer copy.** Editing the consumer copy breaks the
> propagation-lane fingerprint (`branch_prefix` + `author_identity` + *every
> changed file on manifest surface*), drops the PR to a full Phase-4 review, and
> gets clobbered on the next sync.

1. **Canary fails → STOP the fan-out.** Investigate in that one PR before
   opening any others. Most failures are upstream manifest gaps that the
   `requires:` closure would have caught.
2. **Decide where the fix belongs:**
   - **Canonical source (common case):** fix in mergepath (script / workflow /
     manifest), land it, re-propagate. *Example: #482 — a test/check lockstep
     closure gap fixed in `.mergepath-sync.yml`, not in any consumer.*
   - **Genuinely consumer-specific:** use `.sync-overrides.yml` on the dest
     path, or a per-consumer `facts:` / `exclusions:` entry (with a `reason:`)
     in `.mergepath-sync.yml`. Do not hand-edit the propagated file.
3. **Bot findings on a consumer sync PR** (they re-flag against canonical
   content, so they classify `canonical-coverage` — a mergepath concern):
   - **Real** → fix in mergepath, re-propagate; resolve the thread (reviewer PAT).
   - **False positive** → post a substantive rebuttal reply, *then* resolve.
   - **Real but non-blocking P2** → file a `post-review,observation` follow-up
     issue before resolving (don't silently drop).
   - Codex App threads on an amended HEAD won't auto-resolve → use the
     identity-checked `resolveReviewThread` mutation (see REVIEW_POLICY.md
     § Operation-to-Identity Matrix).
4. **Re-propagation mechanics:** after the source fix merges, re-run the sync.
   **Never rerun a stale-payload run** (close/redo it). Some consumers
   auto-merge on approval; bootstrap-gated repos need a human break-glass.

## repo_lint.yml travels in waves (#601)

`.github/workflows/repo_lint.yml` is a **canonical, consumers-all** manifest
entry as of #601 — it was previously seeded exactly once by the bootstrap
template-mirror and never again, so consumers ran a bootstrap-era ~8-step
workflow against the full, kit-propagated `scripts/ci/`. Wave implications:

- **Atomicity:** a new `scripts/ci/check_*` and its `run:` step land in the
  same mergepath PR, so the check + its wiring arrive at each consumer in the
  SAME sync PR and `check_ci_scripts_wired` stays green at every sync point.
  The `scripts/ci/` kit and `repo_lint.yml` `requires:` each other
  (bidirectionally, asserted by `check_sync_manifest`), so neither can fan
  out without the other.
- **Canary expectation on the FIRST #601 wave:** the consumer's `lint` job
  jumps from the bootstrap-era ~8 executed checks to the full wired set
  (~50). Expect a much longer lint run and read the log accordingly: hub-only
  checks must show `SKIP (consumer checkout: ...)` lines, not failures. A
  FAIL on a consumer that traces to a missing hub-only file is a
  consumer-safety gap in that check — fix at the source (add the
  `scripts/sync-to-downstream.sh` marker SKIP guard), never in the consumer
  copy. The hub-only `tests/test_repo_lint_consumer_safety.sh` net models
  exactly this and should have caught it first.
- **Pre-wave annex migration (matchline, and any consumer with local
  repo_lint edits):** consumer-local steps and consumer-local `WIRED-EXEMPT`
  lines sitting in a consumer's `repo_lint.yml` copy get **clobbered** by the
  first canonical overwrite. BEFORE fanning out the first #601 wave to such a
  consumer, move its local wiring into the never-propagated
  `.github/workflows/repo_lint_local.yml` annex (a real workflow file — it
  runs its own steps — and `check_ci_scripts_wired` scans the union of both
  files). matchline is the known carrier of consumer-local check wiring;
  audit each consumer's `repo_lint.yml` against the mergepath copy before its
  wave slot.

## Maintenance

- **This doc is canonical.** [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492)
  is the **monthly review log + tracker**, not a competing source — on a
  material order change the two are kept in lockstep (below).
- **Monthly review** (`propagation-order-monthly-review`, 1st of each month):
  re-measure per-consumer risk signals — config divergence (overrides / unique
  `facts`), churn (recent PR/line volume), recent propagation failures,
  framework/visibility changes.
  - **No change** → comment `no change — order holds (YYYY-MM-DD)` on #492.
  - **Material change** → update #492 *and* open a PR re-syncing the order
    table above, so the canonical doc never lags the review.
- The order is a **soft heuristic** — only shift it on a real, defensible
  signal; don't churn it cosmetically.
