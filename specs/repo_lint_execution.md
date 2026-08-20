# Repo-lint execution model

## Purpose

The `repo-lint` workflow preserves one stable required context named `lint` while avoiding duplicate work and keeping exhaustive regression nets off unrelated pull requests' critical path.

## Event contract

Pull-request heads run through `pull_request` only. Feature-branch pushes do not start a second copy of `repo-lint`, Markdown prose wrapping, or OWL validation. A `push` run is retained for `main`, and pull-request concurrency cancels an older in-progress head when a newer commit arrives. Scheduled and manually dispatched `repo-lint` runs always execute deep CI.

## Scope classifier

`scripts/ci/repo-lint-scope.sh` is the single scope decision. A pull request enters deep CI when it changes CI workflows, scripts, tests, specifications, rules, agent operating documentation, architecture decisions, either repository manifest, `AGENTS.md`, `REVIEW_POLICY.md`, or `ai_agent_tooling_standard.md`. Other pull requests use the fast lane. An unreadable pull-request diff fails closed to deep CI, and every non-pull-request event is deep.

This path classifier intentionally begins conservatively. It may run more deep CI than a future machine-readable wrapper dependency graph would require, but it must not skip a regression net after its implementation, fixtures, propagation contract, or governance inputs change.

## Required result

`lint-fast` always runs the live repository assertions. The consumer and residue legs of the `deep-safety` matrix run in parallel only when the scope output is `deep=true`; the single matrix declaration keeps their isolated fixtures from duplicating workflow setup logic. An always-running aggregator publishes the required `lint` result and fails unless the fast lane succeeds and the matrix has the result appropriate to the selected scope. Path filtering therefore never leaves branch protection waiting for a missing required context.

The token-output gate uses `--scan` in the fast lane and `--self-test` in deep CI. Documentation ownership uses `--check` in the fast lane and `--self-test` in deep CI. The complete consumer simulation and residue lattice remain deep-CI checks. Consumer simulation recognizes only a wrapper's canonical `<check>: SKIP (...)` line as a skipped verdict; nested test output containing `SKIP` does not change the wrapper result.

## Approval coordination

The agent-review workflow pins the current pull-request head before enabling auto-merge. When `.github/workflows/repo_lint_local.yml` is confirmed absent at that head, GitHub native auto-merge and branch protection wait for required checks without holding the approval runner open. If the optional annex is present, the workflow retains its explicit bounded polling because that annex is deliberately outside branch protection. An indeterminate annex lookup does not take the no-wait fast path.

## Regression contract

`tests/test_repo_lint_optimization.sh` validates triggers, concurrency, scope selection, the stable aggregator, split gate modes, consumer verdict classification, and the native-auto-merge fast path. `tests/test_655_repo_lint_local_observed.sh` behaviorally proves that a confirmed-absent annex makes no rollup queries or sleeps and that a present annex retains the current-head wait semantics.
