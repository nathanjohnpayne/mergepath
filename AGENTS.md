# AGENTS.md

Agent instructions are organized into focused sub-files under `docs/agents/`. Read the relevant file(s) before taking action in this repository.

## Sections

1. **[Repository Overview](docs/agents/repository-overview.md)** --- Project description, tech stack, agent role
2. **[Agent Operating Rules](docs/agents/operating-rules.md)** --- Reading order, conflict resolution
3. **[Code Modification Rules](docs/agents/code-modification-rules.md)** --- File creation, duplication, directory constraints
4. **[Documentation Rules](docs/agents/documentation-rules.md)** --- When and what to update
5. **[Testing Requirements](docs/agents/testing-requirements.md)** --- Coverage expectations, test deletion policy
6. **[Deployment Process](docs/agents/deployment-process.md)** --- Build/deploy flow, 1Password-backed auth

## Code Review Policy

This repository uses a multi-identity AI agent code review system. The full policy is in REVIEW_POLICY.md. The per-repo configuration is in .github/review-policy.yml.

### Identity Rules

- All agents author and commit code as nathanjohnpayne.
- Each agent reviews code under its own reviewer identity (e.g., nathanpayne-claude, nathanpayne-cursor, nathanpayne-codex).
- An agent never reviews code under the same identity that authored it.
- Only nathanjohnpayne merges to the target branch.

### Workflow Summary

1. Author code as nathanjohnpayne. File a PR.
2. Switch to your reviewer identity (e.g., nathanpayne-claude). Review the PR. Post comments.
3. Switch back to nathanjohnpayne. Address each comment. Push fix commits.
4. Repeat steps 2–3 until the reviewer identity approves with no outstanding issues.
5. If this repo has `coderabbit.enabled: true` in `.github/review-policy.yml`, read CodeRabbit's automated review comments and address substantive findings before proceeding. CodeRabbit review is advisory and does not block merge.
6. Check .github/review-policy.yml for the external review threshold. If the PR meets the threshold (lines changed >= external_review_threshold OR files match external_review_paths), post a handoff message (see REVIEW_POLICY.md for format) and alert the human.
7. If external review is not required, merge as nathanjohnpayne.
8. If external review is required, wait for the human to relay external reviewer feedback. Resolve all issues through back-and-forth until the external reviewer approves.
9. If the external reviewer flags observations or risks while approving, create a GitHub Issue for each one assigned to nathanjohnpayne with labels "post-review" and "observation" or "risk" before merging.
10. Merge as nathanjohnpayne.

### Disagreements

If the internal reviewer and external reviewer disagree, the human is the tiebreaker. Surface both positions clearly and wait.

### Adding a New Agent

1. Create a GitHub account: nathanpayne-{agent}
2. Add it to available_reviewers in .github/review-policy.yml.
3. Configure the agent environment with credentials for both nathanjohnpayne and the new reviewer identity.

For the complete policy including the handoff message format, post-merge issue creation rules, and git identity switching instructions, read REVIEW_POLICY.md.
