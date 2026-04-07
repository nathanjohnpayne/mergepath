Read these files before taking any action in this repository:

1. `AGENTS.md` — behavioral rules and operating instructions
2. `rules/repo_rules.md` — binding structural constraints
3. Relevant `specs/` files — intended system behavior
4. `DEPLOYMENT.md` — deploy process and credential setup
5. `.ai_context.md` — supplemental context

If any of these files are missing, flag the gap before proceeding.

# Code Review — Mandatory Checklist

Never push directly to `main`. All changes must go through a pull request.

Every PR you open must follow this workflow. No exceptions unless the human
explicitly authorizes a break-glass override in chat.

## Before opening a PR

1. Include `Authoring-Agent: claude` (or cursor/codex) in the PR description.
2. Include a `## Self-Review` section covering: correctness, regression risk,
   style, test coverage, and security/dependency hygiene.
3. The PreToolUse hook (`scripts/hooks/gh-pr-guard.sh`) will block `gh pr create`
   if either field is missing.

## After opening the PR

4. Switch to your reviewer identity (e.g., nathanpayne-claude).
   Use `GH_TOKEN="$(op read 'op://Private/<item-id>/token')"` to authenticate
   API calls. See REVIEW_POLICY.md § PAT lookup table for your agent's item ID.
5. Review the PR. Post comments on any issues found.
6. Switch back to nathanjohnpayne. Address each comment. Push fix commits.
7. Repeat steps 4–6 until the reviewer identity approves.
7.5. If `.github/review-policy.yml` has `coderabbit.enabled: true`, read
     CodeRabbit's review comments and address substantive findings. Fix real
     issues; dismiss false positives with a brief reply. CodeRabbit is advisory
     and does not block merge.

## Before merging

8. Check `.github/review-policy.yml` for the external review threshold.
   If the PR meets the threshold (lines changed ≥ threshold OR files match
   external_review_paths), post the handoff message and alert the human.
   Do NOT merge — wait for external review.
9. If external review is not required, merge as nathanjohnpayne.
10. Never use `--admin` to merge unless the human explicitly authorizes it
    in chat as a break-glass exception. The hook will block it otherwise.

## After merging

11. If the reviewer flagged observations or risks while approving, create a
    GitHub Issue for each one (labels: post-review, observation/risk).

Full policy: REVIEW_POLICY.md | Config: .github/review-policy.yml | Summary: AGENTS.md § Code Review Policy
