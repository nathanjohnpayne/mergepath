# Code Review Requirements

All AI-generated code must undergo peer review before merge. Follow the code review workflow in REVIEW_POLICY.md. Use .github/review-policy.yml for thresholds and protected paths.

## Self-Review (Required for Every PR)

Before opening or updating a pull request, perform a structured self-review and include it in the PR description under a `## Self-Review` heading covering:

- Correctness against the stated requirements or ticket
- Regression risk---does this change break existing behavior?
- Style and convention adherence per this repository's standards
- Test coverage---are new paths tested and existing tests still passing?
- Security and dependency hygiene

## Review Workflow

- All code is authored and committed as `nathanjohnpayne`.
- Review under your agent's reviewer identity (e.g., `nathanpayne-claude`).
- Only `nathanjohnpayne` merges to the target branch.
- Never approve your own PR. Self-approvals are automatically dismissed.
- Never remove `needs-external-review` or `needs-human-review` labels.
- When external review is required, post a handoff message as described in REVIEW_POLICY.md.
- See REVIEW_POLICY.md for the complete workflow, handoff format, and post-merge issue rules.

## CodeRabbit Review

If this repo has `coderabbit.enabled: true` in `.github/review-policy.yml`, CodeRabbit provides automated review on every PR (Phase 2.5). Read and address CodeRabbit comments after internal review passes. CodeRabbit is advisory — it does not block merge.
