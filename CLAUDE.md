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

## Active-account convention

`gh` resolves auth differently for read paths vs write paths:

- **Read paths** (`gh api user`, `gh api ...` GETs, `gh pr view`, `gh pr
  checks`) honor `GH_TOKEN` correctly. Set the env var per command and
  the request runs as whichever PAT you supply.
- **Write paths** that create reviews / comments / PRs / merges /
  label edits (`gh pr review`, `gh pr create`, `gh pr merge`,
  `gh pr edit`, `gh api -X POST repos/.../pulls/.../reviews`) use the
  keyring's **active** account regardless of `GH_TOKEN`. The byline is
  whoever `gh auth status` shows as `Active: true` when the call lands.

Each agent's working machine has the agent identity as the **active**
gh account, set once per machine: `gh auth switch -u nathanpayne-claude`
(substitute your agent identity). Both `nathanjohnpayne` (author) and
`nathanpayne-<agent>` (reviewer) must already be in the keyring (one-
time `gh auth login` per identity per machine). With this convention:

- Reviewer-identity writes (`gh pr review --comment` from your agent
  identity) just work — no `GH_TOKEN` switch, no `gh auth switch`.
- Author-identity writes (`gh pr create`, `gh pr merge`, `gh pr edit`
  for label changes) need a temporary switch-around so the byline is
  the author identity, paired with a switch-back so the active state
  never lingers wrong:

  ```bash
  gh auth switch -u nathanjohnpayne && \
    gh pr merge <PR#> --squash --delete-branch && \
    gh auth switch -u nathanpayne-claude
  ```

`git commit` does NOT go through gh auth — it uses the local git
config (`user.name` / `user.email` set to the human author identity),
so commits keep attributing to nathanjohnpayne even when the gh
keyring active is your agent identity. No switch needed for commits.

## Session start (run once)

0. Run credential preflight to front-load all biometric prompts:
   `eval "$(scripts/op-preflight.sh --agent claude --mode all)"`
   This caches PATs and deploy credentials in a chmod-600 session file
   at `$XDG_CACHE_HOME/mergepath/op-preflight-claude.env` (default
   `$HOME/.cache/mergepath/`). Safe to re-run at the top of every tool
   call — within the TTL (4h default, override via
   `OP_PREFLIGHT_TTL_SECONDS`) the script reads the session file and
   emits the same exports without a new biometric prompt. All subsequent
   steps use `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT"` (reviewer) or
   `GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"` (author) instead of `op read`.
   Run `scripts/op-preflight.sh --agent claude --purge` at end of
   session to wipe the cache. If preflight was not run (or failed), fall
   back to inline `op read` (original pattern).

## Before opening a PR

1. Include `Authoring-Agent: claude` (or cursor/codex) in the PR description.
2. Include a `## Self-Review` section covering: correctness, regression risk,
   style, test coverage, and security/dependency hygiene.
3. The PreToolUse hook (`scripts/hooks/gh-pr-guard.sh`) will block `gh pr create`
   if either field is missing.
4. Before claiming "CI passes": confirm each required workflow actually
   **ran and succeeded**, not that it was skipped. A `SKIPPED` result
   means the job was not executed (usually because an `if:` guard or
   a label excluded it) — it is not a verification signal. If you
   need to verify a change to a job that is currently skipped, either
   remove the guard temporarily to force a run, toggle
   draft→ready_for_review to re-fire event-guarded jobs, or
   acknowledge in the PR body that the fix has not been live-tested.
   See #59 for the regression this rule closes.

## After opening the PR

4. Review the PR under your reviewer identity. With your agent identity
   active per the convention above, just run:
   `gh pr review <PR#> --repo owner/repo --comment --body "..."`.
   The review is correctly attributed to the agent reviewer identity.
5. Post comments on any issues found.
6. Address each comment via fix commits (commits use git config, no
   gh auth involved — byline stays nathanjohnpayne).
7. Repeat steps 4–6 until the reviewer identity approves.
7.5. If `.github/review-policy.yml` has `coderabbit.enabled: true`:
     a. Wait for CodeRabbit to post on the current HEAD. Prefer
        `scripts/coderabbit-wait.sh <PR#>` over an ad-hoc poll — it
        anchors on HEAD committer date (closes the auto-merge race
        in #136) and handles CodeRabbit's non-auto-retrying rate-limit
        state (#138). Exit codes: 0 cleared, 2 findings, 4 grace-window
        timeout (log + skip, CodeRabbit is advisory), 5 rate-limit
        stalled (alert human, do not proceed).
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
      one. If the gate passes, merge as nathanjohnpayne with the
      switch-around per the active-account convention:
      `gh auth switch -u nathanjohnpayne && \
       gh pr merge <PR#> --squash --delete-branch && \
       gh auth switch -u nathanpayne-claude`

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
   f. Merge as nathanjohnpayne via the switch-around per the
      active-account convention (`gh auth switch -u nathanjohnpayne &&
      gh pr merge ... && gh auth switch -u nathanpayne-claude`).

10. Never use `--admin` to merge unless the human explicitly authorizes it
    in chat as a break-glass exception. The hook will block it otherwise.

## After merging

11. If the reviewer flagged observations or risks while approving, create a
    GitHub Issue for each one (labels: post-review, observation/risk).

Full policy: REVIEW_POLICY.md | Config: .github/review-policy.yml | Summary: AGENTS.md § Code Review Policy
