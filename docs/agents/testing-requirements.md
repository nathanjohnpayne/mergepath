# Testing Requirements

- Update tests when behavior changes.
- Do not delete tests to make a build pass.
- Every spec file should have a corresponding test file or a documented exception explaining why one does not exist.

## Repo-lint execution

The required `lint` context is an aggregator over a fast live-assertion lane and a change-aware deep lane of three `deep-safety (...)` jobs: the consumer-smoke and residue legs run for every deep selection, the sharded complete consumer replay runs when the consumer shape or the lane itself changes (and on every main push and scheduled run), and the self-test legs run when an affected wrapper is enrolled in them. Pull requests that change CI implementation, propagation, or tests select the wrappers the dependency graph declares for those paths, or fail closed to the complete surface when a path is undeclared; governance documents and specifications request the deep legs in smoke mode. Main pushes, the daily schedule, and manual runs always select the complete surface. Do not add path filters to the aggregator itself: every pull-request head must publish exactly one stable `lint` result, and the aggregator must keep reading every deep job's result against the scope bit that selected it.

When you add a `tests/test_*` reference to a wrapper that the graph declares, declare that test under the wrapper in `scripts/ci/repo-lint-dependencies.json`; when you enrol a new `--self-test` step in the workflow, add the wrapper to the graph's `self_tests` list. `tests/test_repo_lint_optimization.sh` fails lint-fast on the hub until both are in step.

The fast lane is itself a shard matrix balanced by measured step time: a new check step in `lint_fast` is pinned to exactly one shard with `if: matrix.shard == N` (pick the shard with the smallest measured sum), and `tests/test_repo_lint_optimization.sh` fails on an unpinned check or a pin naming a shard the matrix does not declare.

Checks with separable repository assertions and implementation regression suites should expose explicit live and self-test modes. The fast lane invokes the live mode, deep CI invokes the self-test mode, and the no-argument behavior remains compatible for consumers during propagation skew. The canonical contract and regression coverage live in `specs/repo_lint_execution.md` and `tests/test_repo_lint_optimization.sh`.

## Feedback snapshot recovery

For Codex P1 workflow changes, run `tests/test_codex_p1_workflow_runtime.sh` and `scripts/ci/check_codex_p1_gate` with an outer timeout. The runtime suite extracts the checked-in event preparation/closing steps and scheduled loop, invokes them with the Actions default `bash -e` shell behavior, and verifies the native execution result together with the original lease. Cover stable blocked and configuration-error verdicts in the positive-reference-absence bootstrap window, plus missing/non-executable scheduled drivers across multiple readable PRs. A green check from a separate producer does not prove recovery. Exercise publisher launch failures and timeout/exit races in both event and scheduled paths, checking original-lease closure, the three-attempt failure-only reserve, and honest infrastructure status for unclosed leases. Preserve baseline failure receipts and known-bad controls for both snapshot comparisons; installed consumer acceptance follows canonical propagation and remains separate from hermetic transport evidence.
