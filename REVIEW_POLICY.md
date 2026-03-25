# AI Agent Code Review Policy

## Overview

This policy governs how AI coding agents author, review, and merge code across repositories owned by the `nathanjohnpayne` GitHub account. It enforces a structured peer review process where a single agent performs both authoring and self-review under separate GitHub identities, with mandatory external review by a different agent when complexity thresholds are met. All review activity occurs through GitHub PRs, producing a complete audit trail indistinguishable from multi-developer collaboration.

## Identities

### Author Identity

All agents commit and push code under a single shared author identity:

- **GitHub ID:** `nathanjohnpayne`
- **Role:** Author, committer, and merger for all code changes
- **Used by:** Whichever agent is currently writing or fixing code

### Reviewer Identities

Each agent has a dedicated reviewer identity used exclusively for code review:

| Agent | Reviewer Identity |
|-------|-------------------|
| Claude | `nathanpayne-claude` |
| Cursor | `nathanpayne-cursor` |
| Codex | `nathanpayne-codex` |

To add a new agent, register a GitHub account following the pattern `nathanpayne-{agent}` and add it to the `available_reviewers` list in the repo's `review-policy.yml`.

### Identity Rules

- An agent **never** reviews its own code under the same identity that authored it.
- The author identity (`nathanjohnpayne`) is always the one that merges to the target branch.
- Reviewer identities only post review comments, request changes, and approve PRs. They do not merge.

## Workflow

### Phase 1: Authoring

1. The agent creates a feature branch from the target branch (e.g., `main`).
2. The agent writes code as `nathanjohnpayne`, following all project-level rules (linting, testing, conventions).
3. The agent files a PR from the feature branch to the target branch under `nathanjohnpayne`. The PR description must include an `Authoring-Agent:` line identifying which agent wrote the code (e.g., `Authoring-Agent: claude`). This is required because all PRs share the `nathanjohnpayne` author identity, and the workflow uses this line to assign the correct reviewer identity for internal self-peer review.

### Phase 2: Internal Review (Self-Peer Review)

4. The agent switches its Git identity to its reviewer account (e.g., `nathanpayne-claude`).
5. The reviewer identity checks out the PR branch, reviews the diff, and posts review comments on the PR with specific, actionable feedback.
6. The agent switches back to `nathanjohnpayne` and addresses each comment—pushing fix commits to the same branch.
7. Steps 4–6 repeat until the reviewer identity approves the PR with no outstanding issues.

**All review rounds are captured as GitHub PR comments and commits.** The back-and-forth should read like two developers collaborating.

### Phase 3: External Review Threshold Check

> **Note on automation timing:** CI workflows may apply the `needs-external-review` label automatically when a PR is opened or updated, as an early advisory based on line count and protected paths. This label blocks merge immediately. The agent's responsibility is to post the handoff message and alert the human after internal review passes—the label itself may already be present.

