# Code Review Requirements

All AI-generated code must undergo peer review before merge.

## Self-Review (Required for Every PR)

Before opening or updating a pull request, the authoring agent must perform a structured self-review covering:

- Correctness against the stated requirements or ticket
- Regression risk—does this change break existing behavior?
- Style and convention adherence per this repository's standards
- Test coverage—are new paths tested and existing tests still passing?
- Security and dependency hygiene

The self-review summary must be included in the PR description under a `## Self-Review` heading.

## External Peer Review

External review is required when any of the following apply:

- The PR touches more than 300 lines of non-generated code
- The PR modifies shared infrastructure, CI/CD pipelines, or dependency versions
- The PR introduces a new architectural pattern or departs from an established one
- The PR affects authentication, authorization, or data handling
- The author agent's confidence in any portion of the change is below high

When external review is required, the agent must explicitly request it by tagging the appropriate reviewer(s) and must not self-merge. The PR description should include a `## Review Guidance` section that flags the specific areas where human judgment is needed and why.

## Review Tiers

See [docs/agents/code-review-requirements.md](../docs/agents/code-review-requirements.md) for full details on:
- **Standard PRs** — single agent reviewer
- **External-review PRs** — dual agent reviewers with review guidance branch
- **Human-escalated PRs** — agent disagreement or manual escalation by Nathan

## Enforcement

1. **CI gate:** A required status check must validate that every PR description contains a `## Self-Review` section. PRs missing this section will be blocked from merge at the CI level.

2. **Auto-labeling:** A CI step or GitHub Action must evaluate the PR against the external review triggers above (line count, file paths touching infrastructure or auth, dependency file changes). PRs that meet any trigger are automatically labeled `needs-external-review`. This label blocks merge until removed by an authorized reviewer.

3. **Label gate:** PRs with `needs-external-review`, `needs-human-review`, or `policy-violation` labels are blocked from merge by a required status check.

4. **Self-approval block:** If an agent approves its own PR, the approval is automatically dismissed and the PR is labeled `policy-violation`.

5. **Disagreement escalation:** If one agent reviewer approves and another requests changes, the PR is auto-labeled `needs-human-review` and @nathanjohnpayne is notified.

6. **No self-removal of labels:** Agents must not remove the `needs-external-review` or `needs-human-review` labels. Only a human reviewer may remove them after completing their review. Agent attempts to remove the label should be treated as a policy violation and logged.

7. **Post-merge audit:** On a recurring cadence (weekly), run an automated audit of merged PRs to catch any that bypassed review policy. Flag these in a report surfaced to Nathan Payne.

8. **Violation handling:** PRs identified as policy violations in post-merge audit must be retroactively reviewed by a human within one business day. Repeat violations from a specific agent configuration should trigger a review of that agent's permissions and autonomy level, up to and including restricting its ability to open PRs without pre-approval. Escalation owner: Nathan Payne.
