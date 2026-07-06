# Agent Operating Rules

Read in this order before taking any action:

1. `README.md` — understand the project
2. `AGENTS.md` — load behavioral instructions (index pointing to this directory)
3. `rules/repo_rules.md` — load binding constraints
4. Relevant `specs/` files — understand intended behavior
5. `.ai_context.md` — load supplemental context

If `docs/projects/<project>/prds/` exists in the repo, read the generated PRD mirror as product context. It is a generated mirror --- do not edit it directly; see `docs/agents/documentation-rules.md` § "Direct writes to documentation" for the repo-owned-vs-mirror boundary and the canonical edit path. Implementation behavior changes still belong in the owning repo's `specs/`, policy files, scripts, and tests.

Conflict resolution:

- If code conflicts with `specs/`: flag the conflict, update spec or tests first, then update code. Do not silently modify behavior.
- If a proposed change violates `rules/repo_rules.md`: stop and flag the violation. Do not proceed without resolution.
- If a tool folder contains instructions that conflict with `AGENTS.md` or these sub-files: follow the canonical docs and flag the duplication for removal.
- If `AGENTS.md` or its sub-files are missing required sections: flag the gap and do not assume behavior for missing sections.

## Always paginate PR comment / review / check-run list reads

Any `gh api` list read against a PR's comments, reviews, or check-runs MUST use `--paginate` (or, for a GraphQL connection, a cursor loop). This is not optional past round 1 of a Phase 4a review loop. `gh api` without `--paginate` fetches exactly one page --- 30 items by default, at most 100 with `per_page=100` --- and returns cleanly with no error or warning that more data exists. On a long-lived PR that has been through many review rounds, the current data routinely sits past that boundary, so an unpaginated read silently returns a stale or empty result that reads as "no new activity" or "no findings" when the opposite is true. This has repeatedly produced false all-clear conclusions and can silently defeat a merge gate (#691).

This applies to every hand-rolled, mid-session investigative query, not just the shipped helper scripts. An agent manually inspecting a PR's live state is the common case, and it is exactly the query that skips the paginated helpers. The endpoints that truncate, and the correct form:

