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
  whoever owns the active keyring entry — read it with `gh config get
  -h github.com user`, NOT `gh auth status`. (`gh auth status` is
  GH_TOKEN-poisonable: when GH_TOKEN is set, it reports the GH_TOKEN
  entry as Active and the keyring entry as inactive, even though
  writes still attribute to the keyring.)

Each agent's working machine has the agent identity as the **active**
gh account, set once per machine: `gh auth switch -u nathanpayne-claude`
(substitute your agent identity). Both `nathanjohnpayne` (author) and
`nathanpayne-<agent>` (reviewer) must already be in the keyring (one-
time `gh auth login` per identity per machine). With this convention:

- Reviewer-identity writes (`gh pr review --comment` from your agent
  identity) just work — no `GH_TOKEN` switch, no `gh auth switch`.
- Author-identity writes (`gh pr create`, `gh pr merge`, `gh pr edit`
  for label changes) **MUST** use `scripts/gh-as-author.sh` — a single
  bash process that switches to the author identity, runs the wrapped
  command, then restores the prior active account via `trap EXIT`:

  ```bash
  scripts/gh-as-author.sh -- gh pr create --title "..." --body "..."
  scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch
  ```

  Bundling the switch + write + switch-back into one wrapper process
  is a HARD RULE, not a soft recommendation. Splitting the three
  steps across two or more Bash tool calls has been observed to land
  the PR under the wrong identity — see #241 (and the concrete
  incident on `friends-and-family-billing#262`) for the failure
  mechanism and consequences (self-approval blocked, policy
  fingerprint inversion, destructive recovery). The `gh-pr-guard.sh`
  PreToolUse hook now enforces this: a `gh pr create` while the
  keyring's active account is not `nathanjohnpayne` is blocked with
  a diagnostic pointing at `gh-as-author.sh`. The wrapper also runs
  a post-create `gh pr view --json author` verification to catch the
  failure within seconds if it slips through. If you ever need the
  unwrapped form, do it in one bash invocation:

  ```bash
  # Equivalent, only acceptable if gh-as-author.sh is unavailable for some reason:
  gh auth switch -u nathanjohnpayne && \
    gh pr merge <PR#> --squash --delete-branch && \
    gh auth switch -u nathanpayne-claude
  ```

`git commit` does NOT go through gh auth — it uses the local git
config (`user.name` / `user.email` set to the human author identity),
so commits keep attributing to nathanjohnpayne even when the gh
keyring active is your agent identity. No switch needed for commits.

## Session start (run once)

0. Run credential preflight to front-load all biometric prompts. The
   canonical session-loop snippet (see REVIEW_POLICY.md § Phase 0 for
   the full doc, and § PAT lookup table for the per-agent item IDs):

   ```bash
   # Session start (one biometric burst). Default --mode is `review`.
   eval "$(scripts/op-preflight.sh --agent claude --mode review)"

   # Every subsequent tool call (idempotent, NEVER prompts):
   eval "$(scripts/op-preflight.sh --agent claude --check)"

   # Read-path API call (uses cached PAT, no biometric):
   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login

   # Write-path API call (gh keyring active = nathanpayne-<agent>):
   gh pr review <PR#> --comment --body "..."

   # Author write (temporary switch via the gh-as-author.sh wrapper):
   scripts/gh-as-author.sh -- gh pr create ...
   ```

   The cache lives at `$XDG_CACHE_HOME/mergepath/op-preflight-claude.env`
   (default `$HOME/.cache/mergepath/`), chmod 600. The `--check` mode
   is a read-only validator: it never invokes `op`, never warms SSH,
   never reads ADC; on a missing/stale cache it exits non-zero with a
   pointer back at `--mode review`. Safe to re-run at the top of every
   tool call. Within the TTL (4h default, override via
   `OP_PREFLIGHT_TTL_SECONDS`) the script emits the cached exports
   without a new biometric prompt. Set `OP_PREFLIGHT_QUIET=1` to
   collapse the cache-hit stderr block to a single line.

   Run `scripts/op-preflight.sh --agent claude --purge` at end of
   session to wipe the cache. If preflight is unavailable (e.g.
   first-time bootstrap on a fresh machine), fall back to inline
   `op read` per REVIEW_POLICY.md § PAT lookup table > Fallback —
   every call triggers biometric, so use only for setup, never for
   routine work.

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
7. Repeat steps 4–6 until the reviewer identity approves. The mechanism
   of "approves" is scope-dependent (REVIEW_POLICY.md
   § No-self-approve scoping):
   - **Under-threshold PRs** (lines changed < `external_review_threshold`
     AND no file matches `external_review_paths`): the reviewer identity
     posts `gh pr review <PR#> --repo owner/repo --approve --body "..."`
     once CodeRabbit has cleared the current HEAD. This is the intended
     path — it satisfies branch protection's required-approving-review
     check without bouncing a small PR to an external agent.
   - **Above-threshold PRs**: the reviewer identity posts `--comment`
     only. Phase 4 (step 9 below) carries the cross-agent merge gate
     via Codex 👍 (4a) or external CLI reviewer's `APPROVED` (4b).
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

