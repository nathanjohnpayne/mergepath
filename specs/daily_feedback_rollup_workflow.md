---
spec_id: daily_feedback_rollup_workflow
---

# Daily Feedback Rollup Workflow

`.github/workflows/daily-feedback-rollup.yml` accepts optional `since` and `until` dispatch inputs in `YYYY-MM-DD` form. Each non-empty value must identify a real Gregorian calendar date before the workflow invokes `scripts/daily-feedback-rollup.sh`; leap years follow the divisible-by-4 rule except century years not divisible by 400. Empty inputs remain omitted, preserving the scheduled defaults in the rollup script.

Dispatch values are passed to the shell through environment variables, validated before use, and forwarded as separately quoted arguments. A provided non-empty `dry_run` value must be `true` or `false`; empty or omitted values are valid, and only `true` adds `--dry-run`. Rejected inputs stop before the rollup script is invoked.

The native workflow regression is `tests/test_465_fail_closed.sh` D13. It extracts and executes the workflow's actual `Run rollup` step against a stub that records its arguments, covering accepted dates, rejected dates, environment-only bindings, quoting, dry-run handling, and empty scheduled inputs.
