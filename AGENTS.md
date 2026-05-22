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
- Agents may add `human-hold` to freeze a PR, but must never remove it. The label is human-remove-only and supersedes all merge paths.

### Workflow Summary

0. Run credential preflight at the start of every PR session. The
   canonical session-loop snippet (read-path GH_TOKEN, write-path
   active-keyring, author-write wrapper — full details in REVIEW_POLICY.md
   § Phase 0 and § PAT lookup table):

   ```bash
   # Session start (one biometric burst). Default --mode is `review`.
   eval "$(scripts/op-preflight.sh --agent {your-agent} --mode review)"

   # Every subsequent tool call (idempotent, NEVER prompts):
   eval "$(scripts/op-preflight.sh --agent {your-agent} --check)"

   # Read-path API call (uses cached PAT, no biometric):
   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login

   # Reviewer write path. The hook derives the expected reviewer from
   # GH_PR_GUARD_EXPECTED_REVIEWER, then MERGEPATH_AGENT, then claude;
   # when in doubt, use gh-as-reviewer.sh so the wrapper switches/verifies.
   gh pr review <PR#> --comment --body "..."
   GH_AS_REVIEWER_IDENTITY=nathanpayne-{your-agent} \
     scripts/gh-as-reviewer.sh -- gh pr review <PR#> --comment --body "..."

   # Author write (temporary switch via the gh-as-author.sh wrapper):
   scripts/gh-as-author.sh -- gh pr create ...
   ```

   `--check` (alias `--status`) is the lightweight re-validator: never
   invokes `op`, never warms SSH, exits non-zero on missing/stale
   cache. Set `OP_PREFLIGHT_QUIET=1` to collapse the cache-hit stderr
   block. The helper scripts (`coderabbit-wait.sh`,
   `codex-review-request.sh`, `codex-review-check.sh`,
   `resolve-pr-threads.sh`, `request-label-removal.sh`) auto-source
   the cache when `GH_TOKEN` is unset (#282), so the explicit
   `GH_TOKEN=...` prefix is optional once preflight has run.

   Set the gh keyring active account once per machine: `gh auth switch
   -u nathanpayne-{your-agent}`. Then read-path commands use
   `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT"`; write paths use the
   keyring active. Bare reviewer-byline writes (`gh pr comment`,
   `gh pr review`, `gh issue comment`) are blocked unless the active
   keyring account exactly matches the expected reviewer resolved from
   `GH_PR_GUARD_EXPECTED_REVIEWER`, then `MERGEPATH_AGENT`, then the
   `claude` default; use `scripts/gh-as-reviewer.sh` when the harness
   env is uncertain.
   For author-identity writes (PR create/merge/label edits), MUST
   wrap the call in `scripts/gh-as-author.sh -- gh pr create ...` — a
   single bash process that switches, runs, and switches back via
   `trap EXIT`. Splitting the sequence across two Bash tool calls
   lands the PR under the wrong identity (#241). The `gh-pr-guard.sh`
   PreToolUse hook now blocks `gh pr create` when the keyring's active
   is not `nathanjohnpayne`. See REVIEW_POLICY.md § Reviewer PAT Quick
   Start for the full convention and § Recovery: PR created under the
   wrong identity for what to do if a PR already landed under the
   wrong account.

   Run `scripts/op-preflight.sh --agent {your-agent} --purge` (or
   `--purge-all`) at end of session to delete the cached PATs.
1. Author code as nathanjohnpayne. File a PR.
2. Review the PR under your reviewer identity. With your agent identity active and either `MERGEPATH_AGENT={your-agent}` or `GH_PR_GUARD_EXPECTED_REVIEWER=nathanpayne-{your-agent}` set, bare `gh pr review <PR#> --comment --body "..."` attributes correctly. If the hook environment is uncertain, wrap the call with `GH_AS_REVIEWER_IDENTITY=nathanpayne-{your-agent} scripts/gh-as-reviewer.sh -- gh pr review ...`. Post comments.
3. Address each comment via fix commits (commits use git config, no gh auth involved — byline stays nathanjohnpayne).
4. Repeat steps 2–3 until the reviewer identity approves with no outstanding issues. The mechanism: for under-threshold PRs (step 6), `gh pr review --approve` from your reviewer identity is the intended path — it satisfies branch protection without bouncing a small PR to an external agent. For above-threshold PRs (step 7), post `gh pr review --comment` only; Phase 4 carries the cross-agent gate. See REVIEW_POLICY.md § No-self-approve scoping.
5. If this repo has `coderabbit.enabled: true` in `.github/review-policy.yml`:
   a. **Wait** for CodeRabbit to post its review on the current HEAD. Prefer `scripts/coderabbit-wait.sh <PR#>` over an ad-hoc poll — it anchors "cleared" on the HEAD committer date (closing the race that let auto-merge fire pre-CodeRabbit; see #136) and handles CodeRabbit's non-auto-retrying rate-limit state by parsing the published window and posting `@coderabbitai, try again.` itself (see #138). Exit codes: `0` cleared, `2` findings, `4` grace-window timeout (advisory — log and skip), `5` rate-limit stalled (alert the human, do not proceed).
   b. **Read both endpoints:** PR-level comments (`gh api repos/{owner}/{repo}/issues/{pr}/comments`) and inline diff comments (`gh api repos/{owner}/{repo}/pulls/{pr}/comments`).
   c. **Grep inline comments** for `Potential issue` or `⚠️` — these must each be explicitly addressed (fixed or dismissed with reasoning).
   d. Address other substantive findings. CodeRabbit review is advisory and does not block merge.
6. Check .github/review-policy.yml for the external review threshold. If the PR does NOT meet it (lines changed < external_review_threshold AND no file matches external_review_paths), merge as nathanjohnpayne. Done.
7. If the PR meets the threshold, proceed to Phase 4 (see REVIEW_POLICY.md § Phase 4). Before Phase 4a, consult `phase_4b_default` from `.github/review-policy.yml` (parsed and exported as `PHASE_4B_DEFAULT` by `scripts/codex-review-check.sh`). When set to `complex-changes`, run `scripts/phase-4b-classifier.sh <PR#>` between 4a clearance and merge — exit 1 means post the Phase 4b handoff and wait for an external CLI review; exit 0 means merge. Full detail in CLAUDE.md step 8.5 and REVIEW_POLICY.md § Phase 4b Triggers. Phase 4 has two legs:
   - **Phase 4a — Automated (preferred)** when ALL of: `codex.enabled: true` in `.github/review-policy.yml`, BOTH `scripts/codex-review-request.sh` AND `scripts/codex-review-check.sh` exist on disk, AND the **ChatGPT Codex Connector GitHub App is review-ready on this repo**. "Review-ready" means installed, Code Review enabled at [chatgpt.com/codex/cloud/settings/code-review](https://chatgpt.com/codex/cloud/settings/code-review), AND a Codex environment configured at [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments). Verify only by observation: did a recent PR in this repo receive an auto-review from `chatgpt-codex-connector[bot]`? That is the only reliable check from a reviewer PAT — `gh api repos/{owner}/{repo}/installation` requires a GitHub App JWT and returns 401 for normal tokens. Drive the Codex GitHub App review loop: post `@codex review` via the request script, address **P0/P1** findings (fix code or rebuttal reply — P2/P3 findings do NOT block clearance), loop up to `codex.max_review_rounds`. On clearance (COMMENTED review with no unaddressed P0/P1 findings on the current HEAD, OR 👍 reaction from `chatgpt-codex-connector[bot]`), run `scripts/codex-review-check.sh` to verify the merge gate and merge. On exit code 4 (timeout), drop to Phase 4b. On repeat-after-rebuttal or round > `max_review_rounds`, escalate per § Disagreements below. If any of the conditions is false (Codex App not review-ready, partial script rollout, or Codex disabled in config), fall back to Phase 4b directly rather than entering 4a and stalling.
   - **Phase 4b — Manual CLI fallback** when 4a is unavailable or 4a fell back. When `codex.enabled: false`, `scripts/codex-review-check.sh` ignores Codex bot reviews/reactions and requires this Phase 4b substitute path for gate (c). Post the handoff message (see REVIEW_POLICY.md § Handoff Message Format) as a PR comment, emit the chat-side handoff block per REVIEW_POLICY.md § Handoff Message Format § Chat-side handoff block before alerting the human, and wait for an external reviewer identity (e.g., nathanpayne-codex) to post an `APPROVED` review via a separate agent CLI session. Address feedback via back-and-forth.
8. If the external reviewer flags observations or risks while approving, create a GitHub Issue for each one assigned to nathanjohnpayne with labels "post-review" and "observation" or "risk" before merging.
9. Merge as nathanjohnpayne. Non-Dependabot auto-merge is opt-in only:
   it may merge PRs only with an `AUTHOR_MERGE_TOKEN` Actions secret
   that resolves to `nathanjohnpayne`; absent that secret, use
   `scripts/gh-as-author.sh -- gh pr merge ...`.

### Disagreements

If the internal reviewer and external reviewer disagree on whether code is ready to merge, the human is the tiebreaker. Surface both positions clearly and wait.

In Phase 4a specifically, the agent escalates automatically on either of two signals: **repeat-after-rebuttal** (Codex re-flags a finding after the agent posted a rebuttal reply) or **runaway rounds** (round counter exceeds `codex.max_review_rounds`, default 2). On escalation, the agent stops the loop, posts a comment on the PR summarizing both positions with links to the review rounds, alerts the human, and does not merge. Timeout (exit code `4` from `codex-review-request.sh`) is NOT a disagreement — it falls back to Phase 4b directly. Full detail in REVIEW_POLICY.md § Disagreements and Tiebreaking.

### Adding a New Agent

1. Create a GitHub account: nathanpayne-{agent}
2. Add it to available_reviewers in .github/review-policy.yml.
3. Configure the agent environment with credentials for both nathanjohnpayne and the new reviewer identity.

For the complete policy including the handoff message format, post-merge issue creation rules, and git identity switching instructions, read REVIEW_POLICY.md.
