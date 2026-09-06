# Propagation wave ordering and change-handling

Status: **canonical, in-repo source of truth.** The order below is reviewed monthly; the dated review log lives on the repo wiki page [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log). See [§ Maintenance](#maintenance) for how the doc and that log stay in sync.

This is a **hub-only** doc — it governs how a canonical change is fanned out *from* mergepath *to* the 7 consumers via `scripts/sync-to-downstream.sh`. It is intentionally **not** in `.mergepath-sync.yml` (consumers don't run propagation waves). It complements [templated-propagation.md](templated-propagation.md) (the rendering engine) and the canary-first note in `.mergepath-sync.yml`.

Treat this as the default for every propagation wave unless a specific wave documents a reason to deviate in its own tracking issue.

## Default propagation order (riskiest → least)

This is the **fan-out** order — the sequence in which consumer PRs are opened *after* the canary is green.

| Wave | Pair | Why this tier |
|---|---|---|
| **0 (riskiest—re-based 2026-09-01)** | `fiveacross` (single) | **Re-based on measured signals; the earlier first-sync/conservatism rationale is retired.** The 2026-08-30 row held this position provisionally and on an explicit condition: fold it into tier 1 if the next measurement did not distinguish the repo. The 2026-09-01 measurement does distinguish it, on three axes that are not the spent one. **Churn:** 191 locally-authored PRs and +136,895/−12,577 lines over 2026-08-01→2026-09-01—1.4× the next consumer by PR count, 3.7× by additions, and roughly 9× the third-ranked repo. **Bot posture:** it is the only consumer with CodeRabbit fully disabled, since 2026-08-04—`reviews.auto_review.enabled: false` in its `.coderabbit.yml` *and* `coderabbit.enabled: false` in its `.github/review-policy.yml`, the paired keys that stop the App reviewing and stop the agent waiting. **Residue:** it carries far more hub-only bootstrap residue than any other consumer, none of which the manifest audit can see. Measured 2026-09-01 against hub `e55fcbc`: of the 501 paths the hub tracks, `fiveacross` holds 442 against 339–352 for the other seven, and **90** of those are held by `fiveacross` and by no other consumer at all—`matchline` is sole carrier of 1, and the remaining six of none. The 90 span `scripts/bootstrap/`, the `tests/test_bootstrap_*` suites, the audit data under `docs/audits/data/`, and four hub-only `docs/agents/` files including this one. That is the *sole-carrier* count and is deliberately not the same set as the "roughly 24" cited in [§ repo_lint.yml travels in waves](#repo_lintyml-travels-in-waves-601), which counts only paths added to `BOOTSTRAP_MIRROR_EXCLUDES` after its 2026-07-07 bootstrap; the two answer different questions, so read each with its definition rather than as a contradiction. Its tree is also the fleet's largest at 1,424 files against a next-highest 753. **What is now spent:** the `scripts/ci/` kit signal. Its `.sync-overrides.yml` survives but is empty (`version: 1` only), and the 2026-09-01 kit measurement puts it byte-identical to the hub like every other consumer. It holds wave 0 on churn, bot posture and residue—not on kit divergence, and not on a pending first sync. **It cannot supply the advisory CodeRabbit pass a canary normally carries**, which is a statement about that leg and not a bar on the role: where a wave's dominant risk is specific to `fiveacross`—an interaction with its bootstrap residue, say—it still leads, with the advisory leg recorded unavailable. See [§ Wave audit](#wave-audit-one-scoped-review-per-wave-662). |
| **1 (riskiest of the steady state)** | `overridebroadway` + `nathanpaynedotcom` | Both confirmed 2026-09-01. overridebroadway: a Next.js app (`next` + `eslint-config-next`) still carrying the `create-next-app` `eslint.config.mjs` alongside the manifest-delivered CJS `eslint.config.js`; with no `"type"` in its `package.json` the `.js` shadows the `.mjs` under ESLint v9 flat-config resolution, so its Next rules are installed but never enforced, and its manifest `facts:` do not record Next at all. 5 bespoke `path_instructions`. nathanpaynedotcom: still the only consumer carrying a `tools.eslint.enabled: false` override (the #426 Astro-parser workaround), the only Astro consumer, and second-highest on churn (135 locally-authored PRs, +36,869 lines in the window). |
| **2** | `matchline` + `tadlockpsychiatry` | Both confirmed 2026-09-01. Both React+TS. matchline = well-trodden reference (deepest bot history); it carries the `repo_lint_local.yml` annex and 3 consumer-only `scripts/ci/` files, both structurally contained—the annex is never propagated, and a consumer-only file is never overwritten by the mirror. tadlockpsychiatry = quietest / least-observed (9 locally-authored PRs, the lowest non-zero count in the window). The 2026-08 review flagged a matchline/nathanpaynedotcom churn inversion to re-examine; it did not persist (matchline 15 against nathanpaynedotcom's 135), so this pairing holds. |
| **3** | `friends-and-family-billing` (single) | Confirmed 2026-09-01. Recently touched by the ESLint-floor work; divergence still entirely template-folded (`testing: vitest`, `jsx_in_js: true`), no bespoke override. Paired with `device-source-of-truth` until 2026-09-05, when that repo went dormant — Actions disabled, dropped as a consumer — which also removed the fleet's only non-public consumer. |
| **4 (safest)** | `swipewatch` (single) | Confirmed 2026-09-01. Simplest surface; swipewatch is the documented ESLint canary, carries `frameworks: []`, and recorded zero locally-authored PRs in the window. Paired with `device-platform-reporting` until 2026-08-26, when that repo was archived and dropped as a consumer. |

**Rationale:** the dominant failure mode for a wave is **usually** per-consumer idiosyncrasy (config divergence, local adaptations) rather than a uniform payload break. Front-loading the most divergent repos surfaces any check-vs-config interaction while attention is full; fixes land once at the source and later pairs become verification. Simplest repos last = cheap confirmation. (Visibility was once an ordering factor, since a private repo's CI failures aren't readable without auth. It stopped distinguishing the tiers while every consumer was public, partially returned on 2026-09-01 when `device-source-of-truth` became the only private consumer, and stopped applying again on 2026-09-05 when that repo was dropped and the fleet returned to uniformly public. Either way it bore on canary readability rather than on fan-out risk, so the ranking axis remains divergence and churn.) "Usually" is doing real work in that sentence: it is a claim about the typical wave, not about every wave, and the canary rule below asks which mode dominates *this* change rather than assuming the usual one.

**Tier membership is a claim about current state, not a permanent label.** Every "Why this tier" cell above **must** carry a date, and a consumer occupies its tier only for as long as its stated signal still reproduces. Every row now meets that requirement: all five carry a 2026-09-01 measurement, which is the first pass in which the tier-1 config signals were measured rather than inherited. Read a row that has lost its date in a later edit as an inherited claim awaiting re-measurement, never as a freshly verified one. A rationale that was true when it was written keeps being repeated long after the condition it described has been reconciled, and re-measuring is the only thing that tells the two apart. Before relying on any row, check that its stated signal is still observable ([§ Measuring tier membership](#measuring-tier-membership)); a tier whose justification no longer reproduces is stale prose, not a standing fact about the repo.

## Canary selection (always do ONE first, chosen per wave)

> **Consumer rename (2026-08-27).** `nathanjohnpayne/gaycruisebingo` became `nathanjohnpayne/fiveacross`. Every reference below uses the new slug, including in dated measurements and issue links that predate the rename — those records are unchanged in substance and the old slug still redirects. The new name is what `--repos` must be given: `sync-to-downstream.sh`'s `in_repo_filter` exact-matches `.consumers[].name` in `.mergepath-sync.yml`, so the old slug now selects zero consumers and exits successfully having opened no PRs.

**The canary is a role assigned per wave, never a standing title.** No consumer holds a permanent canary designation, and no phrase like "the propagation canary" identifies a repo on its own — the canary is whichever consumer best exercises the dominant risk of the change being propagated, and the answer legitimately differs from wave to wave. Two axis-specific labels do exist and are routinely misread as general appointments: `swipewatch` is the documented **ESLint** canary, and `fiveacross` was the **first-sync** canary for its own enrolment backlog. Both are scoped to one axis. This restates what CONTEXT.md already defines: "the single consumer synced and driven green before any fan-out, **chosen by the dominant risk of the change**".

Before any fan-out, sync ONE consumer and get its PR green:

```bash
# --repos narrows the --sync-all mode to a single consumer (it is a filter, not a mode)
scripts/sync-to-downstream.sh --sync-all --repos <canary>
```

Pick the canary by the **dominant risk of this change**:

- **Uniform manifest/payload gap** (the #264 class — a missing test / fixture / script the kit hard-requires) → cheapest to catch on the **simplest public** repo (`swipewatch`).
- **Per-consumer config idiosyncrasy** → the **most-divergent** repo, read off the current table rather than from memory, which then doubles as canary + first wave. Divergence is not one signal, and as of 2026-09-01 the two that matter point in different directions. **The `scripts/ci/` kit axis is exhausted:** that measurement puts all eight consumers byte-identical to the hub on all 124 kit paths, with no path carrying more than one distinct tuple across the fleet, so kit divergence separates nobody and cannot pick a canary for a kit change any more. **The off-manifest config axis is now measured and does separate them:** `nathanpaynedotcom` carries the sole `tools.eslint.enabled: false` override, `overridebroadway` carries a live `eslint.config.mjs`/`eslint.config.js` shadowing conflict plus 5 bespoke `path_instructions`, and `fiveacross` carries CodeRabbit disabled outright. So pick the most-divergent repo off the config signal, read from the dated table above rather than from memory, and note that `fiveacross` cannot supply the advisory CodeRabbit leg, on the separate ground recorded in [§ Wave audit](#wave-audit-one-scoped-review-per-wave-662)—a leg to record as unavailable, not a reason to pass over the repo when its own risk is what the wave must exercise.
- **A consumer's own first sync** → that consumer, for that wave only. A repo whose enrolment backlog has never been reconciled is the highest-risk repo to exercise on the wave that reconciles it, because its wave PR is the first thing to distinguish real local modifications from missed upstream fixes. This is a per-wave reason like the others; it is **not** a licence to hold the fleet, and the fan-out is gated on the canary going green plus the wave audit, never on any particular repo's membership in a tier.

Only fan out (`--sync-all`) once the canary's `lint` is green **and the wave audit below has cleared (or is recorded as unavailable)**; the remaining consumers re-use the cleared invariant instead of each re-discovering the problem.

### Selection on record for the next wave (recorded 2026-08-30)

**Canary: `swipewatch`, alone.** The **uniform payload** bullet selects it. This wave carries exactly two canonical paths — `.github/workflows/pr-review-policy.yml` and `tests/test_pr_body_contract_parity.sh`, from mergepath#1139 — and both are byte-identical across every consumer today (blobs `c04b0e52` and `6970d6a7` on all 8, measured 2026-08-30 against hub `2e255194`). There is no per-consumer divergence on the paths this wave touches, so the idiosyncrasy axis has nothing to bite on and the cheapest repo to surface a uniform break is the simplest one.

**The dominant failure mode for this change is uniform, and it is already evidenced.** The wave at hub `63795db` failed on all eight consumers for one reason: the parity suite's Phase 4b probes assumed the automation was enabled, and no consumer carries a `phase_4b` block, so `phase-4b-review.sh` exited 5 on the disabled path and the assertion misread that as a contract failure. Green on the hub, red everywhere else. That is the #264 class exactly—a payload that exercises a path the hub has and consumers do not—and it reproduced identically on every repo rather than on the divergent ones. mergepath#1153 fixed it by driving the probes through the documented `--force-enabled` override, and the corrective wave at hub `0e203d0` carried that fix outward and merged on all eight consumers on 2026-08-29. **So this wave is not the first to carry the fix**, and an earlier round of this block said it was, citing `0e203d0` as the failing head when it is the fixing one. The uniform break is already closed; what the canary is being asked to prove here is that it stays closed over this wave's payload, which is confirmation rather than first evidence.

**Why not the previous selection.** The 2026-08-20 block named `fiveacross` on the first-sync bullet: its `.sync-overrides.yml` had skipped the whole `scripts/ci/` kit until fiveacross#1011 lifted it, making the next wave its first delivery of that directory. That reason is spent — `fiveacross` now holds the kit (verified 2026-08-30: it carries the #1148 EPIPE conversions like every other consumer), so this wave is not its first sync of anything. The prerequisites recorded against that selection (#845's staged rollout, #1055's migration of its consumer-only `check_workflow_parsers` assertions) belong to that wave's payload, not this one; neither `scripts/ci/` nor `check_workflow_parsers` is in this wave's drift.

**The bootstrap hazard this wave would otherwise carry is already closed, by ordering rather than by the canary.** `pr-review-policy.yml` here calls `scripts/validate-pr-body.sh --self-review-only`, and the gate loads that validator from the consumer's **default branch**. Delivering the workflow to a consumer whose default branch lacked the flag would fail the required Self-Review job on every PR there. The flag was propagated ahead of it in its own wave and confirmed present on all nine repos before this wave opened. Do not reorder these two: the workflow must never lead the validator.

**This selection expires with this wave.**

## Wave audit (one scoped review per wave, #662)

A verified mirror carries nothing unreviewed: every line already passed review on its upstream mergepath PR, and the propagation lane byte-verifies the mirror. So the wave's external review runs **once**, against the canary PR, scoped to the canonical range that has not been audited before — instead of CodeRabbit + Codex re-reading the same bytes on all 7 consumers:

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

The canary keeps the full advisory CodeRabbit pass—open it **without** `--coderabbit-ignore`. **`fiveacross` cannot satisfy that requirement** (measured 2026-09-01): CodeRabbit is disabled there on both the `.coderabbit.yml` and `.github/review-policy.yml` keys, so a wave canaried on it receives no advisory pass at all rather than an empty-but-real one. Prefer a different canary when the wave's risk is not specific to `fiveacross`; when it is, canary `fiveacross` anyway and record the advisory leg as unavailable in the wave tracker. Either way the leg is recorded, never assumed.

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
- **Residue is the other direction, and the strip-based net sees only part of it.** `tests/test_repo_lint_consumer_safety.sh` models three consumer states, not one (#1069). `CONSUMER_ABSENT` **removes** a path, which is the only state it modelled before that change. `CONSUMER_RESIDUE_PRESENT` **keeps** a hub-only path an older bootstrap left behind. `CONSUMER_FROZEN_CONTENT` keeps a path that every consumer has but that no manifest entry updates, and **replaces its contents** with a bootstrap-era stand-in — the state that produced the `REVIEW_POLICY.md` half of #1068, where a check asserted hub-current prose against a snapshot frozen at enrolment. A frozen stand-in must carry BOTH shapes an assertion can read: it must lack the current text a check requires AND still carry the obsolete text a check forbids, or the negative half passes vacuously. A consumer bootstrapped before a path was added to `BOOTSTRAP_MIRROR_EXCLUDES` carries that hub-only path **present** — fiveacross (bootstrapped 2026-07-07) carries roughly 24 of them, including `tests/test_repo_lint_consumer_safety.sh` itself. A FAIL on a consumer that traces to a hub-only file being unexpectedly present is that class, and the hub-only `tests/test_consumer_residue_safety.sh` net is what models it. Consequence for anyone writing a new hub-only check: **the `scripts/sync-to-downstream.sh` marker test must come FIRST, before any test of the check's own hub-only artifacts.** The older both-absent idiom (wrapped test absent *and* marker absent → SKIP) reads an artifact a stale bootstrap may have left behind, so its consumer decision is not a function of what the manifest delivered. Marker-first keeps the protection the pair idiom was written for: with the wrapped test lost from the hub, the marker is still present, the guard does not skip, and the check hard-errors exactly as before. Two conventions make that net able to see your check at all, and it fails the PR if either is broken: name every hub-only file the gate reads by its **literal path** (`"$REPO_ROOT/tests/test_x.sh"`, never `"$TESTS_DIR/${STEM}.sh"`), and spell the skip **`<check name>: SKIP (consumer checkout: …)`** — the `SKIP: <reason>` form is for tooling skips inside `tests/`, and a consumer gate spelled that way is invisible to the verdict comparison.
- **Pre-wave annex migration (matchline, and any consumer with local repo_lint edits):** consumer-local steps and consumer-local `WIRED-EXEMPT` lines sitting in a consumer's `repo_lint.yml` copy get **clobbered** by the first canonical overwrite. BEFORE fanning out the first #601 wave to such a consumer, move its local wiring into the never-propagated `.github/workflows/repo_lint_local.yml` annex (a real workflow file — it runs its own steps — and `check_ci_scripts_wired` scans the union of both files). matchline is the known carrier of consumer-local check wiring; audit each consumer's `repo_lint.yml` against the mergepath copy before its wave slot.

## Measuring tier membership

The ordering table is a heuristic, but the signals behind it are observable, and a row is only worth trusting while its signal still reproduces. The cheapest full measurement compares each consumer's `scripts/ci/` kit tree against the hub's without fetching a single file, by comparing the **git tree entry** — `mode`, `type` and object id — exactly as `scripts/workflow/verify-propagation-pr.sh` does. Compare the whole tuple, not the object id alone: an exec-bit flip leaves the blob identical while the propagation verifier rejects it, so a blob-only comparison reports parity on drift the wave will fail on. The kit is genuinely mixed — at `main` (`9943173ca2b532359d619ffeadda93daf9f9cf43`) it is 68 `100755` entries and 47 `100644`, 115 blobs in total — so "they're all executable anyway" is not available as a shortcut. That total is the one every measurement below is quoted against, and it moves whenever a check is added: the 67/47 split recorded here before 2026-08-20 predated #1018 adding `check_review_feedback_accounting`. Re-read it at the commit you are actually propagating FROM rather than trusting the number written here, which is exactly the discipline the rest of this section asks for.

Pin both sides to an **immutable ref**. `origin/main` and a consumer's `HEAD` both move, so a measurement taken against them is not re-derivable a day later — which matters here, because the point of the exercise is to check whether a dated claim still holds. Resolve the refs first, then measure:

```bash
HUB_REF=<hub sha>          # the commit you are propagating FROM, not origin/main
CONSUMER_REF=<sha>         # that consumer's commit, not HEAD

set -o pipefail   # REQUIRED, see the note under the consumer command below
TAB=$(printf '\t')

# Hub side: mode, type, oid and path for every kit entry at HUB_REF.
# `git ls-tree` emits `<mode> <type> <oid><TAB><path>` -- two SPACES then a
# TAB -- while the API expression below emits four TAB-separated fields.
# Normalise the first two spaces to tabs so both sides are the same four
# fields; comparing the raw forms marks every single entry as differing.
# Substitute the literal `$TAB` computed above, never a `\t` escape: POSIX
# leaves a backslash before an unspecified replacement character UNDEFINED,
# and a sed that passes it through emits a literal `t`, which silently
# recreates the very mismatch this normalisation exists to remove.
git ls-tree -r "$HUB_REF" scripts/ci/ \
  | sed "s/ /$TAB/; s/ /$TAB/" | sort -t"$TAB" -k4

# Consumer side, per repo: the same tuple, one API call.
# `.truncated` FIRST: the recursive Trees API silently caps a large tree and
# still returns 200, so filtering `.tree` without checking it measures a
# partial listing as though it were the whole one -- every capped-off path
# reads as ABSENT, which is the bucket that means "uniform payload gap".
# Fail closed instead; the fleet's trees are far under the cap today, and
# that is a fact about today.
#
# `set -o pipefail` above is LOAD-BEARING and not hygiene. Without it the
# nonzero status jq raises on a truncated response is swallowed by the
# trailing `sort`, the pipeline exits 0, and the redirect leaves an EMPTY
# kit_<consumer>.tsv -- which the comparison then reads as every kit path
# absent, i.e. the exact "uniform payload gap" verdict the check exists to
# prevent. Measured: without pipefail the pipeline exits 0 with 0 lines;
# with it, 5.
gh api "repos/nathanjohnpayne/<consumer>/git/trees/$CONSUMER_REF?recursive=1" \
  --jq 'if .truncated then error("truncated tree response — refusing to measure a partial listing") else . end
        | .tree[] | select(.type=="blob") | select(.path | startswith("scripts/ci/"))
        | [.mode, .type, .sha, .path] | @tsv' | sort -t"$TAB" -k4
```

**Resolving the last synced hub sha** (the `HUB_REF` for a "has this consumer drifted since its last wave?" comparison): `scripts/sync-to-downstream.sh --sync-all` records it in three places, and only one of them is abbreviated. The **branch name** `mergepath-sync/sync-all-<sha7>` carries 7 characters. The **sync commit message** carries a `Source: https://github.com/nathanjohnpayne/mergepath/commit/<sha>` trailer with the full sha. The **PR body's first line** reads `Bulk sync to [mergepath@<sha7>](…/commit/<sha>)`, whose link target is also the full sha. Prefer either full-sha form over the branch name. Note the `Source:` trailer is on the COMMIT, not in the PR body — grepping the body for it returns nothing (measured across 92 sync PRs on three consumers). Read it off that consumer's most recent merged sync PR rather than assuming the fleet shares one; they usually do. A consumer that reached parity through the bootstrap template mirror has **no** sync PR at all. For a pre-#1056 bootstrap, its commit is **not** usable as `HUB_REF` either: that sha belongs to the consumer repository, so `git ls-tree -r "$HUB_REF"` in a mergepath checkout cannot resolve it. See below for the post-#1056 exception.

**For such a repo there is no hub sha to recover, and this document previously claimed there was.** `scripts/bootstrap/template-mirror.sh` commits the mirrored tree as `Initial commit (bootstrapped from mergepath)` and records no source sha anywhere — not in that message, not in the mergepath-side loop PR body, and nowhere in the logged commands (verified against `fiveacross`'s `a2965a93`). Sending an operator to look for it wastes the lookup and, worse, invites reaching for a *plausible* mergepath commit by date, which silently produces a baseline the mirror never used.

So, for a pre-#1056 bootstrap: **drop the hub baseline and use the consumer-to-consumer comparison below**, which needs no hub ref and answers the divergence question directly.

A consumer bootstrapped by a `template-mirror.sh` that already carries the #1056 fix DOES have a recoverable `HUB_REF` — PROVIDED that bootstrap's `source_root` passed every canonical-source check the fix requires (an exact git top level, an origin naming canonical mergepath, HEAD contained in that repo's own remote history, and a clean working tree; see `specs/bootstrap_source_attribution.md` for the full contract). A source_root failing any one of those still gets the pre-#1056 generic subject with no `Source:` trailer, the same as an unreadable one always did. When it succeeds, the sha is recorded in the same two places `scripts/sync-to-downstream.sh` writes it on every sync PR: the bootstrap commit's subject reads `Initial commit (bootstrapped from mergepath@<sha7>)`, and its body carries a `Source: https://github.com/nathanjohnpayne/mergepath/commit/<sha>` trailer with the full sha. Read either off that consumer's single initial commit — there is no sync PR to check instead, since a bootstrapped repo has none.

Comparing the two lists sorts every kit path into three buckets per consumer — byte-identical, differing, and absent. **Those buckets are measured against the hub, so they cannot establish uniformity across consumers, and no amount of agreement between their shapes will.** A path lands in `differing` because the consumer's entry is not the hub's; two consumers can both put the same path in `differing` while carrying entirely different entries there. So a bucket comparison answers "how far is each consumer from the hub?" and never "do the consumers agree with each other?" — and the second question is the one a divergence-based tier actually rests on. Answer it directly, by comparing the consumers' own entries to **each other** (or to their immutable last-synced baselines), before ranking anything:

```bash
# Save each consumer's normalised listing above as kit_<consumer>.tsv, then:
# how many DISTINCT versions of each kit path exist across the fleet?
# A count above 1 is real per-consumer divergence.  A count of 1 means the
# fleet agrees with itself and the path is merely lagging the hub together.
for c in <consumer> ...; do
  # KEY on the whole tuple, not the oid: this section rejects a blob-only
  # comparison two paragraphs up, and a per-path key that drops mode and type
  # would miss exactly the exec-bit drift the propagation verifier fails on.
  # Keep the consumer beside that tuple so the saved report identifies which
  # repo owns each divergent version instead of only counting the versions.
  awk -v consumer="$c" -F"$TAB" \
    '{print $4 "\t" consumer "\t" $1 "," $2 "," $3}' "kit_$c.tsv"
done | tee consumer-kit-entries.tsv \
  | cut -f1,3 | sort -u | cut -f1 | uniq -c | awk '$1 > 1 {print $1, $2}'
```

On this fleet the tuple key and an oid-only key currently return the same counts, because no consumer carries mode-only drift on any kit path. That is a measured fact about today, not a licence to simplify the key.

That reports only paths every consumer HOLDS. A path some consumers lack is divergence too, so also diff the path sets — `cut -f4 kit_<a>.tsv` against `cut -f4 kit_<b>.tsv` — which is what surfaces a consumer carrying kit files the hub does not ship at all.

With that answered, the bucket shapes are still worth reading — but as a description of fleet-vs-hub lag, which is what they are:

Every one of these shapes is **indeterminate on its own** and becomes a verdict only after the consumer-to-consumer comparison above has been run. Read them as hypotheses to confirm, never as classifications:

- **Absent everywhere, same paths** → *consistent with* a uniform payload gap. Absence is the one shape that carries its own content — a path nobody holds cannot differ between holders — so this is the shape closest to conclusive. Even so, confirm no consumer holds it before treating the fleet as uniform on it.
- **Differing everywhere, same paths** → **indeterminate, and the trap this document was built on.** It is consistent with the fleet being pinned to one older payload, and equally consistent with several consumers carrying different hand-patched versions. This exact shape concealed divergence on two paths, represented by five distinct path/mode/type/OID tuples, which is what produced the wrong canary. Never read it as uniform without comparing the consumers' own entries; re-comparing against the last synced hub sha is a supporting check, not a substitute.
- **Differing on a path only some consumers differ on** → per-consumer idiosyncrasy, visible directly in the bucket shape. It is not the ONLY bucket that can justify a divergence-based tier — the all-differing bucket can too, once the consumer-to-consumer comparison shows the versions disagree, which is exactly what happened on this fleet. Read the diff before ranking on it either way: a hand-patched kit file (the thing a verbatim mirror clobbers) is a genuine wave risk, while a file that merely lags is not.

**Consumer refs behind the 2026-08-20 measurement.** Recorded so the result stays re-derivable once these advance, which is the same immutable-ref requirement stated above — a dated claim naming only the hub half is reproducible only until the first consumer moves:

| consumer | ref | | consumer | ref |
|---|---|---|---|---|
| `overridebroadway` | `a90fb62fb55d0eed4be806811156ed3f639d819b` | | `friends-and-family-billing` | `d1ece75b66bec8cb0a991cd7820b3d94ce54d9b2` |
| `nathanpaynedotcom` | `d07f7371a7d0ceaa89658fcbfb41840b22c71c11` | | `device-platform-reporting` | `9076e165a3c9f0c36d8f37bd769752e93232998f` |
| `matchline` | `5873afcfe33003ac96ec6312060a47155b6b67dc` | | `swipewatch` | `269d958be12a68d7749e317fc20befb22eb8b23b` |
| `tadlockpsychiatry` | `e813d23381ee71e18fa442d2f4bb29206e964659` | | `fiveacross` | `767341cc996382e4914225a89467f94d34409eca` |
| `device-source-of-truth` | `6e9a6985e45f2b3baebf14674b111317378fb6f0` | | | |

**The 2026-08-20 measurement, and the 2026-08-19 error it corrects.** Against hub `9943173ca2b532359d619ffeadda93daf9f9cf43`, all nine consumers produce the **identical hub-relative** bucket signature: 87 byte-identical, 23 differing, 5 absent, the same paths in each bucket for every consumer. Those counts cover the 115 hub-known kit paths; each consumer holds 110 of them, and `matchline` separately holds three consumer-only kit files. An earlier round of this PR read that as proof that no consumer was individually divergent, retired the wave-0 tier on it, and recorded `swipewatch` as the canary. That inference is invalid, and it is worth keeping here because the measurement it rests on is correct and the conclusion still does not follow: the buckets are computed against the **hub**, so identical signatures mean the nine consumers are equally far from the hub, not that they carry the same bytes. Comparing the consumers to **each other** shows two kit paths on which they do not agree, producing five distinct path/mode/type/OID tuples — `check_coderabbit_config` carries two distinct versions across the fleet and `check_workflow_parsers` three, with `fiveacross` the sole outlier on both and `nathanpaynedotcom` an outlier on one, while `matchline` carries three `scripts/ci/` files the hub does not ship at all. Seven consumers are outliers on nothing. Read that ranking with the reclassification above in hand: divergence measured by object id is not the same as **clobber risk**, and `fiveacross`'s `check_coderabbit_config` difference is a patch superseded by canonical #911 that the mirror will correctly replace. On clobber risk the two are tied at one file each — which is why the canary is chosen on the whole-kit first sync rather than on this count. So the per-consumer idiosyncrasy signal was present the whole time and the bucket comparison was structurally unable to see it. Re-run with the full mode+type+oid tuple rather than the object id alone, every number above is unchanged and no consumer carries mode-only drift on any kit path — so the exec-bit hazard the tuple comparison exists to catch is a real failure mode that is simply not firing on this fleet today, which is a thing worth re-checking rather than assuming.

**The 2026-09-01 measurement: the kit axis is fully reconciled and no longer ranks anything.** Against hub `e55fcbc873d15c5d14ee45822058e0df52a2fddf` the kit is 124 blobs (75 `100755`, 49 `100644`)—up from the 115 recorded at 2026-08-20, which is the re-read-at-the-propagating-commit discipline this section asks for, not a discrepancy. All eight consumers return the identical hub-relative signature: **124 byte-identical, 0 differing, 0 absent**, on the full `mode`+`type`+`oid` tuple. The consumer-to-consumer comparison returns **no path carrying more than one distinct tuple**, so the fleet agrees with itself as well as with the hub. The two divergent paths recorded on 2026-08-20—`check_coderabbit_config` and `check_workflow_parsers`, five distinct tuples between them—are both gone, reconciled by the `0e203d0` and `2e255194` waves. **Consequence for the table:** clobber risk on the kit axis is now zero fleet-wide, so kit divergence distinguishes no consumer and cannot justify any tier. The wave-0 row was re-based onto churn, bot posture and residue accordingly; tier 1 rests on off-manifest config signals, which the kit measurement never covered in either direction.

Only path-set differences remain, and they are the class the mirror never touches: `matchline` carries 3 consumer-only kit files (`check_fixture_match_ids`, `check_no_other_skill_normalization`, `check_prompt_schema_pairs`) and `fiveacross` 1 (`check_synthetic_uptime_parsers`). No consumer is missing a hub-shipped kit path. Read these under the same reclassification as before—a consumer-only file is not overwritten by a verbatim mirror and is not covered by the wave audit either, so it belongs to that consumer's own CI and to the pre-wave annex inspection, not to this ranking.

**Consumer refs behind the 2026-09-01 measurement.**

| consumer | ref | | consumer | ref |
|---|---|---|---|---|
| `overridebroadway` | `b9bfe04cd4e2996bd6b9aef75f9b91a071a1ce0a` | | `friends-and-family-billing` | `fe5f035ba1ba17afa2da394e28f9309b6c4f41b2` |
| `nathanpaynedotcom` | `029b5cef3baa8fb31a87adb8772a7fb26b9da55b` | | `swipewatch` | `1f5b43c58fc4cf856216506c0c68f8524c1c638d` |
| `matchline` | `51c72a6d984fbb7cd93843f53452592967f98122` | | `tadlockpsychiatry` | `212341885bc2dd9e68149eb5c050bcdd7b694baf` |
| `device-source-of-truth` | `a49eaa0cc7e06fc509d5ca26ea60b57a796676b4` | | `fiveacross` | `8a651e8f6518568925d8e426e215a482e3939226` |

**One measurement hazard worth recording, because it fails silently.** The comparison loops in this section iterate a consumer list. Under `zsh` an unquoted `$CONSUMERS` does **not** word-split, so `for c in $CONSUMERS` binds the whole list as a single name, every `kit_<name>.tsv` read misses, and the consumer-to-consumer step prints no divergent paths—which is indistinguishable from a clean fleet. Iterate a literal list or read the names on stdin, and sanity-check that the per-consumer entry counts are non-zero before believing a zero-divergence result.

`matchline`'s three extra files are a different risk class again, and should not be added to the same ranking. A hand-patched copy of a file the hub **does** ship is what a verbatim mirror overwrites, which is the wave risk this tier ordering is about. A consumer-local file the hub does not ship is not overwritten by the mirror at all — and it is **not** covered by the wave audit either, which is worth stating because assuming otherwise would skip the only checks that can see it: `scripts/wave-audit.sh` builds its review diff from mergepath manifest source paths over the canonical range, so a file the hub does not ship is absent from that diff by construction. Consumer-only extras belong to that consumer's own CI and to the pre-wave annex inspection above, which is where matchline — the known carrier of consumer-local check wiring — is already handled.

## Maintenance

- **This doc is canonical.** The [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log) wiki page is the **monthly review log**, not a competing source — on a material order change the doc and the log are kept in lockstep (below). The log lived in [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492) until 2026-07-06, when it moved to the wiki so the recurring review no longer needs an always-open issue.
- **Monthly review** (`propagation-order-monthly-review`, 1st of each month): re-measure per-consumer risk signals — config divergence (overrides / unique `facts`), churn (recent PR/line volume), recent propagation failures, framework/visibility changes. Re-measure kit divergence per [§ Measuring tier membership](#measuring-tier-membership) rather than re-reading the table's own rationale, and **re-date every "Why this tier" cell you confirm** — an undated rationale is how a reconciled condition survives as a standing label.
  - **No change** → append a dated `No change — order holds (YYYY-MM-DD)` entry to the wiki review log.
  - **Material change** → update the wiki review log *and* open a PR re-syncing the order table above, so the canonical doc never lags the review.
- The order is a **soft heuristic** — only shift it on a real, defensible signal; don't churn it cosmetically.