- Inline diff comments --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/comments"`. By round 4+ a PR easily exceeds 30 of these (findings, plus replies, plus resolve-tool tag-replies), so the newest findings land on page 2 and an unpaginated read returns nothing for them.
- PR-level (issue) comments --- `gh api --paginate "repos/OWNER/REPO/issues/PR/comments"`. This is where a Codex clean verdict lands.
- Review objects --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/reviews"`. This is where a Codex findings round lands.
- Check-runs / commit statuses --- `gh api --paginate "repos/OWNER/REPO/commits/SHA/check-runs"` and `.../statuses`. A single head commit can accumulate 100+ check-runs from repeated scheduled-sweep re-evaluations (194 observed on #687), so even `per_page=100` without `--paginate` silently drops a live failure onto page 2.

`gh pr view --json comments|reviews|statusCheckRollup` has the same trap and CANNOT be fixed with `--paginate`: the `--json` GraphQL shape caps each connection at the first 100 entries and strips the `pageInfo` you would need even to detect the truncation. For any connection that can exceed 100 (check-runs above all), read the REST endpoint with `gh api --paginate`, or walk the GraphQL connection with a Relay cursor loop --- see the `statusCheckRollup` cursor loops in `scripts/codex-review-check.sh` and `scripts/admin-merge-codeowners-blocked.sh`. A single-item read (`repos/.../issues/comments/ID`, `repos/.../pulls/PR`) is not a list and does not need `--paginate`.

The shipped gate scripts already bake this in --- `fetch_api_array` wraps `gh api --paginate` for the REST arrays, and the GraphQL reads use cursor loops --- so this rule is aimed at the ad-hoc queries those helpers do not cover. When in doubt, add `--paginate`: it is a no-op on a short list and the only safe default on a long one.

## 1Password CLI authentication failures

If any `op` command (`op read`, `op inject`, `op run`, `op document get`, or any script that wraps them) fails with a sign-in or authentication error — including but not limited to:

- `[ERROR] ... not currently signed in`
- `session expired`
- `biometric unlock ... timed out`
- `authorization prompt dismissed`
- `error initializing client: authorization`

Then follow this procedure:

1. **Stop immediately.** Do not retry the command, do not attempt workarounds (manual token entry, environment variable overrides, fallback credential paths, or skipping the credential step).
2. **Check if preflight was run.** If `OP_PREFLIGHT_DONE` is not set, suggest running the preflight script:
   > "1Password auth failed. Would you like to run credential preflight to cache all credentials at once? `eval \"$(scripts/op-preflight.sh --agent claude --mode review)\"`"
   >
   > (Use `--mode deploy` or `--mode all` instead if a deploy is in scope; the default is now `review` per #282.)
3. **If preflight was already run** but credentials expired (rare — only after 1Password locks or the 12-hour hard limit), prompt the human and suggest re-running preflight:
   > "Preflight credentials appear to have expired. Could you re-run preflight when you're back? I need to resume the review."
4. **Wait for the human to confirm** they are present and ready before re-running preflight (not individual `op read` commands).
5. After confirmation, re-run preflight. If it fails again, report the full error output and wait — do not loop.

This rule applies only to 1Password CLI sign-in and authentication errors. Other `op` failures (wrong item ID, missing field, network errors, vault permission errors) should be diagnosed and resolved normally.

## Bug fix escalation policy

These rules prevent agents from repeatedly patching symptoms of a structural defect. They are derived from a real failure where one agent made six unsuccessful fix attempts on the same issue because every attempt preserved the same broken architectural assumption.

### Two-strike audit rule

If an agent has made **two or more failed fix attempts** on the same issue (i.e., two merged PRs that were each intended to resolve the issue but did not), the next attempt **must** begin with a written audit of all prior attempts before any code changes. The audit must:

1. List every prior PR that targeted this issue.
2. For each, state what it changed and why it was insufficient.
3. Identify the **shared assumption** across all prior attempts.
4. Propose a fix that addresses that assumption directly, not another symptom within it.

The audit should appear in the PR description under a section titled "Audit Of Prior Failed Fixes."

If the agent cannot identify a shared assumption, it must flag the issue to the human rather than filing another incremental fix.

### Agent rotation for retries

When an agent's fixes are not resolving an issue after two attempts, **hand the problem to a different agent**. A fresh agent without the prior context is less likely to inherit implicit assumptions about the system's architecture. The new agent should be given:

- The issue description
- Links to all prior fix PRs
- No additional narrative framing (let it form its own model)

This is a recommendation, not a hard rule. The human decides when to rotate.

### Serialization layer review requirement

When reviewing a PR that introduces or modifies a **serialization or deserialization layer**—any code that converts structured data to a flat format (strings, JSON, markdown, plain text) and back—the reviewer must verify:

1. **Losslessness:** Does the round-trip preserve all semantically meaningful information? If not, what is discarded?
2. **Consumer parity:** Do all consumers of the serialized format produce identical output from identical input? If there are multiple parsers/renderers, are they tested for equivalence?
3. **Necessity:** Is the intermediate format required, or can consumers read the structured format directly?

If the round-trip is lossy, the reviewer must flag the information loss as a design risk and require either:
- An explicit justification for why the loss is acceptable, or
- A plan to eliminate the intermediate format

## Session finalization

Before an agent session goes idle, implementation-ready work must end in one of three durable states: a committed PR, an explicit issue/PR handoff, or an explicit discard. Start follow-up work after a PR merges on a fresh branch or worktree from current `origin/main`; do not continue shipping follow-ups from the just-merged branch's stale checkout. Open the tracking PR or issue early enough that in-flight work is visible. Run `scripts/session-finalization-check.sh` (or equivalent `git status` / stash / worktree checks) before closeout; the script is read-only and reports dirty files, stashes, stale branch state, and dirty auxiliary worktrees without deleting work. Verified-merged local branch classification is handled by `scripts/worktree-cleanup.sh`.

## Worktree lifecycle

Worktrees created for a task must be removed immediately after the corresponding branch is merged or deleted from the remote. Never leave a worktree checked out for a branch that is `[gone]` on the remote. Stale worktrees confuse branch/HEAD reasoning, leave dead generated artifacts around, and increase the chance an agent validates or runs commands from a dead branch.

**After a merge or branch delete**, run `scripts/worktree-cleanup.sh` (dry-run) to audit stale worktrees and `scripts/worktree-cleanup.sh --apply` to remove safe candidates. The helper identifies four classes of stale state:

- worktrees whose branch upstream is `[gone]` (the branch was deleted upstream);
- detached `mergepath-pr-*` worktrees whose corresponding PR is closed/merged (cross-checked via `gh pr view`);
- local branches whose upstream is `[gone]` and whose PR is verified merged (cross-checked via `gh pr list --head <branch> --state merged`);
- orphaned directories under `.claude/worktrees/` that have no matching entry in `git worktree list --porcelain`.

```bash
scripts/worktree-cleanup.sh                       # dry-run audit (default)
scripts/worktree-cleanup.sh --apply               # remove safe candidates
scripts/worktree-cleanup.sh --apply --force-locked
                                                  # also remove LOCKED entries
                                                  # (may belong to active sessions)
scripts/worktree-cleanup.sh --apply --orphan-clean
                                                  # also rm -rf orphan dirs
```

Locked worktrees and orphan dirs are listed in dry-run but require explicit `--force-locked` / `--orphan-clean` opt-in under `--apply`, because locked worktrees may correspond to in-progress agent sessions and orphan dirs may hold partial work the user wants to keep. Verified-merged local branches are deleted only after `gh pr list --head <branch> --state merged` confirms the PR merged; checked-out local branches are listed but skipped.

This helper is intentionally local-only — worktree state is machine-local and should not gate repository CI (see #288).

## Feedback-rollup cadence model

Two complementary automations catch unaddressed review feedback at different time horizons. Agents should know which one fires when, so triage work isn't duplicated and missed-signal classes are surfaced at the right cadence.

### Daily rollup — deferred-and-forgotten class

**`.github/workflows/daily-feedback-rollup.yml`** runs daily at `55 23 * * *` UTC. It scans yesterday's MERGED PRs and surfaces bot review threads that were RESOLVED **without** an associated fix commit or substantive reply. The output splits into two clearly-labeled tracks (substantive / polish) so the high-severity stream stays high-signal even on days with a lot of nit volume.

This catches the class that motivated #234 / #286 / #287: a CodeRabbit Major or Codex P2 the agent resolved as "non-blocking, will fix in a follow-up" — and then nobody wrote down. Captured while the resolving agent's context is still hot.

See `scripts/daily-feedback-rollup.sh` (workhorse) + `scripts/lib/daily-feedback-rollup-helpers.sh` (classifier helpers) + `scripts/resolve-pr-threads.sh --auto-resolve-bots` (the upstream emit-side that tags each resolve with `[mergepath-resolve:<class>]` so the classifier prefers agent-recorded rationale over heuristics).

### Weekly sweep — longer-tail residuals

**`.github/workflows/weekly-feedback-sweep.yml`** runs Mondays at `09:00` UTC. It enumerates UNRESOLVED review threads on closed PRs across the org (by default a 90-day lookback). Captures items that slipped past the merge gate AND remained unresolved through the daily rollup's 24h window — typically because the resolving agent's day rolled over before triage.

The sweep keys purely on GitHub review-thread state (`isResolved == false && isOutdated == false`), so a finding that was fixed during the PR but whose thread was left open re-surfaces here as if it were unactioned. Resolving actioned threads during the PR — `scripts/resolve-pr-threads.sh <PR#> --resolve-actioned`, which resolves only demonstrably-actioned threads and confirms each with an `isResolved: true` readback — keeps this backlog focused on feedback that still needs attention (#564).

See `scripts/sweep-unresolved-feedback/enumerate.sh` + `scripts/sweep-unresolved-feedback/render.sh`.

### Which one to act on

- Routine end-of-day triage → the substantive `deferred-feedback-rollup YYYY-MM-DD` issue from the daily cron. Items aged 0-7 days, context fresh.
- Polish/nit batch triage → the `polish-feedback-rollup YYYY-MM-DD` issue from the same daily cron. Lower urgency; can batch across multiple days.
- Quarterly backlog review → the weekly sweep's rollup issue. Items aged 7+ days, context decayed but pattern recognition still possible.

Both surfaces are per-repo (each consumer has its own daily + weekly rollup issues). Cross-repo aggregation is explicit non-goal for v1 of both workflows; the per-repo design preserves operator focus on the repo whose context they're currently in.

## PR and issue titles/descriptions: describe the work, not the session

Titles and descriptions — for both pull requests and issues — must describe the final state of the change (what it does and why) for a reader who arrives with no knowledge of the session that produced it.

- Do not narrate the session's path: no pivots, abandoned approaches, "originally did X, then switched to Y," or commentary on how the plan evolved.
- When a pivot changes what the work is, update the title/description to reflect the new end state — not the fact that a pivot happened.
- Once a title or description already describes the work accurately, treat it as read-only. Do not reword or "refresh" it to fold in later session context.
- This bans narrating the session, not documenting the work. Design rationale, an "Alternatives considered" section, or contrasting the change with the prior committed code (e.g. "replaces the hard-coded `null` with a threaded value") all describe the end state for a cold reader and are fine. The test: would the text help someone who never saw the session? Rationale and prior-code contrast pass; "I first tried X, then switched" does not.

This is advisory guidance for judgment, not a `repo_lint`/CI gate — the narration-vs-rationale distinction is not reliably lintable, and a reviewer (human or bot) should apply it as judgment rather than minting false-positive findings from words like "originally" or "instead." See #654.