8. After internal review passes, the agent evaluates whether the PR meets the external review threshold (see [Review Policy Configuration](#review-policy-configuration)).
9. If the threshold is **not** met, the agent merges the PR as `nathanjohnpayne`. Done.
10. If the threshold **is** met, the agent posts a **handoff message** (see [Handoff Message Format](#handoff-message-format)) as a PR comment and alerts the human.

### Phase 4: External Review

11. The human takes the handoff message to a different agent (e.g., from Claude to Cursor, or from Cursor to Codex).
12. The external agent's reviewer identity (e.g., `nathanpayne-codex`) reviews the PR and posts comments.
13. The human relays the external reviewer's feedback back to the originating agent.
14. The originating agent, as `nathanjohnpayne`, addresses the feedback and pushes fixes.
15. The human shuttles updated code back to the external reviewer.
16. Steps 12–15 repeat until the external reviewer approves.
17. If the external reviewer flags **observations** or **risks** while approving, those are converted to GitHub Issues on the repo, assigned to `nathanjohnpayne` (see [Post-Merge Issue Creation](#post-merge-issue-creation)).
18. `nathanjohnpayne` merges the PR. Done.

### Flow Diagram

```
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 1: AUTHOR                                        │
  │  Agent writes code as nathanjohnpayne → files PR         │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 2: INTERNAL REVIEW                                │
  │  Agent switches to nathanpayne-{agent}                   │
  │  Reviews PR → posts comments                             │
  │  Agent switches to nathanjohnpayne → fixes               │
  │  ↻ Repeat until approved                                 │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 3: THRESHOLD CHECK                                │
  │  Lines changed ≥ threshold OR protected paths touched?   │
  │                                                          │
  │  NO ──→ nathanjohnpayne merges. Done.                    │
  │  YES ──→ Post handoff message. Alert human.              │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 4: EXTERNAL REVIEW                                │
  │  Human hands PR to different agent                       │
  │  External nathanpayne-{agent} reviews → posts comments   │
  │  Human relays feedback to original agent                 │
  │  nathanjohnpayne fixes → human relays back               │
  │  ↻ Repeat until external reviewer approves               │
  │                                                          │
  │  Observations/risks → GitHub Issues                      │
  │  nathanjohnpayne merges. Done.                           │
  └─────────────────────────────────────────────────────────┘
```

## Handoff Message Format

When external review is required, the originating agent posts a PR comment and surfaces the following to the human:

```
## External Review Required

**PR:** #{pr_number} — {pr_title}
**Branch:** {branch_name}
**Author Agent:** {originating_agent}

### Summary
{2–4 sentence summary of what changed and why}

### Focus Areas
- {specific area 1 the external reviewer should scrutinize}
- {specific area 2}
- {specific area 3, if applicable}

### Observations from Internal Review
- {any concerns, trade-offs, or risks flagged during self-review}

### Suggested External Reviewer
nathanpayne-{suggested_agent}

### Rationale for External Review
{why the threshold was triggered: line count, protected paths, or both}
```

The human uses this message to brief the external agent. The external agent does not need access to the internal review thread—the handoff message contains everything needed to begin.

## Post-Merge Issue Creation

When an external reviewer approves a PR but flags observations or risks, the merging agent creates a GitHub Issue for each item before or immediately after merging:

- **Title:** `[Post-Review] {brief description of observation/risk}`
- **Body:** Full context from the reviewer's comment, including the PR number and relevant code references
- **Assignee:** `nathanjohnpayne`
- **Labels:** `post-review`, `observation` or `risk` as appropriate

These issues are tracked like any other work item. They are not blockers to the merge—the external reviewer has approved—but they represent acknowledged technical debt or areas requiring follow-up.

## Disagreements and Tiebreaking

If the internal reviewer and external reviewer disagree on whether code is ready to merge, the human is the tiebreaker. The agent should surface the disagreement clearly, summarizing both positions, and wait for the human's decision.

## Review Policy Configuration

Each repository contains a `.github/review-policy.yml` file that governs review behavior. This file is read by the agent at the start of every review cycle.

The following is an **illustrative example with default values**. Each repository's actual `.github/review-policy.yml` may have different `external_review_paths` customized to its directory structure. Always read the repo's actual file, not this example.

```yaml
# .github/review-policy.yml (example defaults — actual config may differ)

# Lines changed (additions + deletions, excluding generated/lockfiles) that trigger external review.
# Set to 0 to require external review on every PR.
# Set to a very high number to effectively disable.
external_review_threshold: 300

# Paths that always require external review regardless of line count.
# Glob patterns supported.
external_review_paths:
  - "src/auth/**"
  - "src/payments/**"
  - "**/*secret*"
  - "**/*credential*"
  - ".github/**"

# Registered reviewer identities. Add new agents here.
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex

# Default suggestion when the agent needs to recommend an external reviewer.
# The agent may override this suggestion based on context.
default_external_reviewer: nathanpayne-codex
```

### Threshold Evaluation

A PR requires external review if **either** condition is true:

1. Total non-generated lines changed (additions + deletions) ≥ `external_review_threshold`. Lockfiles (`*.lock`, `*lock.json`), minified files (`*.min.js`, `*.min.css`), and generated files (`*.generated.*`) are excluded from the count.
2. Any file in the PR diff matches a pattern in `external_review_paths`

The agent evaluates this after internal review passes, before merging. CI workflows may also evaluate and label earlier as an advisory (see Phase 3 note above).

## Git Identity Switching

Agents must automate identity switching so that commits and PR activity are attributed to the correct GitHub account. The mechanism depends on the agent's environment, but the result must be:

- Commits during authoring use `nathanjohnpayne`'s name and email.
- Review comments and PR reviews are posted via `nathanpayne-{agent}`'s GitHub credentials.
- The switch is fully automated within the agent session—no human intervention required for internal review.

Example (Git CLI):

```bash
# Switch to author identity
git config user.name "nathanjohnpayne"
git config user.email "nathan@nathanjohnpayne.example"

# Switch to reviewer identity
git config user.name "nathanpayne-claude"
git config user.email "claude@nathanpayne-claude.example"
```

Authentication for posting PR reviews under the reviewer identity requires a personal access token or GitHub App token for that account, configured in the agent's environment.

## Adding a New Agent

1. Create a GitHub account: `nathanpayne-{agent}`
2. Generate a personal access token with `repo` scope for the new account.
3. Add the identity to `available_reviewers` in each relevant repo's `.github/review-policy.yml`.
4. Configure the new agent's environment with both the `nathanjohnpayne` author credentials and the `nathanpayne-{agent}` reviewer credentials.
5. The new agent follows the same workflow described above.

## Template Usage

This policy and the accompanying `review-policy.yml` should be included in every new repository created under `nathanjohnpayne`. To bootstrap a new repo:

1. Copy `.github/review-policy.yml` into the new repo's `.github/` directory.
2. Copy this document into the repo as `REVIEW_POLICY.md` (or the location specified by your project template).
3. Adjust `external_review_threshold`, `external_review_paths`, and `default_external_reviewer` to fit the project.
4. Ensure all agent environments have credentials configured for the repo.