7.6. Resolve all open review threads on the current HEAD:

     ```bash
     scripts/resolve-pr-threads.sh <PR#>                       # list unresolved
     scripts/resolve-pr-threads.sh <PR#> --auto-resolve-bots   # resolve bots
     ```

     Branch protection on `main` typically requires
     `required_conversation_resolution: true`, which means **every
     review thread must be resolved before merge** — including
     CodeRabbit `🧹 Nitpick` / `🔵 Trivial` comments that don't block
     merge in CodeRabbit's own model. Without this step,
     `mergeStateStatus` stays `BLOCKED` even when all required CI
     checks are green and Codex has cleared. The blocker is invisible
     in `gh pr checks` output — only the GitHub UI surfaces it.

     For each unresolved bot-authored thread where you have already
     addressed the finding (fix on this HEAD, or rebuttal posted),
     `--auto-resolve-bots` clears it via the GraphQL
     `resolveReviewThread` mutation. Per
     `REVIEW_POLICY.md § Implementation notes for branch protection
     gates`, this is a clean-up mechanism, NOT a policy override —
     human-authored threads must be resolved via the GitHub UI or by
     asking the human; the helper refuses to touch them.

     **Rationale-tag emission (mergepath#305).** Before each resolve
     mutation, the helper posts a one-line reply on the thread with
     `[mergepath-resolve: <class>] <rationale>`. The v1 daily rollup
     classifier reads this tag and prioritizes it over its own
     heuristics, so unresolved-feedback rollups attribute resolves
     accurately instead of guessing from commit timestamps. Valid
     `<class>` values (taxonomy mirrored from
     `scripts/lib/daily-feedback-rollup-helpers.sh`). Listed in the
     ladder order the resolver actually applies (first match wins):

     - `canonical-coverage` — anchored path matches a canonical
       entry in `.mergepath-sync.yml` (propagated content). Wins
       over `addressed-elsewhere` because a finding on propagated
       canonical content is structurally a mergepath concern
       regardless of whether the local PR's fix commit also
       happened to touch the file.
     - `addressed-elsewhere` — fix-commit by an agent author after
       the comment's createdAt, touching the anchored file.
     - `rebuttal-recorded` — ≥30-char agent-authored reply already
       on the thread.
     - `nitpick-noted` — severity is Nitpick/Trivial/P3, no
       stronger signal applies.
     - `deferred-to-followup` — default fallback / `--rationale`
       override.

     The helper auto-classifies via the ladder above. To override
     for a manual case (e.g. deferring a P2 to a tracked follow-up
     issue), pass `--rationale "free-form text"` — class is forced
     to `deferred-to-followup` and the free-form text follows the
     tag verbatim. To suppress tag emission entirely (e.g. dry-
     rehearsing the resolve loop without polluting thread history),
     pass `--no-tag-reply`; the resolve mutation still runs.

     Tag-reply failure (network blip, mutation rejected) is logged
     and the resolve continues — losing the tag is a soft regression
     (the rollup falls back to its own heuristics), not a
     correctness bug.

     Examples:

     ```bash
     # Default — helper picks the class per the decision ladder.
     scripts/resolve-pr-threads.sh <PR#> --auto-resolve-bots

     # Manual override with custom rationale (forces deferred-to-followup).
     scripts/resolve-pr-threads.sh <PR#> --auto-resolve-bots \
         --rationale "P2 noted; deferred to mergepath canonical follow-up #280"

     # Suppress tag-reply (resolve only).
     scripts/resolve-pr-threads.sh <PR#> --auto-resolve-bots --no-tag-reply
     ```

     **Escape hatch — if the script reports clean but merge fails.**
     If `scripts/resolve-pr-threads.sh` exits 0 ("no unresolved
     threads") AND the merge attempt errors with `GraphQL: All
     comments must be resolved. (mergePullRequest)`, the script
     undercount detector either didn't fire or the threads endpoint
     is briefly inconsistent. Drop to the manual GraphQL query
     (note the `totalCount` check — the API caps at 100 nodes per
     page; without the assert, a >100-thread PR would silently
     truncate and mask threads):

     ```bash
     # Read-path: pin to preflight reviewer PAT per the auth split.
     GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api graphql -f query='
       query {
         repository(owner: "OWNER", name: "REPO") {
           pullRequest(number: PR_NUM) {
             reviewThreads(first: 100) {
               totalCount
               pageInfo { hasNextPage endCursor }
               nodes {
                 id
                 isResolved
                 comments(first: 1) {
                   nodes { author { login } path body }
                 }
               }
             }
           }
         }
       }' --jq '
         if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage
         then "ERROR: PR has >100 review threads; paginate with after:$endCursor"
              | halt_error(2)
         else .data.repository.pullRequest.reviewThreads.nodes
              | map(select(.isResolved != true))
         end
       '
     ```

     For each unresolved bot-authored thread where the finding is
     addressed on the current HEAD, resolve via (same PAT pinning
     as the read above — the mutation is reviewer-attributed):

     ```bash
     GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api graphql -f query='
       mutation { resolveReviewThread(input:
         {threadId: "THREAD_ID"}) { thread { isResolved } } }'
     ```

     Same agent-prohibitions apply: do not resolve human-authored
     threads via this path either. See #192 for the bug history.

## Before merging

8. Check `.github/review-policy.yml` for the external review threshold.
   If the PR does NOT meet it (lines changed < `external_review_threshold`
   AND no file matches `external_review_paths`), merge as nathanjohnpayne.
   Done.

8.5. Read `phase_4b_default` from `.github/review-policy.yml` (the
     parser is in `scripts/codex-review-check.sh`; it exports
     `PHASE_4B_DEFAULT` for downstream consumers). Three modes drive
     whether Phase 4b proactive triggers fire on the current PR. The
     taxonomy that the classifier evaluates is in REVIEW_POLICY.md
     § Phase 4b Triggers.

     - `fallback-only` (default for repos without the field): proceed
       to Phase 4a as today. Phase 4b only fires on 4a unavailability,
       timeout (exit code 4 from `codex-review-request.sh`), or
       escalation.
     - `complex-changes` (default for new repos including mergepath):
       run `scripts/phase-4b-classifier.sh <PR#>` AFTER Phase 4a
       clears but BEFORE merging. The classifier exits 0 (no 4b
       needed → merge), 1 (invoke-4b recommended → post the Phase 4b
       handoff per REVIEW_POLICY.md § Handoff Message Format and wait
       for the external CLI review), 2 (config/API error → stop and
       investigate), or 3 (bad args → fix the invocation).
     - `always`: skip the classifier; post the Phase 4b handoff
       unconditionally for any over-threshold PR.

     The classifier's recommendation is advisory but its exit code is
     load-bearing — agents should respect it rather than judging the
     diff themselves. Address P0/P1 findings from the resulting 4b
     review the same way as 4a findings (fix or rebut). On 4b
     clearance (the external reviewer identity posts an `APPROVED`
     review on the current HEAD with no unaddressed P0/P1 — same
     concrete criterion as the Phase 4b manual fallback below), merge
     as nathanjohnpayne.

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
      one.
   g. **Phase 4b checkpoint (do not skip).** Before the merge call,
      apply step 8.5: if `phase_4b_default` is `complex-changes`, run
      `scripts/phase-4b-classifier.sh <PR#>` and act on its exit code
      (1 → emit the chat-side handoff block per REVIEW_POLICY.md
      § Handoff Message Format § Chat-side handoff block, post the
      4b handoff, and wait for the external reviewer identity to post
      an `APPROVED` review on the current HEAD with no unaddressed
      P0/P1, then come back here; 0 → proceed to merge; 2 → stop and
      investigate; 3 → fix the invocation). If `phase_4b_default` is
      `always`, emit the chat-side handoff block per REVIEW_POLICY.md
      § Handoff Message Format § Chat-side handoff block, post the
      4b handoff unconditionally, and wait for the same external
      `APPROVED` condition before coming back to merge. If
      `fallback-only`, skip directly to merge.
   h. With the gate passing AND the 4b checkpoint cleared, merge as
      nathanjohnpayne via `scripts/gh-as-author.sh` per the active-
      account convention above (HARD RULE — splitting the switch +
      merge + switch-back across Bash tool calls has been observed
      to leave the keyring on the wrong identity, see #241):

      ```
      scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch
      ```

      The non-Dependabot `auto-merge-on-approval` workflow is only a
      convenience when `AUTHOR_MERGE_TOKEN` is configured and verified
      as `nathanjohnpayne`. Without that author-owned secret, auto-merge
      is disabled and this manual author-merge step is the expected path.

   **Phase 4b — Manual CLI fallback.** Applies when Phase 4a is
   unavailable (`codex.enabled: false`, either helper script missing,
   Codex App not review-ready, or 4a fell back via exit code 4):

   a. Post the handoff message per REVIEW_POLICY.md § Handoff Message
      Format as a PR comment.
   b. Emit the chat-side handoff block per REVIEW_POLICY.md
      § Handoff Message Format § Chat-side handoff block, then alert
      the human via chat. The human takes the handoff to a different
      agent CLI session (typically `nathanpayne-codex`), which posts
      an external review.
   c. Address feedback via the usual nathanjohnpayne commit loop.
   d. Wait for the external reviewer identity to post an `APPROVED` review.
   e. If the external reviewer flags observations or risks, file the
      post-merge GitHub Issues per step 11 below.
   f. Merge as nathanjohnpayne via `scripts/gh-as-author.sh` per the
      active-account convention above (HARD RULE per #241):
      `scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch`.
      Reviewer-identity tokens must not be used for automatic PR merges;
      an optional `AUTHOR_MERGE_TOKEN` may enable auto-merge only after
      the workflow verifies it resolves to `nathanjohnpayne`.

10. Never use `--admin` to merge unless the human explicitly authorizes it
    in chat as a break-glass exception. The hook will block it otherwise.

10.5. Before merging, verify `mergeStateStatus === "CLEAN"` (not
     `BLOCKED` or `UNSTABLE`). `BLOCKED` with an empty
     `gh pr checks` failure list almost always means an unresolved
     review thread — re-run step 7.6.

10.6. Never use `gh pr edit ... --remove-label` (or `--add-label`) for
     `needs-external-review`, `needs-human-review`, or
     `policy-violation`. Agents may add `human-hold` to freeze a PR,
     but must never remove it. These are human-action labels; the
     `scripts/hooks/label-removal-guard.sh` PreToolUse hook blocks
     prohibited calls regardless of chat authorization. To request
     removal, run: `scripts/request-label-removal.sh <PR#> <label>` —
     the human clears it from any device and the PR can proceed once
     the normal merge gates are green. See REVIEW_POLICY.md § Agent
     prohibitions.

     - For `needs-external-review` specifically, the auto-clear workflow
       (`.github/workflows/auto-clear-blocking-labels.yml`, #191/#195)
       usually removes the label automatically once `codex-review-check.sh`
       clears the merge gate on `pull_request_target` /
       `pull_request_review` / `workflow_run` events. A 15-min `schedule`
       sweep (#197) catches the 👍-after-last-push case where no
       event-driven trigger fires; opt-out via
       `auto_clear_labels.scheduled_sweep_enabled: false` in
       `.github/review-policy.yml`.
     - `request-label-removal.sh` is the fallback when no triggering
       event arrived AND the sweep hasn't yet fired (or the gate is
       genuinely not yet met).
     - `needs-human-review`, `policy-violation`, and `human-hold`
       remain manual-only by design. `human-hold` supersedes every
       merge path, including Codex clearance, reviewer approvals,
       Dependabot auto-merge, and break-glass agent merge variables.

## After merging

11. If the reviewer flagged observations or risks while approving, create a
    GitHub Issue for each one (labels: post-review, observation/risk).

Full policy: REVIEW_POLICY.md | Config: .github/review-policy.yml | Summary: AGENTS.md § Code Review Policy
