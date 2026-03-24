# Code Review Requirements

All AI-generated code must undergo peer review before merge.

## Self-Review (Required for Every PR)

Before opening or updating a pull request, perform a structured self-review and include it in the PR description under a `## Self-Review` heading covering:

- Correctness against the stated requirements or ticket
- Regression risk—does this change break existing behavior?
- Style and convention adherence per this repository's standards
- Test coverage—are new paths tested and existing tests still passing?
- Security and dependency hygiene

## External Peer Review

External review is required when any of the following apply:

- The PR touches more than 300 lines of non-generated code
- The PR modifies shared infrastructure, CI/CD pipelines, or dependency versions
- The PR introduces a new architectural pattern or departs from an established one
- The PR affects authentication, authorization, or data handling
- Your confidence in any portion of the change is below high

When external review is required, explicitly request it by tagging the appropriate reviewer(s) and do not self-merge. Include a `## Review Guidance` section in the PR description flagging specific areas where human judgment is needed and why.

## Rules

- Never remove the `needs-external-review` or `needs-human-review` labels from a PR. Only a human reviewer may remove them.
- Never approve your own PR. Self-approvals are automatically dismissed and labeled `policy-violation`.
- PRs missing the `## Self-Review` section will be blocked by CI.
- PRs labeled `needs-external-review`, `needs-human-review`, or `policy-violation` cannot be merged until the label is resolved.
- When your PR is labeled `needs-external-review`, push a review guidance branch (`review/pr-{number}-guidance`) with a `reviews/pr-{number}-guidance.md` file using the template at `.github/templates/review-guidance.md`.
- Cross-agent review rotation: Claude → Codex → Cursor → Claude. You will be auto-assigned as a reviewer on other agents' PRs.
