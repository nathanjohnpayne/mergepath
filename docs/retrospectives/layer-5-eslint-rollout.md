# Layer 5 Templated Propagation — 6-Repo ESLint Rollout Retrospective

- **Date:** 2026-05-16
- **Parent tracker:** [mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250)
- **Follow-ups:** [mergepath#322](https://github.com/nathanjohnpayne/mergepath/issues/322), [mergepath#323](https://github.com/nathanjohnpayne/mergepath/issues/323), [mergepath#324](https://github.com/nathanjohnpayne/mergepath/issues/324)

## Context

[mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250) (parent tracker) drove the first end-to-end exercise of Layer 5 templated propagation. The original Layer 5 design ([mergepath#168](https://github.com/nathanjohnpayne/mergepath/issues/168)) only contemplated simple variable substitution; the ESLint rollout pushed it to handle conditional template blocks keyed on per-consumer facts. This retrospective captures what worked, what didn't, and what the next round should change.

## Scope

- **Infrastructure shipped:** [mergepath#313](https://github.com/nathanjohnpayne/mergepath/issues/313) (lib-only), [mergepath#316](https://github.com/nathanjohnpayne/mergepath/issues/316) (sync integration), [mergepath#318](https://github.com/nathanjohnpayne/mergepath/issues/318) (ESLint templated entry), [mergepath#319](https://github.com/nathanjohnpayne/mergepath/issues/319)/[mergepath#320](https://github.com/nathanjohnpayne/mergepath/issues/320)/[mergepath#321](https://github.com/nathanjohnpayne/mergepath/issues/321) (Phase D hotfixes)
- **Consumer follow-ups:** [swipewatch#53](https://github.com/nathanjohnpayne/swipewatch/issues/53) (canary), [dpr#83](https://github.com/nathanjohnpayne/device-platform-reporting/issues/83), [ffb#274](https://github.com/nathanjohnpayne/friends-and-family-billing/issues/274), [tadlockpsychiatry#58](https://github.com/nathanjohnpayne/tadlockpsychiatry/issues/58), [npd#373](https://github.com/nathanjohnpayne/nathanpaynedotcom/issues/373), [matchline#234](https://github.com/nathanjohnpayne/matchline/issues/234) — all merged
- **Span:** ~3 days of intensive work (mergepath + 6 consumer PRs + 4 closure-invariant hotfixes)

## What worked

1. **The phased approach.** B1 (lib only) → B2 (sync integration) → C (ESLint templated entry) → D-canary (swipewatch) → D-fanout (5 more) avoided cliff failures. Each phase had its own merge ceremony with codex external review.
2. **Conditional template syntax.** The `>>> if <expr> ... <<<` comment-marker scheme works well — readable, preserves the surrounding language's syntax, doesn't require a preprocessor.
3. **`facts.frameworks`** as closed vocabulary (react/typescript/astro) cleanly drives per-consumer rendering. The 8th-consumer case (overridebroadway, 0 lintable files) was handled by excluding from the manifest entry rather than rendering an empty config.
4. **Canary discipline.** Swipewatch as canary (9 files, JS only) surfaced the yq syntax bug ([mergepath#319](https://github.com/nathanjohnpayne/mergepath/issues/319)) and propagation closure gaps ([mergepath#320](https://github.com/nathanjohnpayne/mergepath/issues/320), [mergepath#321](https://github.com/nathanjohnpayne/mergepath/issues/321)) before fanout. The fanout PRs all opened with the hardened infrastructure.
5. **Codex Phase 4b external review.** Caught real bugs the local reviewer missed:
   - [mergepath#319](https://github.com/nathanjohnpayne/mergepath/issues/319) yq lexer error (Phase 4b round 1)
   - empty .paths: regression (Phase 4b round 2)
   - matchline tseslint preset leak onto JS files ([matchline#234](https://github.com/nathanjohnpayne/matchline/issues/234) round 3)

## What hurt

1. **Per-consumer overrides were repetitive.** 5 of 6 consumers added the same vitest globals block, `^_`-prefix unused-vars convention, React Compiler off, allowEmptyCatch, no-explicit-any → warn. Filed as [mergepath#322](https://github.com/nathanjohnpayne/mergepath/issues/322) — template should ship better defaults so the next ESLint policy update isn't a churning diff that reverts every consumer's overrides.
2. **Closure invariant was incomplete.** Initially propagated scripts/ci/check_* wrappers without the corresponding tests/test_*.sh files — caught by codex Phase 4b on [mergepath#316](https://github.com/nathanjohnpayne/mergepath/pull/316), fixed via [mergepath#320](https://github.com/nathanjohnpayne/mergepath/issues/320). The closure rule needs better static checking.
3. **Identity drift cost cycles.** Multiple sessions left the gh keyring active on `nathanpayne-codex` after the human's 4b CLI run, breaking subsequent claude-side `request-label-removal.sh` / `resolve-pr-threads.sh` calls (identity-check refuses to fire). Filed as [mergepath#317](https://github.com/nathanjohnpayne/mergepath/issues/317).
4. **Auto-clear flakiness.** `auto-clear-blocking-labels.yml` failed to fire on at least 3 of 6 propagation PRs; manual `request-label-removal.sh` invocations needed every time. Filed as [mergepath#324](https://github.com/nathanjohnpayne/mergepath/issues/324) (related to but distinct from [mergepath#315](https://github.com/nathanjohnpayne/mergepath/issues/315)).
5. **`verify-propagation-pr.sh` doesn't enforce the templated lane gate yet.** A propagation PR with drifted rendered output would slip through. Filed as [mergepath#323](https://github.com/nathanjohnpayne/mergepath/issues/323).
6. **mikefarah yq quirks.** Multiple subtle bugs around `if/then/else end` in some contexts, `IFS=\t` field-collapse on empty strings, etc. Each cost a Phase 4b cycle. The fix landed but the underlying brittleness suggests we should consider an alternative (jq or a dedicated parser) for the manifest reader as the schema grows.

## ROI realization

The original plan (`give-me-a-summary-glimmering-squid.md`) noted: *"This is multi-week mergepath work to enable a 6-repo rollout that could have been 6 manual PRs in a day."* That tradeoff held:

- **Investment:** ~3 days for Layer 5 infrastructure + ~1 day for 6-repo fanout (with ~6 codex review cycles total)
- **6-manual-PR baseline:** ~1 day, but with no propagation infrastructure for future ESLint changes
- **Break-even:** the second ESLint policy update across these 8 consumers. After that, every update is a single mergepath PR + auto-fanout vs 8 hand-edits.

The next ESLint policy update (e.g., adopting React Compiler when ready, or upgrading to ESLint 10) will validate or refute the investment.

## Lessons for the next templated rollout

1. **Land the template-gap defaults BEFORE the next ESLint policy change.** Otherwise consumers get a churn-diff that fights their overrides. [mergepath#322](https://github.com/nathanjohnpayne/mergepath/issues/322) is the blocker.
2. **Lane gate the templated re-render** ([mergepath#323](https://github.com/nathanjohnpayne/mergepath/issues/323)) before adding more templated entries to the manifest.
3. **Canary first, always.** Follow the canonical [per-wave canary selection](../agents/propagation-ordering.md#canary-selection-always-do-one-first-chosen-per-wave) and [wave-audit gate](../agents/propagation-ordering.md#wave-audit-one-scoped-review-per-wave-662), including its reviewer-unavailable path. The smallest consumer was the right canary for *this* historical rollout because its dominant risk was a uniform templated payload; size is not the standing selection rule.
4. **Identity discipline.** Always wrap codex-CLI handoffs with a switch-back to claude (the human's machine convention). Codify in `gh-as-author.sh` and similar wrappers (partly done via identity-check.sh from [mergepath#316](https://github.com/nathanjohnpayne/mergepath/issues/316); expand coverage).
5. **Closure invariant should be a manifest-level invariant, not a wrapper-level one.** Anything that's a wrapper for `tests/test_*.sh` should require the test file in the same manifest entry. Static check, not a Phase 4b catch.

## Closing

Closing [mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250) with this retrospective + the 3 follow-up issues ([mergepath#322](https://github.com/nathanjohnpayne/mergepath/issues/322), [mergepath#323](https://github.com/nathanjohnpayne/mergepath/issues/323), [mergepath#324](https://github.com/nathanjohnpayne/mergepath/issues/324)) capturing the backlog. The 8-consumer ESLint baseline is in place.
