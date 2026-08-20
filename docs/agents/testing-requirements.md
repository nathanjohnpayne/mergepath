# Testing Requirements

- Update tests when behavior changes.
- Do not delete tests to make a build pass.
- Every spec file should have a corresponding test file or a documented exception explaining why one does not exist.

Replace this section with project-specific coverage requirements.

## Repo-lint execution

The required `lint` context is an aggregator over a fast live-assertion lane and a change-aware deep-safety matrix. Pull requests that change CI, governance, propagation, tests, or their specifications run both isolated deep-safety matrix legs; other pull requests keep those exhaustive consumer and residue regression nets off the required critical path. Main pushes, the daily schedule, and manual runs always select deep CI. Do not add path filters to the aggregator itself: every pull-request head must publish exactly one stable `lint` result.

Checks with separable repository assertions and implementation regression suites should expose explicit live and self-test modes. The fast lane invokes the live mode, deep CI invokes the self-test mode, and the no-argument behavior remains compatible for consumers during propagation skew. The canonical contract and regression coverage live in `specs/repo_lint_execution.md` and `tests/test_repo_lint_optimization.sh`.
