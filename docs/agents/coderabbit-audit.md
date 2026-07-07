# CodeRabbit Configuration Audit

This page records the umbrella audit of the [CodeRabbit docs][docs] against our setup (#491), plus the operational runbook entries that came out of it (rate-limit diagnosis, seat-coverage confirmation). It is the canonical home for *why* `.coderabbit.yml` is shaped the way it is and for any deliberate divergence from the docs' default posture. The per-PR review procedure lives in `REVIEW_POLICY.md` § Phase 2.5; this page is the reference behind it.

Audited: 2026-06-17, against the FAQ, `configuration/auto-review`, `reference/configuration`, and `management/plans`. Two findings were large enough to split into their own issues during the first pass — #489 (rate-limit failover to Codex) and #490 (auto-review re-invocation / `paused` state). Those are NOT re-implemented here; this audit is the systematic sweep of everything else.

## How to re-run this audit

1. Read the [FAQ][faq] first — it is the fastest source of behavior gotchas (seats, rate-limit command, base-branch trigger).
2. Sweep [`reference/configuration`][ref] for current key defaults and the allowed enum values; the auto-review specifics are on [`configuration/auto-review`][autoreview].
3. Check [`management/plans`][plans] for the rate-limit tiers.
4. For each `.coderabbit.yml` key, resolve drift as: a config change (with a comment), a tooling note, a follow-up issue, or "no action — documented why" (this page).

## Config posture vs. the docs' defaults

`.coderabbit.yml` is **not** propagated — it is absent from `.mergepath-sync.yml`, so each consumer ships and owns its own copy. The template's copy is the reference posture; consumers may diverge locally (e.g. `profile: assertive`, `learnings.scope: local`). Only the universal safety floor (`scripts/ci/check_coderabbit_config`, #481) is enforced fleet-wide.

| Key | Docs default | Our value | Verdict |
|---|---|---|---|
| `reviews.profile` | `chill` | `chill` | Matches default; pinned + floor-enforced (template). #234/#237 rationale holds — see below. |
| `reviews.request_changes_workflow` | `false` | `false` | Matches default; floor-enforced (must not be `true`). Codex is the blocking gate, not CodeRabbit. |
| `reviews.auto_review.enabled` | `true` | `true` | Matches default; floor-enforced (must not be `false`). |
| `reviews.auto_review.drafts` | `false` | `false` | Matches default. Draft PRs are intentionally skipped. |
| `reviews.auto_review.auto_incremental_review` | `true` | `true` (now explicit) | Matches default; pinned explicitly so the fix-up-loop posture is legible. See below. |
| `reviews.auto_review.auto_pause_after_reviewed_commits` | `5` | unset (inherits `5`) | **Owned by #490** — do not pin here. See below. |
| `reviews.auto_review.base_branches` | `[]` (default branch only) | `[main]` | Redundant-but-explicit; not harmful. See below. |
| `knowledge_base.learnings.scope` | `auto` | `auto` | Kept deliberately; privacy consequence documented below. |
| `reviews.path_instructions` | n/a | `scripts/**`, `docs/**` | Matches doc guidance (minimatch globs). See below. |

### `profile: chill` — rationale still holds (no action)

The docs confirm `chill` is the default and that `assertive` is the "more feedback" profile (the Nitpick category surfaces only in assertive mode). The #234/#237 audit chose `chill` to drop 56 unresolved nit threads across 9 repos that the #236 validation pass classified as ALREADY-FIXED or cosmetic, while keeping substantive findings (`Potential issue` / ⚠️ / Refactor / Security). Nothing in the current docs contradicts that. The template stays on `chill` and the floor check enforces it for the template repo only; consumers may set `assertive` locally.

> **Interaction with `feedback_policy` (#574).** The `feedback_policy` block in `.github/review-policy.yml` can mark the `nitpick` tier `required` (or use `mode: address-all`). That requirement only has teeth under `profile: assertive` — under `chill` the 🧹 Nitpick category is suppressed, so no nitpick threads exist and `nitpick: required` is a **silent no-op**. A repo that genuinely wants nitpicks gated must set `assertive` here as well. (Shipped in #590 and active: `scripts/coderabbit-severity-gate.sh` detects this exact case — `nitpick` marked `required` while `reviews.profile` is, or defaults to, `chill` — and emits a non-fatal warning explaining that the gating is a silent no-op under `chill`, rather than failing the check.)

### `auto_incremental_review: true` — pinned explicitly (config change)

Default is `true` ("re-run the review on each push"). We previously inherited it implicitly. The audit pins it explicitly because the fix-up-commit loop (reviewer identity posts a fix commit → expects a fresh CodeRabbit pass on the new HEAD) depends on it, and `scripts/coderabbit-wait.sh` anchors clearance on the current HEAD committer date. An accidental `false` (or a future default flip) would mean CodeRabbit reviews only the opening commit and ignores subsequent pushes — `coderabbit-wait.sh` would then time out (exit 4) waiting for a HEAD review that never comes. Explicit `true` removes that ambiguity.

### `auto_pause_after_reviewed_commits` — owned by #490 (no action here)

With the key unset we inherit the default **5**: after 5 reviewed commits since the last pause, CodeRabbit auto-pauses incremental review and posts a "Reviews paused" NOTE carrying the marker `<!-- This is an auto-generated comment: review paused by coderabbit.ai -->`. On a long agent-loop PR (#485 hit this at 10 commits) that reads to `coderabbit-wait.sh` as "no review yet," and the script polls to its `max_wait_seconds` budget and exits 4. The pause is durable: a one-shot `@coderabbitai review` re-pauses after more commits, so the correct response is `@coderabbitai resume` (or raising the threshold).

**This key is owned by #490** (auto-review re-invocation + a new `paused` state in `coderabbit-wait.sh`). This audit deliberately does NOT pin a value or edit the wait script, to avoid colliding with that work. The `.coderabbit.yml` comment points a future reader at #490 rather than letting them set it blind.

### `base_branches: [main]` — redundant-but-explicit (config comment only)

The docs are explicit: `base_branches` *extends* the auto-review set and **never replaces the default branch** — CodeRabbit always auto-reviews PRs targeting the repo's detected primary branch (it auto-detects `main`/`master`/ `dev`). Default is `[]`. So listing `main` is redundant (it is already always reviewed) but harmless.

The load-bearing consequence to know: a PR opened against a **non-default base** is NOT auto-reviewed. That covers:

- a **stacked PR** onto a feature branch, and
- a **sync/propagation PR** onto a non-`main` release line.

If we ever target such bases and want CodeRabbit on them, the base (or a regex like `release/.*`) must be added to `base_branches` in *that repo's* `.coderabbit.yml`. Today every template PR targets `main`, and propagation PRs (`mergepath-sync/*`) target the consumer's `main`, so no change is needed. The behavior is documented here and in a comment on the key so a future stacked-PR workflow doesn't silently skip review.

### `learnings.scope: auto` — privacy posture (deliberate divergence, documented)

`learnings.scope` controls where CodeRabbit's accumulated review-preference "learnings" are stored and applied. Allowed values: `local` (this repo only), `global` (shared across the whole org/owner), `auto` (= `local` for **public** repos, `global` for **private** repos).

We keep `auto`. As of **2026-07-06 the entire fleet is public** — matchline, overridebroadway, and tadlockpsychiatry were private earlier in the fleet's history and have since been made public — so `auto` resolves to **`local`** for every consumer and the template repo alike:

| Visibility | Consumers | `auto` resolves to |
|---|---|---|
| Public (all 8) | matchline, overridebroadway, tadlockpsychiatry, device-source-of-truth, friends-and-family-billing, device-platform-reporting, swipewatch, nathanpaynedotcom | `local` |

So no consumer currently shares learnings org-wide — each repo's learnings stay local to that repo. (Historically, while three consumers were private, `auto` gave *those* repos `global`, and the single-owner `nathanjohnpayne` fleet shared review conventions across them; that was deliberate, not a leak — learnings stay within one account's org boundary and CodeRabbit does not use code for model training, FAQ § Data Security — but it no longer applies now the fleet is uniformly public.) If cross-repo convention sharing is later wanted across the public fleet, it would take an explicit `scope: global` override — `auto` will not grant `global` to a public repo. We keep `auto` because it is the correct low-surprise default that needs no per-repo maintenance as visibility changes.

### `path_instructions` — matches doc guidance (no action)

The docs say path instructions use **minimatch** globs and are best used as *targeted supplements* once you see something consistently missed, not as a review rewrite. Our two entries (`scripts/**` shell-safety, `docs/**` accuracy-vs-code) are valid minimatch patterns and align with that guidance — they reinforce the two surfaces this shell/CI-heavy template cares about most. `tone_instructions` carries the global "bugs/security/secrets over nits" steer; path instructions carry the per-surface specifics. No change. If a future surface (e.g. `.github/workflows/**`) is consistently under-reviewed, that is the signal to add an entry — not a speculative addition now.

## Operational runbook

### Checking the rate-limit allowance without consuming a review

CodeRabbit rate limits are **per-developer, per-hour, refillable** (you can burst the full hourly amount; it refills over the following hour rather than resetting at the top of the hour). Each PR review run — including automatic incremental reviews after a push, `@coderabbitai review`, and `@coderabbitai full review` — consumes one from the allowance.

Per-tier hourly limits ([`management/plans`][plans]):

| Plan | PR reviews / hour |
|---|---|
| Free | 3 (summary only) |
| Pro | 5 |
| Pro+ | 10 |
| Enterprise | 12 |

To **diagnose a suspected rate-limit stall without spending a review**, post on the PR (as the author identity — this is an authoring write, so route it through `scripts/gh-as-author.sh`):

```
@coderabbitai rate limit
```

`@coderabbitai reviews remaining?` works too. CodeRabbit replies with the remaining count and refill timing and does **not** consume a review to answer.

This is the read-only counterpart to what `scripts/coderabbit-wait.sh` already automates on the *write* side: when CodeRabbit posts an actual `Rate limit exceeded` comment, the wait helper parses the published retry window, sleeps it + a 30s buffer, posts `@coderabbitai, try again.`, and retries up to `coderabbit.max_rate_limit_retries` (default 2) before exiting `5` (`rate_limit_stalled`). Use `@coderabbitai rate limit` when you want to *check* the allowance up front (e.g. before kicking off a multi-push loop, or to confirm a stall is genuinely the hourly cap) rather than react to a stall.

> Automated failover when stalled (request `@codex review`, revert when the window elapses) is tracked separately in **#489** — CodeRabbit is advisory and Codex is the real blocking gate, so we should not sit idle on an advisory bot's hourly cap. This audit only wires the *manual diagnostic* command into the runbook.

### Confirming author seat coverage across consumers

The FAQ is explicit (§ "How to troubleshoot CodeRabbit not functioning on certain repositories?"): **"Confirm that the author of a pull request has an active seat in CodeRabbit. If not please provide a seat to the user under Subscription page to enable CodeRabbit for the user."** A missing seat for the PR author **silently disables review** — CodeRabbit just never runs, with no error on the PR.

Our entire fleet authors as the single shared identity **`nathanjohnpayne`**. So the coverage question reduces to one check: *does `nathanjohnpayne` have an active CodeRabbit seat covering every consumer repo?* CodeRabbit seat management is **not exposed via the `gh` API** — there is no GitHub-side endpoint for it — so this is a CodeRabbit-dashboard confirmation, not a scriptable CI gate. Confirm it this way:

1. Open the CodeRabbit dashboard → **Subscription** → seat list, signed in as the org owner (`nathanjohnpayne`).
2. Verify `nathanjohnpayne` holds an **active** seat and that the seat's repo/org coverage includes all 8 consumers (all **public** as of 2026-07-06): `matchline`, `overridebroadway`, `tadlockpsychiatry`, `device-source-of-truth`, `friends-and-family-billing`, `device-platform-reporting`, `swipewatch`, `nathanpaynedotcom`.
3. **Observational cross-check (the only API-visible signal):** on a recent PR in each repo, confirm a `coderabbitai[bot]` review/summary actually landed:

   ```bash
   command -v brew >/dev/null 2>&1 && eval "$(brew shellenv)"
   for r in matchline nathanpaynedotcom overridebroadway tadlockpsychiatry \
            device-source-of-truth friends-and-family-billing \
            device-platform-reporting swipewatch; do
     echo "=== $r ==="
     GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api \
       "repos/nathanjohnpayne/$r/issues/comments?per_page=100&sort=created&direction=desc" \
       --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | length' \
       2>/dev/null || echo "(no recent comments / repo quiet)"
   done
   ```

   A non-zero count is positive evidence the author seat is working on that repo. A zero on a repo that *has* had PRs is the red flag to chase in the dashboard. (A quiet repo with no recent PRs is inconclusive, not a failure.) The bootstrap wizard's **private**-repo path can delete `.coderabbit.yml` and leave `coderabbit.enabled: false` (see #248 — `scripts/ci/check_coderabbit_config` PASSes on that state), so on a private consumer a zero count is expected, not a seat gap. **No current consumer is in that state:** all 8 are public and carry `.coderabbit.yml` (tadlockpsychiatry is explicitly `enabled: true`), so a zero on any of them *is* a red flag to chase.

## Safety-floor coverage check (#481)

`scripts/ci/check_coderabbit_config` enforces, fleet-wide, the two keys whose drift would silently weaken or deadlock review:

- `reviews.auto_review.enabled` must not be explicitly `false` (would turn CodeRabbit off while the file still exists), and
- `reviews.request_changes_workflow` must not be explicitly `true` (would make CodeRabbit post CHANGES_REQUESTED and hard-block PRs on branch protection, deadlocking the Codex-gated merge automation).

The audit confirms those two remain the right load-bearing floor:

- `profile` is enforced **template-only** by design (consumers may run `assertive`), so it is correctly *not* in the universal floor.
- `base_branches`, `auto_incremental_review`, `learnings.scope`, and `path_instructions` are **per-repo posture** with safe CodeRabbit defaults (`auto_incremental_review` and `enabled` default `true`; `request_changes_workflow` defaults `false`). Pinning them in the universal floor would over-constrain consumers without closing a silent-failure hole — the two existing floor keys already cover the two states that fail silently. So **no new floor keys are warranted**; the #481 floor still covers the load-bearing surface.

[docs]: https://docs.coderabbit.ai/
[faq]: https://docs.coderabbit.ai/faq
[ref]: https://docs.coderabbit.ai/reference/configuration
[autoreview]: https://docs.coderabbit.ai/configuration/auto-review
[plans]: https://docs.coderabbit.ai/management/plans
