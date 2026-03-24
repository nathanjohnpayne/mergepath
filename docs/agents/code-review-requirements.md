# Code Review Requirements

All AI-generated code must undergo peer review before merge.

## Self-Review (Required for Every PR)

Before opening or updating a pull request, the authoring agent must perform a structured self-review covering:

- Correctness against the stated requirements or ticket
- Regression risk---does this change break existing behavior?
- Style and convention adherence per this repository's standards
- Test coverage---are new paths tested and existing tests still passing?
- Security and dependency hygiene

The self-review summary must be included in the PR description under a `## Self-Review` heading.

## Review Tiers

### Standard PRs

Criteria: under 300 lines of non-generated code, no infra/auth/architecture triggers.

- One agent reviewer (not the author) may approve and merge.
- The author must not approve or merge their own PR.

### External-Review PRs

Criteria: 300+ lines, OR touches infra/CI/CD/deps, OR new architecture, OR auth/data handling, OR author confidence below high.

- The PR is auto-labeled `needs-external-review`.
- Two agent reviewers (neither the author) must both approve.
- The authoring agent pushes a `review/pr-{number}-guidance` branch with a structured review guidance document (see below).
- The second approving reviewer removes the `needs-external-review` label, unblocking merge.
- The author must not remove this label under any circumstances.

### Human-Escalated PRs

- If agent reviewers disagree (one approves, one requests changes), the PR is auto-labeled `needs-human-review`.
- If @nathanjohnpayne manually adds the `needs-human-review` label, agent-only merge is blocked.
- Only @nathanjohnpayne may remove `needs-human-review` and approve.

## Review Guidance (External Reviews Only)

When your PR is labeled `needs-external-review`, you must:

1. Create a branch named `review/pr-{number}-guidance` off the PR's head branch.
2. Add a file `reviews/pr-{number}-guidance.md` using the template at `.github/templates/review-guidance.md`.
3. Fill in all sections honestly---do not minimize risks or inflate confidence.
4. Push the branch. Do not open a PR for this branch; it is a reference artifact only.
5. Post a comment on the PR linking to the guidance file.

External reviewers must read the guidance document before starting their review.

## Agent Review Identities

AI agents post reviews under dedicated GitHub accounts:

| Agent | GitHub username |
|---|---|
| Claude | @nathanpayne-claude |
| Codex | @nathanpayne-codex |
| Cursor | @nathanpayne-cursor |

Cross-agent review rotation: Claude → Codex → Cursor → Claude. For external-review PRs, the second reviewer is the remaining agent not already involved.

## Enforcement

1. **CI gate:** A required status check validates that every PR description contains a `## Self-Review` section. PRs missing this section are blocked from merge.

2. **Auto-labeling:** A GitHub Actions workflow evaluates the PR against external review triggers (line count, file paths touching infrastructure or auth, dependency changes). PRs that meet any trigger are automatically labeled `needs-external-review`.

3. **Label gate:** PRs with `needs-external-review`, `needs-human-review`, or `policy-violation` labels are blocked from merge by a required status check.

4. **Self-approval block:** If an agent approves its own PR, the approval is automatically dismissed and the PR is labeled `policy-violation`.

5. **Disagreement escalation:** If one agent reviewer approves and another requests changes, the PR is auto-labeled `needs-human-review` and @nathanjohnpayne is notified.

6. **No self-removal of labels:** Agents must not remove the `needs-external-review` or `needs-human-review` labels. Only a human reviewer may remove them. Agent attempts to remove these labels are treated as policy violations.

7. **Post-merge audit:** A weekly automated audit checks merged PRs for policy compliance---missing self-reviews, missing approvals, or bypassed label gates. Violations are surfaced in an issue to @nathanjohnpayne.

8. **Violation handling:** PRs identified as policy violations in post-merge audit must be retroactively reviewed by a human within one business day. Repeat violations trigger a review of that agent's permissions and autonomy level. Escalation owner: @nathanjohnpayne.
