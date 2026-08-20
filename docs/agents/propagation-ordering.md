# Propagation wave ordering and change-handling

Status: **canonical, in-repo source of truth.** The order below is reviewed monthly; the dated review log lives on the repo wiki page [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log). See [§ Maintenance](#maintenance) for how the doc and that log stay in sync.

This is a **hub-only** doc — it governs how a canonical change is fanned out *from* mergepath *to* the 9 consumers via `scripts/sync-to-downstream.sh`. It is intentionally **not** in `.mergepath-sync.yml` (consumers don't run propagation waves). It complements [templated-propagation.md](templated-propagation.md) (the rendering engine) and the canary-first note in `.mergepath-sync.yml`.

Treat this as the default for every propagation wave unless a specific wave documents a reason to deviate in its own tracking issue.

## Default propagation order (riskiest → least, in pairs)

This is the **fan-out** order — the sequence in which consumer PRs are opened *after* the canary is green.

| Wave | Pair | Why this tier |
|---|---|---|
| **0 (most locally patched)** | `gaycruisebingo` (single) | Measured 2026-08-20: its `.sync-overrides.yml` skipped the **entire** `scripts/ci/` kit until gaycruisebingo#1011 removed the skip at 2026-08-20T00:33Z, so the next wave is its first sync of that whole directory — the largest unreconciled surface on the fleet, and the reason it leads. It also carries the only confirmed hand-patched kit file the mirror will clobber: `check_workflow_parsers`, holding 71 lines of local `synthetic-uptime.yml` assertions (#768) that appear nowhere in the hub. Its `check_coderabbit_config` patch is **not** a second one — it names mergepath#911 as a pending upstream fix, #911 landed canonically, and the mirror will correctly replace the local copy rather than lose anything (Codex, round 2). So the honest count is one clobber-sensitive file, matching `nathanpaynedotcom`; what separates them is the whole-kit first sync, not the patch count. Its wave PR must still be read for real local modifications vs missed upstream fixes (per the manifest's first-sync-risk note). **Re-based, not retired:** #741 placed it here in 2026-07 for carrying "the largest unaudited accumulated drift" after a bootstrap gap, which was never measured. The 2026-08-20 measurement reaches the **same** position on a signal that does reproduce, so what changed is the evidence, not the ordering. An earlier round of this PR read that measurement as *retiring* the tier; that reading was wrong and the error is recorded in [§ Measuring tier membership](#measuring-tier-membership) because it is instructive. |
| **1 (riskiest)** | `overridebroadway` + `nathanpaynedotcom` | overridebroadway: historically special-cased ("CodeRabbit disabled" era), most bespoke `path_instructions`. nathanpaynedotcom: only consumer with a `tools.eslint.enabled: false` override (Astro) + highest churn. |
| **2** | `matchline` + `tadlockpsychiatry` | Both React+TS. matchline = well-trodden reference (deepest bot history); tadlockpsychiatry = quietest / least-observed. |
| **3** | `device-source-of-truth` + `friends-and-family-billing` | Recently touched by the ESLint-floor work. |
| **4 (safest)** | `device-platform-reporting` + `swipewatch` | Simplest surfaces; swipewatch is the documented ESLint canary. |

**Rationale:** the dominant failure mode for a wave is **usually** per-consumer idiosyncrasy (config divergence, local adaptations) rather than a uniform payload break. Front-loading the most divergent repos surfaces any check-vs-config interaction while attention is full; fixes land once at the source and later pairs become verification. Simplest repos last = cheap confirmation. (All 9 consumers are **public** — visibility was once an ordering factor, since a private repo's CI failures aren't readable without auth, but it no longer distinguishes the tiers; the axis is now divergence and churn.) "Usually" is doing real work in that sentence: it is a claim about the typical wave, not about every wave, and the canary rule below asks which mode dominates *this* change rather than assuming the usual one.

**Tier membership is a claim about current state, not a permanent label.** Every "Why this tier" cell above **should** carry a date, and a consumer occupies its tier only for as long as its stated signal still reproduces. That is a requirement, and most rows do not yet meet it: only the wave-0 row is dated. Rows 1–4 are undated, and the tier-1 config signals in particular have no dated measurement behind them at all — read an undated row as an inherited claim awaiting its first measurement, never as a freshly verified one. A rationale that was true when it was written keeps being repeated long after the condition it described has been reconciled, and re-measuring is the only thing that tells the two apart. Before relying on any row, check that its stated signal is still observable ([§ Measuring tier membership](#measuring-tier-membership)); a tier whose justification no longer reproduces is stale prose, not a standing fact about the repo.

## Canary selection (always do ONE first, chosen per wave)

**The canary is a role assigned per wave, never a standing title.** No consumer holds a permanent canary designation, and no phrase like "the propagation canary" identifies a repo on its own — the canary is whichever consumer best exercises the dominant risk of the change being propagated, and the answer legitimately differs from wave to wave. Two axis-specific labels do exist and are routinely misread as general appointments: `swipewatch` is the documented **ESLint** canary, and `gaycruisebingo` was the **first-sync** canary for its own enrolment backlog. Both are scoped to one axis. This restates what CONTEXT.md already defines: "the single consumer synced and driven green before any fan-out, **chosen by the dominant risk of the change**".

Before any fan-out, sync ONE consumer and get its PR green:

```bash
# --repos narrows the --sync-all mode to a single consumer (it is a filter, not a mode)
scripts/sync-to-downstream.sh --sync-all --repos <canary>
```

Pick the canary by the **dominant risk of this change**:

- **Uniform manifest/payload gap** (the #264 class — a missing test / fixture / script the kit hard-requires) → cheapest to catch on the **simplest public** repo (`swipewatch`).
- **Per-consumer config idiosyncrasy** → the **most-divergent** repo, read off the current table rather than from memory, which then doubles as canary + first wave. Divergence is not one signal, and only one of them is currently measured: the 2026-08-20 measurement below covers **`scripts/ci/` kit divergence only**, and on that signal `gaycruisebingo` and `nathanpaynedotcom` are **tied** at one hand-patched kit file each, with the other seven carrying none. The patch count does not separate them, so it cannot pick the canary on its own — for the next wave the tie is broken by the whole-kit first sync, which is a different bullet below and not this one. (`gaycruisebingo` also differs on `check_coderabbit_config`, but that patch is superseded upstream and is deliberately not counted; see the table above.) The tier-1 rationales — overridebroadway's bespoke `path_instructions`, nathanpaynedotcom's `tools.eslint.enabled: false` override and churn — are **config** signals that no dated measurement currently backs; they are carried forward from earlier review rounds. So pick on the kit signal when the change is a kit change, and re-measure the config signal before ranking on it ([§ Measuring tier membership](#measuring-tier-membership) covers the kit axis; the config axis needs its own pass).
- **A consumer's own first sync** → that consumer, for that wave only. A repo whose enrolment backlog has never been reconciled is the highest-risk repo to exercise on the wave that reconciles it, because its wave PR is the first thing to distinguish real local modifications from missed upstream fixes. This is a per-wave reason like the others; it is **not** a licence to hold the fleet, and the fan-out is gated on the canary going green plus the wave audit, never on any particular repo's membership in a tier.

Only fan out (`--sync-all`) once the canary's `lint` is green **and the wave audit below has cleared (or is recorded as unavailable)**; the remaining consumers re-use the cleared invariant instead of each re-discovering the problem.

### Selection on record for the next wave (recorded 2026-08-20)

**Canary: `gaycruisebingo`, alone.** The third bullet above selects it: it is the consumer whose own accumulated divergence this wave reconciles. Measured 2026-08-20 against hub `9943173c`, whose `scripts/ci/` tree holds **115** blobs; every consumer holds the same 110 **hub-known** entries, while `matchline` also holds three consumer-only kit files (a different set from the manifest's own `paths[]` entries, which at the same ref number **119** — 112 canonical, 5 kit, 2 templated; full numbers and method in [§ Measuring tier membership](#measuring-tier-membership)). Its `scripts/ci/` skip was lifted by gaycruisebingo#1011 at 2026-08-20T00:33Z after mergepath#911 landed, so this is the first wave to deliver the whole kit to it. On the divergence signal it is one of two consumers carrying a hand-patched kit file — `check_workflow_parsers`, with local `synthetic-uptime.yml` assertions the hub does not ship — alongside `nathanpaynedotcom`; the other seven carry none. Its `check_coderabbit_config` difference is a superseded patch rather than a live adaptation and is deliberately not counted.

**An earlier round of this PR recorded `swipewatch` here, and that was wrong.** The reasoning was that the dominant risk is a uniform payload gap, on the evidence that all nine consumers produce an identical bucket signature against the hub. The signature is identical — it still is, at 87 identical / 23 differing / 5 absent, which totals the hub's **115** kit blobs and leaves each consumer with 110 hub-known entries; `matchline` separately holds three consumer-only entries — but it does not license the conclusion drawn from it. A `differing` bucket records only that an entry differs from the **hub**; it says nothing about whether consumers differ from **each other**, and on this fleet five kit paths diverge consumer-to-consumer while sitting inside that uniform signature. The per-consumer idiosyncrasy axis was therefore never at its "fleet-wide minimum"; the measurement simply could not see it. The corrected method is in the section below and the payload-gap reading is retained there as the worked example of the failure.

**The payload gap is real, and it is not the dominant risk.** All nine consumers are missing the same kit checks, and #1041 is open on `.sync-overrides.yml` `skip_paths` bypassing the `requires:` closure — both still true, and both are exercised by whichever consumer goes first. What the corrected measurement changes is the ordering question, not the existence of that gap: a uniform gap is uniform, so any canary surfaces it, while the hand-patched files are specific to one repo and only that repo's PR can surface them.

**Prerequisites before this wave runs.** First, complete #845 Stage B: land the shadow-to-live context-name flip on mergepath, then observe 48 hours of normal traffic and confirm the publisher ran within the last 24 hours before opening the fleet wave. That keeps the rollout's measured hub-first order: the publisher is exercised under live names on one repo while every consumer still runs its untouched fallback producers. Second, migrate the canary's local kit assertions. `gaycruisebingo`'s `check_workflow_parsers` carries 71 lines of consumer-only `synthetic-uptime.yml` assertions (#768) that the hub does not ship, and a verbatim kit sync **overwrites** them. Neither documented success condition catches that: a green lane marker only proves the mirror matches mergepath, which is exactly what an overwrite produces, and the wave audit below reviews the canonical range rather than the consumer-local lines that were removed. So the wave can pass every gate while silently deleting that coverage. Move those assertions into a consumer-local check wired through the never-propagated `repo_lint_local.yml` annex — the same annex migration the matchline note below describes; `gaycruisebingo` has no annex today, so this creates one — or upstream them into the canonical `check_workflow_parsers`, BEFORE the sync PR is opened. Tracked as [#1055](https://github.com/nathanjohnpayne/mergepath/issues/1055). These are hard prerequisites, not cleanup items: Stage B limits the publisher's first live exposure to the hub, and once the mirror lands, the only record of the local assertions is the consumer's git history.

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

The ordering table is a heuristic, but the signals behind it are observable, and a row is only worth trusting while its signal still reproduces. The cheapest full measurement compares each consumer's `scripts/ci/` kit tree against the hub's without fetching a single file, by comparing the **git tree entry** — `mode`, `type` and object id — exactly as `scripts/workflow/verify-propagation-pr.sh` does. Compare the whole tuple, not the object id alone: an exec-bit flip leaves the blob identical while the propagation verifier rejects it, so a blob-only comparison reports parity on drift the wave will fail on. The kit is genuinely mixed — at `main` (`9943173c`) it is 68 `100755` entries and 47 `100644`, 115 blobs in total — so "they're all executable anyway" is not available as a shortcut. That total is the one every measurement below is quoted against, and it moves whenever a check is added: the 67/47 split recorded here before 2026-08-20 predated #1018 adding `check_review_feedback_accounting`. Re-read it at the commit you are actually propagating FROM rather than trusting the number written here, which is exactly the discipline the rest of this section asks for.

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

**Resolving the last synced hub sha** (the `HUB_REF` for a "has this consumer drifted since its last wave?" comparison): `scripts/sync-to-downstream.sh --sync-all` records it in three places, and only one of them is abbreviated. The **branch name** `mergepath-sync/sync-all-<sha7>` carries 7 characters. The **sync commit message** carries a `Source: https://github.com/nathanjohnpayne/mergepath/commit/<sha>` trailer with the full sha. The **PR body's first line** reads `Bulk sync to [mergepath@<sha7>](…/commit/<sha>)`, whose link target is also the full sha. Prefer either full-sha form over the branch name. Note the `Source:` trailer is on the COMMIT, not in the PR body — grepping the body for it returns nothing (measured across 92 sync PRs on three consumers). Read it off that consumer's most recent merged sync PR rather than assuming the fleet shares one; they usually do. A consumer that reached parity through the bootstrap template mirror has **no** sync PR at all, and its bootstrap commit is **not** usable as `HUB_REF`: that sha belongs to the consumer repository, so `git ls-tree -r "$HUB_REF"` in a mergepath checkout cannot resolve it.

**For such a repo there is no hub sha to recover, and this document previously claimed there was.** `scripts/bootstrap/template-mirror.sh` commits the mirrored tree as `Initial commit (bootstrapped from mergepath)` and records no source sha anywhere — not in that message, not in the mergepath-side loop PR body, and nowhere in the logged commands (verified against `gaycruisebingo`'s `a2965a93`). Sending an operator to look for it wastes the lookup and, worse, invites reaching for a *plausible* mergepath commit by date, which silently produces a baseline the mirror never used.

So: **drop the hub baseline for a bootstrapped consumer and use the consumer-to-consumer comparison below**, which needs no hub ref and answers the divergence question directly. Persisting the source sha at bootstrap time would make the hub baseline available to FUTURE consumers and is a change to `template-mirror.sh`, tracked in [#1056](https://github.com/nathanjohnpayne/mergepath/issues/1056); it cannot recover the ones already bootstrapped.

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
- **Differing everywhere, same paths** → **indeterminate, and the trap this document was built on.** It is consistent with the fleet being pinned to one older payload, and equally consistent with several consumers carrying different hand-patched versions. This exact shape concealed five consumer-to-consumer divergences here, which is what produced the wrong canary. Never read it as uniform without comparing the consumers' own entries; re-comparing against the last synced hub sha is a supporting check, not a substitute.
- **Differing on a path only some consumers differ on** → per-consumer idiosyncrasy, visible directly in the bucket shape. It is not the ONLY bucket that can justify a divergence-based tier — the all-differing bucket can too, once the consumer-to-consumer comparison shows the versions disagree, which is exactly what happened on this fleet. Read the diff before ranking on it either way: a hand-patched kit file (the thing a verbatim mirror clobbers) is a genuine wave risk, while a file that merely lags is not.

**Consumer refs behind the 2026-08-20 measurement.** Recorded so the result stays re-derivable once these advance, which is the same immutable-ref requirement stated above — a dated claim naming only the hub half is reproducible only until the first consumer moves:

| consumer | ref | | consumer | ref |
|---|---|---|---|---|
| `overridebroadway` | `a90fb62f` | | `friends-and-family-billing` | `d1ece75b` |
| `nathanpaynedotcom` | `d07f7371` | | `device-platform-reporting` | `9076e165` |
| `matchline` | `5873afcf` | | `swipewatch` | `269d958b` |
| `tadlockpsychiatry` | `e813d233` | | `gaycruisebingo` | `767341cc` |
| `device-source-of-truth` | `6e9a6985` | | | |

**The 2026-08-20 measurement, and the 2026-08-19 error it corrects.** Against hub `9943173c`, all nine consumers produce the **identical hub-relative** bucket signature: 87 byte-identical, 23 differing, 5 absent, the same paths in each bucket for every consumer. Those counts cover the 115 hub-known kit paths; each consumer holds 110 of them, and `matchline` separately holds three consumer-only kit files. An earlier round of this PR read that as proof that no consumer was individually divergent, retired the wave-0 tier on it, and recorded `swipewatch` as the canary. That inference is invalid, and it is worth keeping here because the measurement it rests on is correct and the conclusion still does not follow: the buckets are computed against the **hub**, so identical signatures mean the nine consumers are equally far from the hub, not that they carry the same bytes. Comparing the consumers to **each other** shows five kit paths on which they do not agree — `check_coderabbit_config` carries two distinct versions across the fleet and `check_workflow_parsers` three, with `gaycruisebingo` the sole outlier on both and `nathanpaynedotcom` an outlier on one, while `matchline` carries three `scripts/ci/` files the hub does not ship at all. Seven consumers are outliers on nothing. Read that ranking with the reclassification above in hand: divergence measured by object id is not the same as **clobber risk**, and `gaycruisebingo`'s `check_coderabbit_config` difference is a patch superseded by canonical #911 that the mirror will correctly replace. On clobber risk the two are tied at one file each — which is why the canary is chosen on the whole-kit first sync rather than on this count. So the per-consumer idiosyncrasy signal was present the whole time and the bucket comparison was structurally unable to see it. Re-run with the full mode+type+oid tuple rather than the object id alone, every number above is unchanged and no consumer carries mode-only drift on any kit path — so the exec-bit hazard the tuple comparison exists to catch is a real failure mode that is simply not firing on this fleet today, which is a thing worth re-checking rather than assuming.

`matchline`'s three extra files are a different risk class again, and should not be added to the same ranking. A hand-patched copy of a file the hub **does** ship is what a verbatim mirror overwrites, which is the wave risk this tier ordering is about. A consumer-local file the hub does not ship is not overwritten by the mirror at all — and it is **not** covered by the wave audit either, which is worth stating because assuming otherwise would skip the only checks that can see it: `scripts/wave-audit.sh` builds its review diff from mergepath manifest source paths over the canonical range, so a file the hub does not ship is absent from that diff by construction. Consumer-only extras belong to that consumer's own CI and to the pre-wave annex inspection above, which is where matchline — the known carrier of consumer-local check wiring — is already handled.

## Maintenance

- **This doc is canonical.** The [Propagation-Wave-Order-Review-Log](https://github.com/nathanjohnpayne/mergepath/wiki/Propagation-Wave-Order-Review-Log) wiki page is the **monthly review log**, not a competing source — on a material order change the doc and the log are kept in lockstep (below). The log lived in [mergepath#492](https://github.com/nathanjohnpayne/mergepath/issues/492) until 2026-07-06, when it moved to the wiki so the recurring review no longer needs an always-open issue.
- **Monthly review** (`propagation-order-monthly-review`, 1st of each month): re-measure per-consumer risk signals — config divergence (overrides / unique `facts`), churn (recent PR/line volume), recent propagation failures, framework/visibility changes. Re-measure kit divergence per [§ Measuring tier membership](#measuring-tier-membership) rather than re-reading the table's own rationale, and **re-date every "Why this tier" cell you confirm** — an undated rationale is how a reconciled condition survives as a standing label.
  - **No change** → append a dated `No change — order holds (YYYY-MM-DD)` entry to the wiki review log.
  - **Material change** → update the wiki review log *and* open a PR re-syncing the order table above, so the canonical doc never lags the review.
- The order is a **soft heuristic** — only shift it on a real, defensible signal; don't churn it cosmetically.
