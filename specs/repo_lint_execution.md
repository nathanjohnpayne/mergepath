# Repo-lint execution model

## Purpose

The `repo-lint` workflow preserves one stable required context named `lint` while avoiding duplicate work and keeping exhaustive regression nets off unrelated pull requests' critical path.

## Event contract

Pull-request heads run through `pull_request` only. Feature-branch pushes do not start a second copy of `repo-lint`, Markdown prose wrapping, or OWL validation. A `push` run is retained for `main`, and pull-request concurrency cancels an older in-progress head when a newer commit arrives. Scheduled and manually dispatched `repo-lint` runs execute deep CI in Mergepath and in consumers that carry the canonical `scripts/ci/` kit; kit-less consumers have no deep implementation to execute.

## Scope classifier

`scripts/ci/repo-lint-scope.sh` is the single scope decision. A pull request enters deep CI when it changes CI workflows, scripts, tests, specifications, rules, agent operating documentation, architecture decisions, either repository manifest, `AGENTS.md`, `REVIEW_POLICY.md`, or `ai_agent_tooling_standard.md`. Other pull requests use the fast lane. An unreadable pull-request diff fails closed to deep CI, and every non-pull-request event is deep once the canonical `scripts/ci/` kit is present. A consumer checkout that intentionally or temporarily lacks that kit emits `deep=false` because it has no deep check implementation to execute; the hub fails instead of taking this exception.

The classifier reads `scripts/ci/repo-lint-dependencies.json`, the machine-readable dependency graph for expensive wrapper checks. A direct change to `scripts/ci/check_<name>` selects that wrapper. A dependency named by the graph selects every wrapper that owns it. Changes to the classifier, graph, workflow, deep-safety harnesses, propagation contract, or governance-wide inputs select the complete deep surface. Unknown CI implementation paths also fail closed to the complete surface. The classifier emits one JSON array of selected wrapper names plus an explicit `full` bit; consumers must not reconstruct dependencies with source-text greps.

## Required result

`lint-fast` always runs the live repository assertions. The consumer and residue legs of the `deep-safety` matrix run in parallel only when the scope output is `deep=true`; the single matrix declaration keeps their isolated fixtures from duplicating workflow setup logic. For a partial deep selection, both harnesses receive the classifier's wrapper array and execute only those wrappers while retaining their cheap structural/non-vacuity assertions. A full selection executes every wrapper and every enrolled self-test. An always-running aggregator publishes the required `lint` result and fails unless the fast lane succeeds and the matrix has the result appropriate to the selected scope. Path filtering therefore never leaves branch protection waiting for a missing required context.

The token-output gate uses `--scan` in the fast lane and `--self-test` in deep CI. Documentation ownership uses `--check` in the fast lane and `--self-test` in deep CI. The complete consumer simulation and residue lattice remain deep-CI checks. Consumer simulation recognizes only a wrapper's canonical `<check>: SKIP (...)` line as a skipped verdict; nested test output containing `SKIP` does not change the wrapper result.

## Approval coordination

An approval records merge readiness in GitHub's review state; it does not reserve a runner while required checks execute. The approval workflow performs a one-shot current-head check probe and exits successfully when work is still pending. The trusted default-branch continuation listens for approval, canonical repo-lint, optional local-annex, and policy-gate completion events. Each event resolves the live open pull request by number or exact head SHA, reruns the canonical merge-clearance predicate, and immediately before arming native auto-merge re-reads the current head, all blocking labels, feedback accounting, and unresolved conversations. It passes the re-read head to `--match-head-commit`. A pending or failed prerequisite is a no-op for that event and is reconsidered by a later event or the bounded scheduled backstop.

This event-driven path does not treat CodeRabbit as an additional merge requirement after a registered reviewer has approved. CodeRabbit's required-severity and conversation state remain represented by their existing required gates; advisory review arrival is not polled by a runner.

## Regression contract

`tests/test_repo_lint_optimization.sh` validates triggers, concurrency, dependency selection, the stable aggregator, split gate modes, consumer verdict classification, and the event-driven approval continuation. `tests/test_655_repo_lint_local_observed.sh` retains exact-head and optional-annex semantics without requiring a runner-held wait.
