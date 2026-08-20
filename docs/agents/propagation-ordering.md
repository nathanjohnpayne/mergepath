# Propagation wave ordering and change-handling

Status: **canonical, in-repo source of truth.** The order below is reviewed monthly; the dated review log lives on the repo wiki page [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log). See [§ Maintenance](#maintenance) for how the doc and that log stay in sync.

This is a **hub-only** doc — it governs how a canonical change is fanned out *from* mergepath *to* the 9 consumers via `scripts/sync-to-downstream.sh`. It is intentionally **not** in `.mergepath-sync.yml` (consumers don't run propagation waves). It complements [templated-propagation.md](templated-propagation.md) (the rendering engine) and the canary-first note in `.mergepath-sync.yml`.

Treat this as the default for every propagation wave unless a specific wave documents a reason to deviate in its own tracking issue.

## Default propagation order (riskiest → least, in pairs)

This is the **fan-out** order — the sequence in which consumer PRs are opened *after* the canary is green.

| Wave | Pair | Why this tier |
|---|---|---|
| **0 (most locally patched)** | `gaycruisebingo` (single) | Measured 2026-08-19: the only consumer carrying more than one hand-patched `scripts/ci/` kit file — `check_coderabbit_config` (a local paired-opt-out patch that names mergepath#911 as the pending upstream fix) and `check_workflow_parsers` (local `synthetic-uptime.yml` assertions). nathanpaynedotcom carries one such file, the other seven carry none. Those patches are exactly what a verbatim mirror clobbers, so its wave PR must be read for real local modifications vs missed upstream fixes (per the manifest's first-sync-risk note). The margin is two files out of the 110 kit paths each consumer actually holds — enough to order the fan-out, not enough to gate it. (Do not read that 110 as the manifest's own 114 path entries below; they are different sets that happen to sit near the same number.) **Superseded rationale, do not restore:** #741 placed it here in 2026-07 for carrying "the largest unaudited accumulated drift" after a bootstrap gap; that premise was true at enrolment and is now retired by measurement (see [§ Measuring tier membership](#measuring-tier-membership)). |
| **1 (riskiest)** | `overridebroadway` + `nathanpaynedotcom` | overridebroadway: historically special-cased ("CodeRabbit disabled" era), most bespoke `path_instructions`. nathanpaynedotcom: only consumer with a `tools.eslint.enabled: false` override (Astro) + highest churn. |
| **2** | `matchline` + `tadlockpsychiatry` | Both React+TS. matchline = well-trodden reference (deepest bot history); tadlockpsychiatry = quietest / least-observed. |
| **3** | `device-source-of-truth` + `friends-and-family-billing` | Recently touched by the ESLint-floor work. |
| **4 (safest)** | `device-platform-reporting` + `swipewatch` | Simplest surfaces; swipewatch is the documented ESLint canary. |

**Rationale:** the dominant failure mode for a wave is **usually** per-consumer idiosyncrasy (config divergence, local adaptations) rather than a uniform payload break. Front-loading the most divergent repos surfaces any check-vs-config interaction while attention is full; fixes land once at the source and later pairs become verification. Simplest repos last = cheap confirmation. (All 9 consumers are **public** — visibility was once an ordering factor, since a private repo's CI failures aren't readable without auth, but it no longer distinguishes the tiers; the axis is now divergence and churn.) "Usually" is doing real work in that sentence: it is a claim about the typical wave, not about every wave, and the canary rule below asks which mode dominates *this* change rather than assuming the usual one.

**Tier membership is a claim about current state, not a permanent label.** Every "Why this tier" cell above is a measurement with a date attached, and a consumer occupies its tier only for as long as that measurement still holds. A rationale that was true when it was written keeps being repeated long after the condition it described has been reconciled — the wave-0 entry is the worked example, and re-measuring is what retired it. Before relying on any row, check that its stated signal is still observable ([§ Measuring tier membership](#measuring-tier-membership)); a tier whose justification no longer reproduces is stale prose, not a standing fact about the repo.

## Canary selection (always do ONE first, chosen per wave)

**The canary is a role assigned per wave, never a standing title.** No consumer holds a permanent canary designation, and no phrase like "the propagation canary" identifies a repo on its own — the canary is whichever consumer best exercises the dominant risk of the change being propagated, and the answer legitimately differs from wave to wave. Two axis-specific labels do exist and are routinely misread as general appointments: `swipewatch` is the documented **ESLint** canary, and `gaycruisebingo` was the **first-sync** canary for its own enrolment backlog. Both are scoped to one axis. This restates what CONTEXT.md already defines: "the single consumer synced and driven green before any fan-out, **chosen by the dominant risk of the change**".

Before any fan-out, sync ONE consumer and get its PR green:

```bash
# --repos narrows the --sync-all mode to a single consumer (it is a filter, not a mode)
scripts/sync-to-downstream.sh --sync-all --repos <canary>
```

Pick the canary by the **dominant risk of this change**:

- **Uniform manifest/payload gap** (the #264 class — a missing test / fixture / script the kit hard-requires) → cheapest to catch on the **simplest public** repo (`swipewatch`).
- **Per-consumer config idiosyncrasy** → the **most-divergent** repo, read off the current table rather than from memory (`gaycruisebingo` / `nathanpaynedotcom` / `overridebroadway` as measured 2026-08-19), which then doubles as canary + first wave.
- **A consumer's own first sync** → that consumer, for that wave only. A repo whose enrolment backlog has never been reconciled is the highest-risk repo to exercise on the wave that reconciles it, because its wave PR is the first thing to distinguish real local modifications from missed upstream fixes. This is a per-wave reason like the others; it is **not** a licence to hold the fleet, and the fan-out is gated on the canary going green plus the wave audit, never on any particular repo's membership in a tier.

Only fan out (`--sync-all`) once the canary's `lint` is green **and the wave audit below has cleared (or is recorded as unavailable)**; the remaining consumers re-use the cleared invariant instead of each re-discovering the problem.

### Selection on record for the next wave (recorded 2026-08-19)

**Canary: `swipewatch`.** The dominant risk of the next wave is the **uniform manifest/payload gap** (#264 class), not per-consumer idiosyncrasy, so the first bullet above selects it. Four signals put the payload axis on top: all nine consumers are missing the **same four** kit checks (`check_branch_protection_audit`, `check_consumer_residue_safety`, `check_git_identity_hygiene`, `check_required_check_publisher`); `repo_lint.yml` wired those steps bare until #1044 added the missing-file soft-pass; the manifest carries 114 path entries (107 canonical, 5 kit, 2 templated) and `scripts/ci/` is a whole-directory kit entry, so all four arrive together and a bulk reconcile moves a large fraction of each consumer's managed surface in one PR; and #1041 is open on `.sync-overrides.yml` `skip_paths` bypassing the `requires:` closure. Meanwhile the axis this doc names as the *usual* dominant mode — per-consumer idiosyncrasy — is at its fleet-wide minimum: seven of nine consumers carry zero hand-patched kit files, and only one consumer (`device-platform-reporting`) retains any `skip_paths` at all, a single `eslint.config.js` entry that no manifest entry `requires:`. `swipewatch` is also tier 4 (safest) and the documented ESLint canary, so a payload gap surfaces there against the least local noise.

**This selection expires with this wave.** It is the output of the rule above applied to one change, not a promotion. The next wave re-runs the same question against its own dominant risk and records its own answer here, replacing this block.

## Wave audit (one scoped review per wave, #662)

A verified mirror carries nothing unreviewed: every line already passed review on its upstream mergepath PR, and the propagation lane byte-verifies the mirror. So the wave's external review runs **once**, against the canary PR, scoped to the canonical range that has not been audited before — instead of CodeRabbit + Codex re-reading the same bytes on all 9 consumers:

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
- **Residue is the other direction, and it is the one the strip-based net cannot see.** `tests/test_repo_lint_consumer_safety.sh` builds its consumer by *removing* a hand-written list from the hub tree, so it can only ever exercise a check against files that are **missing**. A consumer bootstrapped before a path was added to `BOOTSTRAP_MIRROR_EXCLUDES` carries that hub-only path **present** — gaycruisebingo (bootstrapped 2026-07-07) carries roughly 24 of them, including `tests/test_repo_lint_consumer_safety.sh` itself. A FAIL on a consumer that traces to a hub-only file being unexpectedly present is that class, and the hub-only `tests/test_consumer_residue_safety.sh` net is what models it. Consequence for anyone writing a new hub-only check: **the `scripts/sync-to-downstream.sh` marker test must come FIRST, before any test of the check's own hub-only artifacts.** The older both-absent idiom (wrapped test absent *and* marker absent → SKIP) reads an artifact a stale bootstrap may have left behind, so its consumer decision is not a function of what the manifest delivered. Marker-first keeps the protection the pair idiom was written for: with the wrapped test lost from the hub, the marker is still present, the guard does not skip, and the check hard-errors exactly as before. Two conventions make that net able to see your check at all, and it fails the PR if either is broken: name every hub-only file the gate reads by its **literal path** (`"$REPO_ROOT/tests/test_x.sh"`, never `"$TESTS_DIR/${STEM}.sh"`), and spell the skip **`<check name>: SKIP (consumer checkout: …)`** — the `SKIP: <reason>` form is for tooling skips inside `tests/`, and a consumer gate spelled that way is invisible to the verdict comparison.
- **Pre-wave annex migration (matchline, and any consumer with local repo_lint edits):** consumer-local steps and consumer-local `WIRED-EXEMPT` lines sitting in a consumer's `repo_lint.yml` copy get **clobbered** by the first canonical overwrite. BEFORE fanning out the first #601 wave to such a consumer, move its local wiring into the never-propagated `.github/workflows/repo_lint_local.yml` annex (a real workflow file — it runs its own steps — and `check_ci_scripts_wired` scans the union of both files). matchline is the known carrier of consumer-local check wiring; audit each consumer's `repo_lint.yml` against the mergepath copy before its wave slot.

## Measuring tier membership

The ordering table is a heuristic, but the signals behind it are observable, and a row is only worth trusting while its signal still reproduces. The cheapest full measurement compares each consumer's `scripts/ci/` kit tree against the hub's, by blob sha — identical sha means byte-identical content, so no file needs to be fetched:

```bash
# Hub side: every kit path and its blob sha at the ref you are propagating from.
git ls-tree -r origin/main scripts/ci/ | awk '{print $3"\t"$4}' | sort -k2

# Consumer side, per repo: the same list, one API call.
gh api "repos/nathanjohnpayne/<consumer>/git/trees/HEAD?recursive=1" \
  --jq '.tree[] | select(.type=="blob") | select(.path | startswith("scripts/ci/")) | .sha + "\t" + .path' | sort -k2
```

Comparing the two lists sorts every kit path into three buckets per consumer — byte-identical, differing, and absent — and it is the **shape** of those buckets, not the counts alone, that carries the signal:

- **Absent everywhere, same paths** → a uniform payload gap. The consumers are behind the hub together; nobody is individually divergent, and the canary should be the simplest repo.
- **Differing everywhere, same paths** → the same thing seen from the other side: the fleet is pinned to an older wave payload. Confirm by re-comparing against the last synced hub sha, where those paths should come back byte-identical.
- **Differing on a path only some consumers differ on** → the real per-consumer idiosyncrasy signal, and the only bucket that justifies a divergence-based tier. Read the diff before ranking on it: a hand-patched kit file (the thing a verbatim mirror clobbers) is a genuine wave risk, while a file that merely lags is not.

The 2026-08-19 measurement is what retired the wave-0 premise. Against hub `main`, all nine consumers produced the **identical** bucket signature — the same 4 kit paths absent, the same 23 differing, 87 byte-identical — so no consumer was individually divergent on the kit at all. Re-comparing against the last synced hub sha resolved the third bucket: seven consumers were byte-exact across all 110 kit paths, `nathanpaynedotcom` differed on one, and `gaycruisebingo` on two. That two-file margin is the entire measured basis for its position in the table, and it is a fraction of what "the largest unaudited accumulated drift" claimed.

## Maintenance

- **This doc is canonical.** The [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log) wiki page is the **monthly review log**, not a competing source — on a material order change the doc and the log are kept in lockstep (below). The log lived in [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492) until 2026-07-06, when it moved to the wiki so the recurring review no longer needs an always-open issue.
- **Monthly review** (`propagation-order-monthly-review`, 1st of each month): re-measure per-consumer risk signals — config divergence (overrides / unique `facts`), churn (recent PR/line volume), recent propagation failures, framework/visibility changes. Re-measure kit divergence per [§ Measuring tier membership](#measuring-tier-membership) rather than re-reading the table's own rationale, and **re-date every "Why this tier" cell you confirm** — an undated rationale is how a reconciled condition survives as a standing label.
  - **No change** → append a dated `No change — order holds (YYYY-MM-DD)` entry to the wiki review log.
  - **Material change** → update the wiki review log *and* open a PR re-syncing the order table above, so the canonical doc never lags the review.
- The order is a **soft heuristic** — only shift it on a real, defensible signal; don't churn it cosmetically.
