# AGENTS.md

Agent instructions are organized into focused sub-files under `docs/agents/`. Read the relevant file(s) before taking action in this repository.

## Sections

1. **[Repository Overview](docs/agents/repository-overview.md)** --- Project description, tech stack, agent role
2. **[Agent Operating Rules](docs/agents/operating-rules.md)** --- Reading order, conflict resolution
3. **[Code Modification Rules](docs/agents/code-modification-rules.md)** --- File creation, duplication, directory constraints
4. **[Documentation Rules](docs/agents/documentation-rules.md)** --- When and what to update
5. **[Testing Requirements](docs/agents/testing-requirements.md)** --- Coverage expectations, test deletion policy
6. **[Deployment Process](docs/agents/deployment-process.md)** --- Build/deploy flow, 1Password-backed auth
7. **[Code Review Requirements](docs/agents/code-review-requirements.md)** --- Self-review, external review triggers, enforcement

## PR Review Identities

AI agents post reviews under dedicated GitHub accounts:

| Agent | GitHub username |
|---|---|
| Claude | @nathanpayne-claude |
| Codex | @nathanpayne-codex |
| Cursor | @nathanpayne-cursor |

These are bot accounts owned by @nathanjohnpayne. All three have Write access for PR review purposes only.

### Review tiers

**Standard PRs** (under 300 lines of non-generated code, no infra/auth/architecture triggers):
- One agent reviewer (not the author) may approve and merge.
- The author must not approve or merge their own PR.

**External-review PRs** (300+ lines, or infra/CI/CD/dep changes, or new architecture, or auth/data handling, or low-confidence code):
- The PR is auto-labeled `needs-external-review`.
- Two agent reviewers (neither the author) must both approve.
- The authoring agent pushes a `review/pr-{number}-guidance` branch with a structured review guidance document.
- The second approving reviewer removes the `needs-external-review` label, unblocking merge.
- The author must not remove this label under any circumstances.

**Human-escalated PRs:**
- If agent reviewers disagree (one approves, one requests changes), the PR is auto-labeled `needs-human-review`.
- If @nathanjohnpayne manually adds the `needs-human-review` label, agent-only merge is blocked.
- Only @nathanjohnpayne may remove `needs-human-review` and approve.

### Subagent invocation

When assigned as a reviewer, agents should automatically begin their review. The GitHub Actions workflow will trigger the appropriate agent. If headless invocation is not available for an agent (e.g., Cursor), the review must be performed manually.

### Review protocol

- The authoring agent must **never** approve its own PR.
- Cross-agent review rotation: Claude → Codex → Cursor → Claude.
- For external-review PRs, the second reviewer is the remaining agent not already involved.
- @nathanjohnpayne may review, approve, or merge any PR at any tier.

### Review guidance (external reviews only)

When your PR is labeled `needs-external-review`, you must:

1. Create a branch named `review/pr-{number}-guidance` off the PR's head branch.
2. Add a file `reviews/pr-{number}-guidance.md` using the template at `.github/templates/review-guidance.md`.
3. Fill in all sections honestly—do not minimize risks or inflate confidence.
4. Push the branch. Do not open a PR for this branch; it is a reference artifact only.
5. Post a comment on the PR linking to the guidance file:
   `Review guidance: [{repo}/blob/review/pr-{number}-guidance/reviews/pr-{number}-guidance.md]`

External reviewers must read the guidance document before starting their review.
