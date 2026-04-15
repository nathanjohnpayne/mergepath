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

## Session start (run once)

0. Run credential preflight to front-load all biometric prompts:
   `eval "$(scripts/op-preflight.sh --agent claude --mode all)"`
   This caches PATs and deploy credentials. All subsequent steps use
   `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT"` (reviewer) or
   `GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"` (author) instead of `op read`.
   If preflight was not run, fall back to inline `op read` (original pattern).

## Before opening a PR

1. Include `Authoring-Agent: claude` (or cursor/codex) in the PR description.
2. Include a `## Self-Review` section covering: correctness, regression risk,
   style, test coverage, and security/dependency hygiene.
3. The PreToolUse hook (`scripts/hooks/gh-pr-guard.sh`) will block `gh pr create`
   if either field is missing.

## After opening the PR

4. Switch to your reviewer identity (e.g., nathanpayne-claude).
   If preflight was run: `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT"` (no biometric).
   Otherwise: `GH_TOKEN="$(op read 'op://Private/<item-id>/token')"`.
   See REVIEW_POLICY.md § PAT lookup table for your agent's item ID.
5. Review the PR. Post comments on any issues found.
6. Switch back to nathanjohnpayne. Address each comment. Push fix commits.
7. Repeat steps 4–6 until the reviewer identity approves.
7.5. If `.github/review-policy.yml` has `coderabbit.enabled: true`:
     a. Wait for CodeRabbit to post (up to 3 min; ask human if delayed).
     b. Read PR-level comments: `gh api repos/{owner}/{repo}/issues/{pr}/comments`
     c. Read inline diff comments: `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
     d. Grep inline comments for `Potential issue` or `⚠️` — address each one.
     e. Fix real issues; dismiss false positives with a brief reply.
     CodeRabbit is advisory and does not block merge.

## Before merging

8. Check `.github/review-policy.yml` for the external review threshold.
   If the PR does NOT meet it (lines changed < `external_review_threshold`
   AND no file matches `external_review_paths`), merge as nathanjohnpayne.
   Done.

9. If the PR meets the threshold, it enters Phase 4 external review.
   See REVIEW_POLICY.md § Phase 4 for the canonical procedure. Short form:

   **Phase 4a — Automated (preferred).** Applies when ALL of the
   following are true:

   - `codex.enabled: true` in `.github/review-policy.yml`
   - BOTH `scripts/codex-review-request.sh` AND
     `scripts/codex-review-check.sh` exist on disk
   - The **ChatGPT Codex Connector GitHub App is review-ready on this
     repository**. "Review-ready" is strictly stronger than
     "installed": the App must be installed, Code Review must be
     enabled at
     [chatgpt.com/codex/cloud/settings/code-review](https://chatgpt.com/codex/cloud/settings/code-review),
     AND a Codex environment must be configured at
     [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments).
     Without the environment, Codex may post a "create an environment
     for this repo" comment instead of a review, even though the App
     is present (observed on PR #62 on 2026-04-14). Treat the App as
     not review-ready until all three pieces are in place.

     **Verification from an agent identity.** The only reliable check
     is observational: has a recent PR in this repo received an
     auto-review from `chatgpt-codex-connector[bot]` within the last
     few hours? If yes, the App is review-ready. If no, check the
     two settings pages above manually, or test with a small throwaway
     PR before routing real work through Phase 4a. **Do NOT use
     `gh api repos/{owner}/{repo}/installation`** as a check — that
     endpoint requires a GitHub App JWT and returns `401 "A JSON web
     token could not be decoded"` for normal user/reviewer PATs.

   If any of these conditions is false (Codex not enabled, either
   helper script missing, or the Codex App is not review-ready), fall
   back to Phase 4b directly rather than entering 4a and stalling:

   a. Run `scripts/codex-review-request.sh <PR#>`. It posts `@codex review`
      (or skips the trigger if Codex already auto-reviewed on open) and
      polls for a response from `chatgpt-codex-connector[bot]`.
   b. Parse the JSON output. Address each P0/P1 inline finding by either
      fixing the code and pushing a new commit, OR posting a reply on the
      finding thread with a clear rebuttal. Increment the round counter.
   c. Re-run `scripts/codex-review-request.sh` for the next round. Loop
      until Codex clears: a `COMMENTED` review with no unaddressed
      **P0/P1** findings on the current HEAD (P2 and P3 findings do NOT
      block clearance — address them at the agent's judgment), OR a
      👍 reaction on the PR issue.
   d. On exit code `4` (FALLBACK_REQUIRED, timeout), stop 4a and drop to
      Phase 4b below.
   e. On disagreement (repeat-after-rebuttal) or runaway (round counter
      exceeds `codex.max_review_rounds`), escalate per REVIEW_POLICY.md
      § Disagreements and Tiebreaking: stop the loop, post a summary
      comment on the PR with both positions, alert the human, do NOT merge.
   f. On clearance, run `scripts/codex-review-check.sh <PR#>` to verify
      the merge gate (CI green + internal reviewer approved + Codex
      cleared on current HEAD). The merge gate does NOT require an
      `APPROVED` review state from the Codex bot — the app never emits
      one. If the gate passes, merge as nathanjohnpayne with
      `gh pr merge --squash --delete-branch`.

   **Phase 4b — Manual CLI fallback.** Applies when Phase 4a is
   unavailable (`codex.enabled: false`, either helper script missing,
   Codex App not review-ready, or 4a fell back via exit code 4):

   a. Post the handoff message per REVIEW_POLICY.md § Handoff Message
      Format as a PR comment.
   b. Alert the human via chat. The human takes the handoff to a
      different agent CLI session (typically `nathanpayne-codex`), which
      posts an external review.
   c. Address feedback via the usual nathanjohnpayne commit loop.
   d. Wait for the external reviewer identity to post an `APPROVED` review.
   e. If the external reviewer flags observations or risks, file the
      post-merge GitHub Issues per step 11 below.
   f. Merge as nathanjohnpayne.

10. Never use `--admin` to merge unless the human explicitly authorizes it
    in chat as a break-glass exception. The hook will block it otherwise.

## After merging

11. If the reviewer flagged observations or risks while approving, create a
    GitHub Issue for each one (labels: post-review, observation/risk).

Full policy: REVIEW_POLICY.md | Config: .github/review-policy.yml | Summary: AGENTS.md § Code Review Policy
