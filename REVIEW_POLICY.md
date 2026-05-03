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

### Reviewer PAT Quick Start

`gh` resolves auth differently for read paths vs write paths:

- **Read paths** (`gh api user`, `gh api ...` GETs, `gh pr view`,
  `gh pr checks`) honor `GH_TOKEN`. Pass it inline per command.
- **Write paths** (`gh pr review`, `gh pr create`, `gh pr merge`,
  `gh pr edit`, `gh api -X POST repos/.../pulls/.../reviews`) use the
  keyring's **active** account regardless of `GH_TOKEN`. The byline is
  whoever owns the active keyring entry — read it with `gh config get
  -h github.com user`, NOT `gh auth status` (the latter is
  GH_TOKEN-poisonable: with GH_TOKEN set it reports the GH_TOKEN entry
  as Active and the keyring entry as inactive, masking real
  mismatches).

Each agent's working machine has the agent identity as the **active**
gh account, set once: `gh auth switch -u nathanpayne-<agent>`.
Reviewer-identity writes then attribute correctly without an env var.
Author-identity writes (`gh pr create`, `gh pr merge`, `gh pr edit`)
need a temporary `gh auth switch -u nathanjohnpayne` around them,
paired with a switch-back. See nathanjohnpayne/mergepath#164 for the
empirical diagnosis (matchline PRs #181, #182).

PATs are still required for the helper scripts (`coderabbit-wait.sh`,
`codex-review-request.sh`, `codex-review-check.sh`) that drive the
review pipeline. Of these, `codex-review-check.sh` is purely
read-path; `coderabbit-wait.sh` and `codex-review-request.sh` BOTH
post comments on the PR (a retry trigger and an `@codex review`
trigger respectively, via `gh pr comment` or `gh api`). The PAT in
`GH_TOKEN` authenticates the API call, but the **byline of the
posted comment** is the keyring's active account — so the
active-account convention applies to these helpers too. Set the
active account once per machine (`gh auth switch -u nathanpayne-<agent>`)
and the comments attribute correctly. The trigger-comment bodies are
identity-agnostic, so a wrong byline isn't load-bearing — but
matters for audit-trail consistency.

#### PAT lookup table

| Agent | Reviewer Identity | 1Password Item ID | `op read` path |
|-------|-------------------|-------------------|----------------|
| Claude | `nathanpayne-claude` | `pvbq24vl2h6gl7yjclxy2hbote` | `op://Private/pvbq24vl2h6gl7yjclxy2hbote/token` |
| Cursor | `nathanpayne-cursor` | `bslrih4spwxgookzfy6zedz5g4` | `op://Private/bslrih4spwxgookzfy6zedz5g4/token` |
| Codex | `nathanpayne-codex` | `o6ekjxjjl5gq6rmcneomrjahpu` | `op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token` |
| Human | `nathanjohnpayne` | `sm5kopwk6t6p3xmu2igesndzhe` | `op://Private/sm5kopwk6t6p3xmu2igesndzhe/token` |

```bash
# Read-path identity check — GH_TOKEN works here.
GH_TOKEN="$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')" \
  gh api user --jq '.login'
# expected: nathanpayne-claude

# Write-path: with the agent identity active, GH_TOKEN is irrelevant
# for the byline. Just run the command.
gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

# Author-identity write: switch around the call so the byline is the
# author identity, then switch back so the active state is correct
# for subsequent reviewer-identity writes.
gh auth switch -u nathanjohnpayne && \
  gh pr create --title "..." --body "..." && \
  gh auth switch -u nathanpayne-claude
```

- Use the item ID from the lookup table above for your agent identity. Do not use the 1Password item title.
- Verify the keyring active account with `gh config get -h github.com user`
  (NOT `gh auth status` — that command honors GH_TOKEN and will
  mis-report when GH_TOKEN is set). The result should be your agent
  identity (`nathanpayne-<agent>`). If it shows `nathanjohnpayne`
  instead, reviewer-identity writes will attribute to nathanjohnpayne
  (not the reviewer). Fix once with `gh auth switch -u nathanpayne-<agent>`.
  The `op-preflight.sh` script warns when active ≠ expected.
- If `op whoami` says you are not signed in, still run the `op read ...`
  command in an interactive TTY. That is what triggers the 1Password biometric
  prompt on local machines.
- If GitHub returns `Review Can not approve your own pull request`, you are
  the active account on a PR you authored. Switch to a different agent's
  reviewer identity (or skip self-approve per the no-self-approve rule).

## Workflow

### Phase 0: Credential Preflight

> Run this once at the start of every PR review or deploy session. It front-loads all 1Password credential reads and SSH key authorization into a single burst of biometric prompts (~15 seconds), so the human can step away for the rest of the session.

```bash
eval "$(scripts/op-preflight.sh --agent claude --mode all)"
```

Replace `claude` with `cursor` or `codex` depending on which agent is running. The `--mode` flag controls what is loaded:

| Mode | What's loaded |
|------|--------------|
| `review` | Reviewer PAT + author PAT + SSH keys |
| `deploy` | GCP ADC credential |
| `all` | Everything (recommended) |

After preflight, these environment variables are set:
- `OP_PREFLIGHT_REVIEWER_PAT` — use with `GH_TOKEN=` for reviewer-identity **read-path** API calls and helper scripts (`coderabbit-wait.sh`, `codex-review-request.sh`, `codex-review-check.sh`). Write paths (`gh pr review` / `create` / `merge` / `edit`) use the active keyring account regardless of `GH_TOKEN` — see [Reviewer PAT Quick Start](#reviewer-pat-quick-start).
- `OP_PREFLIGHT_AUTHOR_PAT` — use with `GH_TOKEN=` for author-identity read-path API calls. For author-identity writes (PR create / merge / label edit), use the `gh auth switch -u nathanjohnpayne && ... && gh auth switch -u nathanpayne-<agent>` switch-around pattern.
- `GOOGLE_APPLICATION_CREDENTIALS` — used automatically by gcloud/Firebase scripts
- `OP_PREFLIGHT_DONE=1` — flag indicating preflight has been run

Resolved credentials are also persisted to a chmod-600 session file at `$XDG_CACHE_HOME/mergepath/op-preflight-<agent>.env` (default `$HOME/.cache/mergepath/`). Re-running the preflight command within the TTL window (4h default, override via `OP_PREFLIGHT_TTL_SECONDS`) short-circuits to the cached values — **no new biometric prompt**. This is what lets agent drivers (Claude Code, Cursor, Codex CLI) re-run preflight at the top of every tool call without repeatedly re-unlocking 1Password; each tool call spawns a fresh subshell that cannot see env vars exported by a prior call, so the session file is the only persistence layer that survives. See nathanjohnpayne/mergepath#139 for the failure mode that motivated this design.

Session-cache maintenance:
- `scripts/op-preflight.sh --agent <name> --refresh` — force a new biometric fetch, overwriting the session file.
- `scripts/op-preflight.sh --agent <name> --purge` — delete the session file + ADC tempfile for that agent.
- `scripts/op-preflight.sh --purge-all` — delete all session files + ADC tempfiles under the cache dir (end-of-session cleanup).

The session file contains plaintext PATs guarded only by filesystem permissions (0600) and is readable by any process running as your user — equivalent to the protection `op` itself provides for its unlocked session. Rotate the PATs in 1Password and purge the cache if you suspect the machine was compromised.

If any `op` command fails mid-session (rare — only if 1Password locks or the 12-hour hard limit is reached), re-run the preflight command with `--refresh` to force a fresh fetch.

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

### Phase 2.5: Automated External Review (CodeRabbit)

> **Applies only to repos with `coderabbit.enabled: true` in `.github/review-policy.yml`.** Skip this phase for repos where CodeRabbit is not enabled.

After internal review passes (Phase 2), CodeRabbit provides an independent automated review:

1. **Wait for CodeRabbit.** CodeRabbit automatically posts a review when the PR is opened or updated. Prefer `scripts/coderabbit-wait.sh <PR#>` over an ad-hoc poll loop — the script anchors its "cleared" signal on the current HEAD committer date, so it will not treat a stale review from a prior HEAD as current; it also handles CodeRabbit's rate-limit state, which the platform does NOT auto-retry (see nathanjohnpayne/mergepath#138). On exit code `0` CodeRabbit has cleared with no high-severity markers; on `2` it has findings to address; on `4` the `coderabbit.max_wait_seconds` grace window elapsed (the agent may log a warning and proceed since CodeRabbit is advisory); on `5` the rate-limit retry budget was exhausted (alert the human rather than proceed). If CodeRabbit has not posted after the grace window, ask the human whether to continue waiting or skip.
2. **Read both API endpoints.** CodeRabbit posts two types of comments that must both be checked:
   - **PR-level summary:** `gh api repos/{owner}/{repo}/issues/{pr_number}/comments` — contains the high-level walkthrough and summary.
   - **Inline review comments on the diff:** `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` — contains line-by-line findings anchored to specific code.
3. **Scan for potential issues.** Before proceeding, grep CodeRabbit's inline review comments for `Potential issue` or `⚠️`. These markers indicate findings CodeRabbit considers high-severity. Every such finding must be explicitly addressed (fixed or dismissed with reasoning).
4. The agent addresses substantive CodeRabbit findings — fixing issues or posting a reply explaining why a finding is not applicable.
5. The agent is not required to resolve every CodeRabbit comment. Use judgment: fix genuine issues, dismiss false positives with a brief explanation. However, all `Potential issue` / `⚠️` findings require an explicit response.
6. CodeRabbit review is advisory. It does not block merge via CI and does not submit a "Changes Requested" review state.

**CodeRabbit runs on ALL PRs** in enabled repos, regardless of size or whether the external review threshold is met. It provides a consistent automated second opinion on every change.

The agent proceeds to Phase 3 (Threshold Check) after addressing CodeRabbit comments, even if some remain open. CodeRabbit is an additional review layer, not a replacement for the existing threshold-based external agent handoff.

#### CodeRabbit Review Checklist

Before moving past Phase 2.5, confirm all of the following:

- [ ] CodeRabbit has posted its review on the current HEAD (use `scripts/coderabbit-wait.sh <PR#>` — exit `0` or `2`; `4` is a grace-window timeout that may be logged and skipped since CodeRabbit is advisory)
- [ ] If `scripts/coderabbit-wait.sh` exited `5` (rate-limit stalled), the human has been alerted rather than the agent proceeding
- [ ] Read PR-level comments via `issues/{pr}/comments` endpoint
- [ ] Read inline diff comments via `pulls/{pr}/comments` endpoint
- [ ] Grepped inline comments for `Potential issue` and `⚠️` — all flagged findings addressed
- [ ] Substantive findings fixed or dismissed with reasoning

### Phase 3: External Review Threshold Check

> **Note on automation timing:** CI workflows may apply the `needs-external-review` label automatically when a PR is opened or updated, as an early advisory based on line count and protected paths. The label blocks merge via the label-gate until external review clears. When the label is present, the agent's responsibility after internal review passes is to proceed to [Phase 4](#phase-4-external-review) — which routes the PR to Phase 4a (automated via the Codex GitHub App) or Phase 4b (manual handoff) depending on `codex.enabled` and on whether 4a converges. The label itself does NOT imply immediate human mediation; Phase 4b only posts the handoff message when the fallback path is actually taken.

8. After internal review passes, the agent evaluates whether the PR meets the external review threshold (see [Review Policy Configuration](#review-policy-configuration)).
9. If the threshold is **not** met, the agent merges the PR as `nathanjohnpayne`. Done.
10. If the threshold **is** met, the agent proceeds to [Phase 4: External Review](#phase-4-external-review). Phase 4 itself routes the PR to Phase 4a (automated, via the Codex GitHub App) or Phase 4b (manual handoff) based on `codex.enabled` in `.github/review-policy.yml` and on whether 4a's automated loop converges. The agent does NOT post a handoff message directly from this step — Phase 4b posts its own handoff message if and when the fallback path is taken.

### Phase 4: External Review

Phase 4 has two sub-phases that together cover the two ways external review can run:

- **Phase 4a — Automated external review** via the ChatGPT Codex Connector GitHub App. This is the default happy path. The authoring agent drives the review loop without human intervention until Codex signals clearance, then runs a merge-gate check and merges.
- **Phase 4b — Manual CLI fallback** via a different agent's CLI session (e.g., Codex CLI as `nathanpayne-codex`, or Cursor, or Claude Code). This is the escape hatch when 4a escalates (disagreement or runaway), times out, or is unavailable because `codex.enabled: false`. The human mediates the handoff.

An agent proceeds to 4a first. If 4a escalates, times out, or is disabled, the agent falls back to 4b and surfaces the handoff to the human per [Handoff Message Format](#handoff-message-format).

#### Phase 4a: Automated External Review (Codex GitHub App)

> **Applies only to repos with `codex.enabled: true` in `.github/review-policy.yml`.** The **ChatGPT Codex Connector GitHub App must also be review-ready on the repository**, meaning installed, with Code Review enabled at [chatgpt.com/codex/cloud/settings/code-review](https://chatgpt.com/codex/cloud/settings/code-review), AND with a Codex environment configured at [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments). "Installed" alone is not sufficient — a PR in a repo where the App is present but the environment is not configured will receive a "create an environment for this repo" comment from `chatgpt-codex-connector[bot]` instead of a review (observed on PR #62 on 2026-04-14). The only verification available from an agent reviewer PAT is observational: check whether a recent PR in this repo received an auto-review from `chatgpt-codex-connector[bot]`; `gh api repos/{owner}/{repo}/installation` requires a GitHub App JWT and is NOT usable from normal tokens. If any of these conditions is not met, skip directly to Phase 4b.

11a. The authoring agent runs `scripts/codex-review-request.sh <PR#>` to trigger or await a Codex review. If the Codex App's "Automatic reviews" setting has already caused Codex to review the PR on open (typical latency ~2 minutes for small PRs), the script skips posting `@codex review` and goes straight to polling.

12a. `codex-review-request.sh` polls the PR until one of the following:

     - **Codex posts a review.** Always in `COMMENTED` state — the Codex GitHub App never uses `APPROVED` or `CHANGES_REQUESTED`. Findings appear as **inline comments on the diff** (`/pulls/{pr}/comments` endpoint), not in the top-level review body. Inline findings carry priority markers: `![P0 Badge]`, `![P1 Badge]`, `![P2 Badge]`, or `![P3 Badge]`.
     - **Codex reacts 👍 / `+1`** on the PR issue with no review body. This is Codex's no-findings clearance signal per the ChatGPT Codex Connector documentation.
     - **Timeout.** No review and no reaction within `codex.review_timeout_seconds` (default: 600s / 10 min). The script exits with code `4` (`FALLBACK_REQUIRED`).

13a. If Codex posted inline findings, the agent addresses each P0/P1 by either:

     - **Fixing the code** and pushing a new commit to the same branch, or
     - **Replying on the finding thread** with a clear rebuttal explaining why the finding does not apply (for false positives or scope disagreements).

     P2 and P3 findings are addressed at the agent's judgment — not every cosmetic or nit-level finding needs a fix or a rebuttal.

14a. The agent increments its round counter and re-runs `scripts/codex-review-request.sh` to request a re-review of the new HEAD.

15a. The loop continues until one of the following terminates it:

     - **Clearance (happy path).** Codex posts a review with no unaddressed P0/P1 inline findings on the current HEAD, OR reacts 👍 on or after the current HEAD commit. Proceed to step 16a.
     - **Disagreement (escalate).** Codex re-flags the same finding after the agent posted a rebuttal. This is "repeat-after-rebuttal." See [Disagreements and Tiebreaking](#disagreements-and-tiebreaking).
     - **Runaway (escalate).** The round counter exceeds `codex.max_review_rounds` (default: 2). The 3rd round trips this guard. See [Disagreements and Tiebreaking](#disagreements-and-tiebreaking).
     - **Timeout (fall back).** `codex-review-request.sh` exits with code `4` (`FALLBACK_REQUIRED`) for the current round. The agent falls back to Phase 4b. There is no "second timeout" escalation — a single timeout already routes to human mediation via the 4b handoff.

16a. Before merging, the agent runs `scripts/codex-review-check.sh <PR#>` to verify the merge gate. All of the following must be true:

     - `gh pr checks` reports all required CI checks green
     - **Gate (b)** — one of:
       - **Branch 1 (cross-agent):** a reviewer identity from `available_reviewers` has posted an `APPROVED` review (Phase 2 internal self-peer review by a DIFFERENT agent than the author)
       - **Branch 2 (same-agent fallback, #170):** the PR's `Authoring-Agent:` matches an entry in `available_reviewers` AND `chatgpt-codex-connector[bot]` has a fresh 👍 reaction on the PR issue (timestamped at-or-after the same `REACTION_THRESHOLD` gate (c) uses). This is the normal path for single-agent sessions where the no-self-approve rule prohibits the author's reviewer identity from approving — Codex's external review is the cross-agent signal that substitutes for an APPROVED state.
     - **Gate (c)** — Codex has signaled clearance on the current HEAD via one of the two forms in step 12a

     **The merge gate must never require an `APPROVED` review state from `chatgpt-codex-connector[bot]` — the app does not emit that state.** This point is load-bearing; a merge gate that looks for Codex APPROVED will never be satisfied and the Phase 4a happy path will be unreachable.

     **No-self-approve rule + branch 2 interaction:** the rule "agents do not `--approve` a PR they authored under their own reviewer identity" remains in effect. Branch 2 is what makes the rule operational — without it, same-agent PRs would deadlock on gate (b) with no escape short of human override. With branch 2, the agent posts a `--comment` review under its reviewer identity (per the rule), and the Codex 👍 carries the cross-check weight.

17a. On a passing merge gate, `nathanjohnpayne` merges the PR with `gh pr merge <n> --squash --delete-branch`. Never `--admin` unless the human explicitly authorizes a break-glass override in chat.

#### Phase 4b: Manual CLI Fallback (Human Handoff)

Phase 4b is invoked when Phase 4a escalates to disagreement or runaway, times out (single timeout, exit code `4` from `codex-review-request.sh`), or when `codex.enabled: false` in the repo. It preserves the cross-agent review flow that existed before the Codex GitHub App integration and provides a human-mediated escape hatch.

11b. The authoring agent posts the handoff message (see [Handoff Message Format](#handoff-message-format)) as a PR comment and alerts the human.

12b. The human takes the handoff message to a different agent session (e.g., from Claude to Cursor, or to a Codex CLI session authenticated as `nathanpayne-codex`).

13b. The external agent's reviewer identity reviews the PR and posts review comments. Unlike the Codex GitHub App, CLI-driven reviews use the standard GitHub review states (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`) as expected.

14b. The human relays the external reviewer's feedback back to the originating agent.

15b. The originating agent, as `nathanjohnpayne`, addresses the feedback and pushes fix commits to the same branch.

16b. The human shuttles updated code back to the external reviewer.

17b. Steps 13b–16b repeat until the external reviewer submits an `APPROVED` review.

18b. If the external reviewer flags **observations** or **risks** while approving, those are converted to GitHub Issues on the repo, assigned to `nathanjohnpayne` (see [Post-Merge Issue Creation](#post-merge-issue-creation)).

19b. `nathanjohnpayne` merges the PR. Done.

### Phase 4b Triggers

Phase 4b is documented above as a fallback (4a unavailable / escalates / times out). Per empirical evidence from matchline (#158: 9 PRs of the same author through both 4a and 4b — 4b caught 6+ real bugs on state-machine + concurrency + transactional changes that 4a cleared past), Phase 4b ALSO has high catch-rate value as a **first-class proactive gate** on a specific class of PR — not just as a fallback.

The `phase_4b_default` field in `.github/review-policy.yml` controls when 4b fires proactively:

| Value | Behavior (intended; full wiring lands in #186 + #187) |
|-------|---------|
| `fallback-only` | Current behavior. 4b only on 4a unavailability/escalation/timeout. |
| `complex-changes` | Run `scripts/phase-4b-classifier.sh` AFTER 4a clears; if any trigger matches, post the 4b handoff before merging. |
| `always` | Skip the classifier; post the 4b handoff for every external-review-threshold PR. |

**Operating instructions:** the runtime branching that consumes `phase_4b_default` is documented in [CLAUDE.md step 8.5](CLAUDE.md) (and summarized in AGENTS.md § Workflow Summary step 7). Agents read the field via `scripts/codex-review-check.sh` (which parses and exports `PHASE_4B_DEFAULT`), then on `complex-changes` run `scripts/phase-4b-classifier.sh <PR#>` between Phase 4a clearance and merge. The classifier's exit code is load-bearing: 0 (no 4b → merge), 1 (invoke 4b → post handoff per § Handoff Message Format), 2 (config/API error → stop), 3 (bad args → fix invocation).

**Default for new repos:** `complex-changes` (the empirically validated middle ground). **Default for existing repos** that haven't added the field: `fallback-only` (no behavior change without explicit opt-in — see [Migration for existing consumers](#migration-for-existing-consumers) below).

The five trigger classes the `complex-changes` mode keys on:

1. **State-machine changes.** PRs introducing or modifying discriminated-union or finite-state-machine types driving UI or service behavior.
   - **Detection:** diff includes new/modified types matching `type \w+ = \| \{ kind: "..."` or similar tagged-union patterns; OR PR body explicitly says "state machine."
   - **Why it matters:** the bug is rarely in any single hunk — it's in the state-transition composition. Local-context LLM reviewers (4a) consistently miss this; cross-context CLI review (4b) consistently catches it.

2. **Concurrency / transactional code.** PRs touching `runTransaction`, `Promise.all`, optimistic updates, subscription handling, or compare-and-set patterns.
   - **Detection:** diff includes `runTransaction` / `setSnapshot` / `applyOptimistic` / `CAS` / `compare-and-set` keywords; OR modifies `**/transactions/`, `**/concurrency/` paths.
   - **Why it matters:** invariant violations across concurrent operations (e.g., owner-uid re-check inside a tx after a tombstone-then-recreate race) require reasoning across pieces that look fine individually.

3. **Prompt design or LLM contract changes.** PRs adding/modifying few-shot examples, system prompts, structured-output schemas, or grounding rules.
   - **Detection:** paths matching `**/prompts/**`, `**/.v[0-9]+.md`, or LLM-tool-call schema files.
   - **Why it matters:** few-shot drift (e.g., disjunctive→conjunctive operator changes in an example) is invisible to a diff reviewer that doesn't understand the prompt as a system.

4. **Cross-cutting refactors.** PRs that change a contract used by ≥3 callers OR touch both the type layer and the service layer in the same diff.
   - **Detection:** changed-files spread across ≥3 distinct top-level dirs OR include both `src/types/` AND `src/services/` (or the consumer repo's analogous layer pair).
   - **Why it matters:** type/runtime split bugs surface when the type updates and runtime updates aren't in sync — same diff doesn't guarantee same semantics.

5. **Validation / invariant-enforcement code.** PRs changing anything pinning a product invariant (e.g., zero-fabrication checks, owner-uid validation, approval-state derivation).
   - **Detection:** paths matching `**/validation/**`, `**/security/**`, or `**/policies/**`; OR PR body explicit "invariant" mention.
   - **Why it matters:** weakening an invariant doesn't trigger any obvious red flag in a per-hunk review — the test of correctness is whether the invariant still holds across the full system, which a cross-context reviewer is better positioned to evaluate.

For PRs that match NONE of these classes, the classifier exits with `recommendation: fallback-only` and the standard 4a path is sufficient. The taxonomy is meant as a checklist, not a perfect predictor — agents should err on the side of invoking 4b when the heuristics are ambiguous.

### Cycle-time budget

Phase 4b adds latency. The human-mediated handoff typically adds 30 minutes to a few hours per PR — acceptable for high-risk changes (where a missed bug costs more than the latency) and corrosive for trivial ones (where the latency dwarfs the change). The taxonomy keeps that latency targeted at the changes that actually benefit. Repos with a high rate of state-machine or concurrency changes get more value from `complex-changes`; repos that mostly do data plumbing and pure-helper PRs get less and can stay on `fallback-only`.

The classifier (`scripts/phase-4b-classifier.sh`) is the implementation; CLAUDE.md step 8.5 (or equivalent) is the operating instruction that consults the classifier; this section is the doctrinal taxonomy that drives both.

### Migration for existing consumers

When you pull this template change into an existing repo, the new `phase_4b_default` field is **optional**. Repos that do not add the field default to `fallback-only` — current behavior, no change. Opt in to the new proactive-trigger flow by adding `phase_4b_default: complex-changes` to your repo's `.github/review-policy.yml`. New repos created from the template inherit `complex-changes` as the default per the template's own `.github/review-policy.yml`.

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
  │  PHASE 2.5: CODERABBIT REVIEW (if enabled)               │
  │  CodeRabbit auto-posts review on PR                      │
  │  Agent reads findings, addresses substantive issues      │
  │  Advisory only — does not block merge                    │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 3: THRESHOLD CHECK                                │
  │  Lines changed ≥ threshold OR protected paths touched?   │
  │                                                          │
  │  NO ──→ nathanjohnpayne merges. Done.                    │
  │  YES ──→ Proceed to Phase 4                              │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 4a: AUTOMATED EXTERNAL REVIEW                    │
  │  (Codex GitHub App, default when codex.enabled: true)   │
  │                                                         │
  │  round ← 1                                              │
  │  Agent runs codex-review-request.sh                     │
  │    → Codex posts COMMENTED review OR 👍 reaction        │
  │                                                         │
  │  ┌─ no unaddressed P0/P1 findings → clearance           │
  │  ├─ P0/P1 findings → fix or reply; round += 1; repeat   │
  │  ├─ repeat-after-rebuttal → ESCALATE (Disagreements)    │
  │  ├─ round > max_review_rounds → ESCALATE (Disagreements)│
  │  └─ timeout (exit code 4) → FALL BACK to Phase 4b       │
  └──────────────┬───────────────────────┬──────────────────┘
                 │ clearance              │ escalate / fallback
                 ▼                        ▼
  ┌──────────────────────────┐  ┌────────────────────────────┐
  │  MERGE GATE:             │  │  PHASE 4b: MANUAL CLI      │
  │  codex-review-check.sh   │  │  FALLBACK                  │
  │                          │  │                            │
  │  • gh pr checks = green  │  │  Post handoff message;     │
  │  • internal reviewer     │  │  alert human.              │
  │    identity APPROVED     │  │                            │
  │  • Codex cleared on HEAD │  │  Human takes handoff to    │
  │    via COMMENTED-no-P0/1 │  │  different agent CLI       │
  │    OR 👍 reaction        │  │  (e.g. nathanpayne-codex). │
  │                          │  │                            │
  │  (NEVER expects APPROVED │  │  External reviewer posts   │
  │   state from Codex bot —  │  │  comments / APPROVED /     │
  │   the app does not emit  │  │  CHANGES_REQUESTED.         │
  │   that state.)           │  │                            │
  └──────────┬───────────────┘  │  Human relays feedback.    │
             │                  │  Agent fixes. Repeat.       │
             ▼                  │                            │
  ┌──────────────────────────┐  │  Observations/risks →      │
  │  nathanjohnpayne merges  │  │  GitHub Issues             │
  │  (--squash). Done.       │  │                            │
  └──────────────────────────┘  │  nathanjohnpayne merges.   │
                                │  Done.                     │
                                └────────────────────────────┘
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

When the internal reviewer and external reviewer disagree on whether code is ready to merge, the human is the tiebreaker. The agent surfaces the disagreement clearly, summarizing both positions, and waits for the human's explicit decision before taking further action.

### Concrete detection signals (Phase 4a)

In Phase 4a, the agent escalates to the human when either of the following fires:

1. **Repeat-after-rebuttal.** The agent posted a reply to a Codex inline finding explaining why the finding does not apply. Codex's next review re-flags the same or substantively-equivalent finding. The agent treats this as a disagreement: Codex is not convinced by the rebuttal, and the agent stops trying to change Codex's mind autonomously. Continuing the loop past this point is rude to the reviewer and wastes API calls.

2. **Runaway rounds.** The round counter exceeds `codex.max_review_rounds` (default: 2). The 3rd `@codex review` request trips this guard. This catches cases where Codex keeps finding new, distinct issues on each pass without the review converging. Even if each individual finding is valid, three rounds of novel issues is a signal that the PR scope is too broad and a human should weigh in.

**Timeout is NOT a disagreement signal.** A Codex response timeout (`codex-review-request.sh` exit code `4` = `FALLBACK_REQUIRED`) routes the PR directly to Phase 4b per step 15a above. It is a fallback trigger, not a tiebreaker trigger. Phase 4b itself mediates via the human through the manual handoff, so there is nothing for the disagreement detector to add on top.

Phase 4b escalation (the traditional cross-agent CLI flow) uses the human's judgment directly — there is no automated detection loop to fire, so this subsection does not apply there.

### Escalation procedure

When either of the two signals above fires, the agent:

1. **Stops the automated loop immediately.** Does NOT push more commits, does NOT re-run `@codex review`, does NOT run the merge gate, does NOT merge.
2. **Posts a comment on the PR** summarizing:
   - Which signal fired and what triggered it
   - Both positions (the agent's and Codex's) in plain language, with links to the specific review rounds and the rebuttal replies
   - The current round counter and a link to the `scripts/codex-review-request.sh` output from the terminating round
3. **Alerts the human via chat** and waits for an explicit decision before taking any further action on the PR.

Note that timeout does NOT go through this escalation procedure. On a timeout (exit code `4` from `codex-review-request.sh`), the agent posts the handoff message per [Handoff Message Format](#handoff-message-format) and routes to Phase 4b directly from step 15a — no in-place tiebreaker.

The human resolves by one of:

- **Approving the existing state** — posting an `APPROVED` review as `nathanjohnpayne` or removing the `needs-external-review` label manually. This unblocks merge under the label-gate rules in [Review Policy Configuration](#review-policy-configuration).
- **Requesting additional changes** — typing the feedback directly in chat. The agent addresses it as normal edits. No `@codex review` loop, no round counter.
- **Taking the PR over manually** — the human merges on behalf of the agent, or closes and reopens with a different approach, or promotes the escalation to Phase 4b manually.

The agent never resolves a fired escalation signal on its own.

## Agent prohibitions

Agents must never modify the `needs-external-review`, `needs-human-review`, or `policy-violation` labels on any PR — these are human-action labels. The `scripts/hooks/label-removal-guard.sh` PreToolUse hook enforces this at the mechanism layer; chat authorization does not bypass it. To request a label removal, run `scripts/request-label-removal.sh <PR#> <label>` — this posts a structured ask on the PR and (if `MERGEPATH_NOTIFY_IMESSAGE_TO` is set) pings the human via iMessage. The human clears the label from any device; auto-merge fires immediately.

## Implementation notes for branch protection gates

### Required status checks (per-repo setup)

The workflows shipped under `.github/workflows/` ENFORCE merge gating only when configured as **required status checks** in branch protection. Without that bit, a failed check is advisory and the PR merges anyway. The 2026-04-27 weekly audit caught `matchline#76` and `matchline#93` merging past `needs-human-review` for exactly this reason — `Label Gate` was running and failing, but wasn't in the required-checks list.

Each repo using this template must mark these as required on `main` (Settings → Branches → Branch protection rule):

- **`Label Gate`** — fails when any of `needs-external-review`, `needs-human-review`, or `policy-violation` is on the PR. The hard gate behind the doctrine in [Agent prohibitions](#agent-prohibitions).
- **`Self-Review Required`** — fails when the PR body lacks a `## Self-Review` section (Dependabot-exempt).

Audit a repo's branch protection with `scripts/audit-branch-protection.sh` (read-only; exits 3 if any canonical check is not required, with a fix recipe). Re-run after every protection change.

### `resolveReviewThread`

The GitHub GraphQL `resolveReviewThread` mutation may be used by agents **only** when both:

- The agent has demonstrably addressed the inline finding (a fix is on the current HEAD, or a rebuttal is posted on the thread), AND
- The bot author of the thread has not auto-resolved within a reasonable window.

It is a clean-up mechanism for the `required_conversation_resolution: true` branch-protection gate, NOT a policy override. It does not authorize removing blocking labels, bypassing required reviews, or merging past unaddressed findings. **If the thread author is a human (not a bot), agents must not call this mutation regardless of state.**

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

# Author identity under which all agents commit and merge.
author_identity: nathanjohnpayne

# CodeRabbit (Phase 2.5 advisory automated review).
# Enabled on public repos only; advisory, does not block merge.
# NOTE: This flag governs AGENT behavior only (whether agents wait for
# CodeRabbit in Phase 2.5). It does NOT control whether the CodeRabbit
# GitHub App itself runs — the App runs based on its own install state.
# To fully disable CodeRabbit, uninstall the GitHub App AND set this flag.
coderabbit:
  enabled: false
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: 300                    # grace window for scripts/coderabbit-wait.sh
  max_rate_limit_retries: 2                # retries after CodeRabbit posts "Rate limit exceeded"
  wallclock_freshness_window_seconds: 1800 # HEAD_ANCHOR floor; closes cherry-pick false-clear

# Codex (Phase 4a automated external review) — see Phase 4a above.
# Same semantics note as coderabbit: this flag governs agent behavior,
# not app runtime. The ChatGPT Codex Connector App runs based on its
# per-repo install state and its "Automatic reviews" setting.
codex:
  enabled: true
  bot_login: "chatgpt-codex-connector[bot]"   # REST API form, with [bot] suffix
  cli_login: nathanpayne-codex                # manual CLI fallback (Phase 4b)
  max_review_rounds: 2                        # runaway guard; 3rd round escalates
  review_timeout_seconds: 600                 # per-round poll timeout
  require_ci_green: true                      # merge gate
```

> **Note on `enabled` flags (both `coderabbit` and `codex`).** These flags govern **agent behavior only** — whether the authoring agent waits for the corresponding review in its phase. They do NOT control whether the underlying GitHub App runs. Both apps run based on their own install state on GitHub, independent of what this YAML says. Setting `enabled: false` alone will cause the agent to skip the corresponding phase while the app continues to post reviews silently in the background. This may be desired as a "dark launch," but can confuse readers who expect the flag to mean "off." To fully disable an integration, uninstall the GitHub App AND set the flag to false.

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

### Git commit identity (user.name / user.email)

```bash
# Switch to author identity
git config user.name "nathanjohnpayne"
git config user.email "nathan@nathanjohnpayne.example"

# Switch to reviewer identity
git config user.name "nathanpayne-claude"
git config user.email "claude@nathanpayne-claude.example"
```

### SSH identity switching (push / pull)

All repos use SSH remotes (`git@github.com:nathanjohnpayne/...`). SSH keys are managed by 1Password and served through its SSH agent. `~/.ssh/config` maps host aliases to specific keys:

| SSH Host | GitHub Account | Key (1Password) |
|----------|----------------|-----------------|
| `github.com` | nathanjohnpayne | GitHub (nathanjohnpayne) |
| `github-claude` | nathanpayne-claude | GitHub Claude |
| `github-cursor` | nathanpayne-cursor | GitHub Cursor |
| `github-codex` | nathanpayne-codex | GitHub Codex |

The public key files (`~/.ssh/id_nathanjohnpayne.pub`, etc.) tell the 1Password agent which private key to sign with. `IdentitiesOnly yes` prevents SSH from trying all keys.

To push/pull as the default author identity (`nathanjohnpayne`), no change is needed — the `github.com` host is the default.

> **If preflight was run:** SSH keys for both the author and reviewer identities were pre-warmed during Phase 0. The `git push` / `git pull` commands below will not trigger additional biometric prompts.

To push/pull as a reviewer identity, temporarily switch the remote:

```bash
# Switch remote to reviewer identity
git remote set-url origin git@github-claude:nathanjohnpayne/repo-name.git

# ... do review work, push review branch ...

# Switch back to author identity
git remote set-url origin git@github.com:nathanjohnpayne/repo-name.git
```

### GitHub API authentication (gh CLI)

`gh` resolves auth differently for read paths vs write paths — the
canonical convention is documented in [Reviewer PAT Quick Start](#reviewer-pat-quick-start).
Short form:

- **Read paths** (`gh api user`, GETs, `gh pr view`, `gh pr checks`)
  honor `GH_TOKEN`. Pass it inline per command.
- **Write paths** (`gh pr review`, `gh pr create`, `gh pr merge`,
  `gh pr edit`, `gh api -X POST`) use the keyring's **active** account
  regardless of `GH_TOKEN`. The active account is set once per machine
  via `gh auth switch -u nathanpayne-<agent>`; `op-preflight.sh` warns
  if active ≠ expected.

```bash
# ── Read-path: GH_TOKEN works ──

# Verify which identity a PAT resolves to (read path):
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq '.login'
# expected: nathanpayne-claude

# Read-only helper:
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-check.sh <PR#>

# Helpers that may also POST a trigger comment — GH_TOKEN authenticates
# the API call, but the comment byline is the active keyring account.
# Set active = nathanpayne-<agent> once per machine; then byline is correct.
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/coderabbit-wait.sh <PR#>
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-request.sh <PR#>

# ── Write-path: active keyring is the byline; GH_TOKEN is ignored ──

# Reviewer-identity write (your agent identity is active by default):
gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

# Author-identity write: temporary switch-around so the byline is
# nathanjohnpayne, paired with switch-back so active state never lingers
# wrong for subsequent reviewer-identity writes:
gh auth switch -u nathanjohnpayne && \
  gh pr merge <PR#> --squash --delete-branch && \
  gh auth switch -u nathanpayne-<agent>
```

- Use the item ID from the [PAT lookup table](#pat-lookup-table) for your agent identity. Do not use the 1Password item title.
- Verify the keyring active account with `gh config get -h github.com user`
  (NOT `gh auth status` — that command honors GH_TOKEN and
  mis-reports when GH_TOKEN is set). Fix once with
  `gh auth switch -u nathanpayne-<agent>`. The `op-preflight.sh`
  script warns when active ≠ expected.
- If `op whoami` says you are not signed in, still run the `op read ...`
  command in an interactive TTY. That is what triggers the 1Password biometric
  prompt on local machines.
- If GitHub returns `Review Can not approve your own pull request`, you
  are the active account on a PR you authored. Switch to a different
  agent's reviewer identity (or skip self-approve per the no-self-approve
  rule).

> **If `op read` fails with a sign-in or biometric error here**, follow the pause-and-prompt procedure in `docs/agents/operating-rules.md` under "1Password CLI authentication failures." Do not hardcode tokens, skip review, or retry in a loop.

### PAT requirements for reviewer identities

Reviewer accounts are **collaborators** on repos owned by `nathanjohnpayne`. This constrains the PAT type:

- **Classic PATs with `repo` scope** — required for collaborator accounts. Fine-grained PATs on personal (non-org) GitHub accounts only cover repos the account *owns*. The "All repositories" scope means all owned repos (zero for collaborators), and "Only select repositories" does not list collaborator repos.
- Store each PAT in 1Password as `GitHub PAT (pr-review-{agent})` with a concealed field named `token`.
- Access via item ID to avoid shell escaping issues with parentheses in the title. See the [PAT lookup table](#pat-lookup-table) for all current item IDs.

### 1Password SSH agent setup (one-time)

If `~/.ssh/config` does not exist or is missing the host aliases above:

```bash
# 1. Export public keys from the 1Password SSH agent
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
ssh-add -L | grep "nathanjohnpayne" > ~/.ssh/id_nathanjohnpayne.pub
ssh-add -L | grep "Claude"          > ~/.ssh/id_nathanpayne_claude.pub
ssh-add -L | grep "Cursor"          > ~/.ssh/id_nathanpayne_cursor.pub
ssh-add -L | grep "Codex"           > ~/.ssh/id_nathanpayne_codex.pub

# 2. Create ~/.ssh/config (see the host alias table above for the full file)
# 3. chmod 600 ~/.ssh/config

# 4. Verify
ssh -T git@github.com          # → Hi nathanjohnpayne!
ssh -T git@github-claude        # → Hi nathanpayne-claude!
```

### Switching all repos to SSH remotes

```bash
for repo in mergepath swipewatch nathanpaynedotcom \
            device-platform-reporting device-source-of-truth \
            overridebroadway friends-and-family-billing docs; do
  cd ~/Documents/GitHub/$repo
  CURRENT=$(git remote get-url origin)
  if [[ "$CURRENT" == https* ]]; then
    SLUG=$(echo "$CURRENT" | sed 's|https://github.com/||;s|\.git$||')
    git remote set-url origin "git@github.com:${SLUG}.git"
    echo "$repo: https → ssh"
  else
    echo "$repo: already ssh"
  fi
done
```

## Adding a New Agent

1. Create a GitHub account: `nathanpayne-{agent}`
2. Add it as a collaborator with Write access on each relevant repo.
3. Accept the invitation (browser or classic PAT — fine-grained PATs cannot accept invites).
4. Generate a **classic** PAT with `repo` scope for the new account.
5. Store the PAT in 1Password as `GitHub PAT (pr-review-{agent})`, field name `token`.
6. Create an SSH key in 1Password named `GitHub {Agent}`. Add the public key to the new GitHub account under Settings → SSH and GPG keys.
7. Export the public key: `ssh-add -L | grep "{Agent}" > ~/.ssh/id_nathanpayne_{agent}.pub`
8. Add a `Host github-{agent}` block to `~/.ssh/config` pointing at the new public key file.
9. Add the identity to `available_reviewers` in each relevant repo's `.github/review-policy.yml`.
10. Add the PAT as a repository secret (e.g., `{AGENT}_PAT`) for CI workflows.
11. Configure the new agent's environment with both the `nathanjohnpayne` author credentials and the `nathanpayne-{agent}` reviewer credentials.
12. The new agent follows the same workflow described above.

## Template Usage

This policy and the accompanying `review-policy.yml` should be included in every new repository created under `nathanjohnpayne`. To bootstrap a new repo:

1. Copy `.github/review-policy.yml` into the new repo's `.github/` directory.
2. Copy this document into the repo as `REVIEW_POLICY.md` (or the location specified by your project template).
3. Copy the governance files from the template:
   - `.github/dependabot.yml` — Dependabot version update schedule
   - `.github/CODEOWNERS` — code ownership routing
   - `SECURITY.md` — vulnerability reporting policy (update the repo name in the advisory URL)
4. Adjust `external_review_threshold`, `external_review_paths`, and `default_external_reviewer` to fit the project.
5. Ensure all agent environments have credentials configured for the repo.
6. If the repo is public, enable secret scanning and push protection via GitHub settings (or API).
7. If the repo is public and using CodeRabbit, set `coderabbit.enabled: true` in `.github/review-policy.yml` and install the CodeRabbit GitHub App on the repo.
8. The `.coderabbit.yml` file at the repo root ships with the template and works out of the box. Customize `reviews.path_instructions` to add repo-specific review guidance (e.g., flag currency rounding in billing code, verify type compatibility in shared packages).

### CodeRabbit Removal

To reverse the CodeRabbit integration (e.g., if the trial ends):

1. Uninstall the CodeRabbit GitHub App from the `nathanjohnpayne` GitHub account.
2. In each repo where CodeRabbit was enabled: set `coderabbit.enabled: false` in `.github/review-policy.yml` and delete `.coderabbit.yml`.
3. No documentation changes are needed — all agent instructions use conditional language (`"if coderabbit.enabled: true"`) and will skip Phase 2.5 automatically.
4. Optionally remove `.coderabbit.yml` from the template if CodeRabbit will not be used for future repos.
