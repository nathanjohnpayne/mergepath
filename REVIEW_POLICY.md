# AI Agent Code Review Policy

## Overview

This policy governs how AI coding agents author, review, and merge code across repositories owned by the `nathanjohnpayne` GitHub account. It enforces a structured peer review process where a single agent performs both authoring and self-review under separate GitHub identities, with mandatory external review by a different agent when complexity thresholds are met. All review activity occurs through GitHub PRs, producing a complete audit trail indistinguishable from multi-developer collaboration.

## Default disposition

**Favoring automation is the default, not an option to be confirmed.** Mergepath exists so an agent can carry a change from author → review → merge without human babysitting. On any PR the agent proceeds through the full path autonomously and **does not pause to ask the human for merge permission** ("should I merge?", "how far should I take this?"). For under-threshold PRs that means reviewer-identity `--approve` → merge (see [No-self-approve scoping](#no-self-approve-scoping) and the [Workflow](#workflow)); for above-threshold or protected-path PRs it means driving [Phase 4](#phase-4-external-review) to clearance and then merging.

The automated path never pauses to ask for merge permission. It defers to a human for only two reasons:

1. **The human says otherwise.** An explicit instruction in chat, or a human-action label that the gates enforce — `human-hold` (a human-remove-only hard freeze that supersedes every gate), `needs-human-review`, or `policy-violation`. Agents may add `human-hold` but must never remove it, and must never modify the others (see [Agent prohibitions](#agent-prohibitions)).
2. **A human handoff or escalation is required.** Either (a) a **Phase 4b handoff** — an above-threshold or protected-path PR where Phase 4a is unavailable or times out, or where `phase_4b_default` routes it to Phase 4b proactively after 4a clearance (`always` for every threshold PR, `complex-changes` only when `scripts/phase-4b-classifier.sh` flags it; see [Phase 4b Triggers](#phase-4b-triggers)); or (b) a **Phase 4a disagreement escalation** — when Codex repeats a finding after a rebuttal, or the round counter exceeds `max_review_rounds`, the agent stops, posts both positions, alerts the human for the tiebreaker, and waits for an explicit decision (see [Disagreements and Tiebreaking](#disagreements-and-tiebreaking)). Phase 4b is the only sanctioned place to post a [handoff message](#handoff-message-format) and wait for a human-mediated external review.

A stuck required gate is separate and non-discretionary, not a disposition choice: a red required check must go green, unresolved GitHub review conversations must be addressed or resolved per the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate), and a CodeRabbit rate-limit stall (`scripts/coderabbit-wait.sh` exit `5`) must be escalated to the human — alerting does not unblock it; the PR waits for human direction — *unless* the Codex failover engaged (`codex_failover_requested: true`, #489), in which case Codex (the real gate) was requested and the PR is not blocked (see [Phase 2.5](#phase-25-automated-external-review-coderabbit)). The agent never works around a stuck gate to merge, but it also never asks permission to merge a green one.

Anything else — a green under-threshold PR, or a Phase 4a clearance where `phase_4b_default` is `fallback-only` or the `complex-changes` classifier exits `0` — merges without a human checkpoint. Presenting a "how far should I take this PR?" disposition prompt on the happy path is a deviation from this policy, not a courtesy.

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

For repo work, `GH_TOKEN` is now the per-command attribution source for the guarded `gh` writes. Do not rely on the machine-global gh keyring selected account for author/reviewer bylines.

- **Read paths** (`gh api user`, `gh api ...` GETs, `gh pr view`, `gh pr checks`) honor `GH_TOKEN`. Pass it inline per command.
- **Guarded write paths** (`gh pr create`, `gh pr merge`, `gh pr edit`, `gh pr comment`, `gh pr review`, `gh issue comment`) MUST go through `scripts/gh-as-author.sh` or `scripts/gh-as-reviewer.sh`. The wrapper resolves the expected token, verifies its effective login with `scripts/identity-check.sh --expect-token-identity`, and runs exactly the wrapped command with `GH_TOKEN` set and `GITHUB_TOKEN` cleared. The wrappers never change stored gh account selection.
- **Bare and inline-token guarded writes** fail closed in `scripts/hooks/gh-pr-guard.sh`. `GH_TOKEN=... gh pr review ...` is not an approved substitute for the wrapper because it does not prove the token belongs to the expected identity.

`codex-review-request.sh` posts the load-bearing `@codex review` trigger through `scripts/gh-as-author.sh`. The Codex GitHub App only monitors trigger comments authored by `nathanjohnpayne` (#405), so this trigger is an author-identity write even though the polling reads use the reviewer PAT. `coderabbit-wait.sh` and other long-tail helpers continue to use the cached PATs they load from preflight; the wrapper-mandatory contract in this section covers the core guarded `gh` write surface.

#### PAT lookup table

> This is the **canonical source** for PAT lookups across the mergepath ecosystem. `CLAUDE.md` (project), `AGENTS.md`, and `DEPLOYMENT.md` all reference this section instead of duplicating the table. Machine-level `~/GitHub/CLAUDE.md` mirrors the same rows for cross-repo work. The same four identities also have SSH signing keys uploaded to GitHub — see the [SSH Signing Keys](#ssh-signing-keys) section below for the inventory + verify/re-upload commands.

| Agent | Reviewer Identity | 1Password Item ID | Cached env var (primary) | `op read` path (setup-only fallback) |
|-------|-------------------|-------------------|--------------------------|--------------------------------------|
| Claude | `nathanpayne-claude` | `pvbq24vl2h6gl7yjclxy2hbote` | `$OP_PREFLIGHT_REVIEWER_PAT` | `op://Private/pvbq24vl2h6gl7yjclxy2hbote/token` |
| Cursor | `nathanpayne-cursor` | `bslrih4spwxgookzfy6zedz5g4` | `$OP_PREFLIGHT_REVIEWER_PAT` | `op://Private/bslrih4spwxgookzfy6zedz5g4/token` |
| Codex | `nathanpayne-codex` | `o6ekjxjjl5gq6rmcneomrjahpu` | `$OP_PREFLIGHT_REVIEWER_PAT` | `op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token` |
| Human | `nathanjohnpayne` | `sm5kopwk6t6p3xmu2igesndzhe` | `$OP_PREFLIGHT_AUTHOR_PAT` | `op://Private/sm5kopwk6t6p3xmu2igesndzhe/token` |

**Cached-variable usage is the primary pattern.** After a single `eval "$(scripts/op-preflight.sh --agent <agent> --mode review)"` at session start, all subsequent API calls use the env var directly — no biometric burned per call:

```bash
# Read-path identity check (PRIMARY — uses cached PAT, no biometric).
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq '.login'
# expected: nathanpayne-<agent>

# Reviewer write path: wrapper resolves and verifies the reviewer token,
# then runs the command with process-local GH_TOKEN. Set the reviewer
# explicitly when the driver environment is ambiguous.
GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> \
  scripts/gh-as-reviewer.sh -- gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

# Author write path: wrapper resolves and verifies the author token. For
# gh pr create it also reads the created PR author with the same token.
scripts/gh-as-author.sh -- gh pr create --title "..." --body "..."
```

##### Fallback / setup-only: inline `op read`

> **⚠️ This triggers a biometric prompt every call. Use only when `op-preflight.sh` is unavailable** — for example, during the initial bootstrap of a new machine before the cache directory exists, or in a CI runner that has not been wired through preflight. Routine agent work should always use the cached `$OP_PREFLIGHT_*_PAT` env vars above.

```bash
# Setup-only — every invocation prompts for Touch ID.
GH_TOKEN="$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')" \
  gh api user --jq '.login'
```

- Use the item ID from the lookup table above for your agent identity. Do not use the 1Password item title.
- To verify a cached PAT, use `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login` or let the wrapper perform the same check before the write. Do not use `gh auth status` as an attribution proof; it is affected by env tokens and does not replace the wrapper's effective-login check.
- If `op whoami` says you are not signed in, still run the `op read ...` command in an interactive TTY. That is what triggers the 1Password biometric prompt on local machines.
- If GitHub returns `Review Can not approve your own pull request`, you either the PR author is not `nathanjohnpayne`, the reviewer token resolved to the author identity, or the no-self-approve scoping rule below applies. Confirm with `gh pr view <PR#> --json author` and `GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> scripts/gh-as-reviewer.sh -- gh api user --jq .login` before retrying. If you intentionally skipped `--approve` under the no-self-approve scoping rule below (Phase 4 / above-threshold PRs), post `--comment` instead and let Phase 4 carry the gate.

### SSH Signing Keys

> This is the **canonical source** for SSH signing key inventory across the mergepath ecosystem. Machine-level `~/GitHub/CLAUDE.md` mirrors the same rows for cross-repo work. Sister-table to the [PAT lookup table](#pat-lookup-table) above: both inventory the same four identities, just for different per-identity artifacts.

Every identity in the [PAT lookup table](#pat-lookup-table) above also has an SSH signing key uploaded to its GitHub account so commits and tags attributed to that login render as **Verified** instead of the "this user has not yet uploaded their public signing key" notice. By convention every key on a given machine shares the title `<machine-name>-signing-key` (currently `mergepath-mac signing key` for the first Mac in the rotation; titles get per-machine suffixes once a second machine joins). The local pub keys live in `~/.ssh/keys/` and are referenced (for auth, not signing) by `~/.ssh/config`.

| Account             | Local pub key                            | GitHub signing key id (mergepath-mac) |
|---------------------|------------------------------------------|---------------------------------------|
| nathanjohnpayne     | `~/.ssh/keys/github_nathanjohnpayne.pub` | 928533                                |
| nathanpayne-claude  | `~/.ssh/keys/github_claude.pub`          | 949665                                |
| nathanpayne-cursor  | `~/.ssh/keys/github_cursor.pub`          | 949666                                |
| nathanpayne-codex   | `~/.ssh/keys/github_codex.pub`           | 949667                                |

**Why all four — including the bot accounts.** Local `git commit` only ever signs as `nathanjohnpayne` (`git config --global user.signingkey` is the human identity per the active-account convention above), so the human's key is the one git invokes day-to-day. The bot accounts need keys uploaded so that GitHub-attributed activity verifies correctly under their logins: web-flow commits a bot makes via the GitHub UI, future API-authored commits via `PUT /repos/:owner/:repo/contents/:path`, or any other surface where GitHub does the signing on behalf of the bot identity. Without the upload, every such commit renders with the "this user has not yet uploaded their public signing key" notice and a yellow "Partial Verified" badge.

**Verify** — read-only check, should return exactly one entry per account (titled `mergepath-mac signing key` on this Mac):

```bash
for acct in nathanpayne-claude nathanpayne-cursor nathanpayne-codex nathanjohnpayne; do
  echo "=== $acct ==="
  GH_TOKEN="$(gh auth token --user "$acct")" \
    gh api /user/ssh_signing_keys --jq '.[] | {id, title, key: (.key[0:60])}'
done
```

**Re-upload (missing key, revoked, or new machine bootstrap):**

```bash
acct="nathanpayne-<bot>"          # claude | cursor | codex
pub="$HOME/.ssh/keys/github_<bot>.pub"
GH_TOKEN="$(gh auth token --user "$acct")" gh api -X POST /user/ssh_signing_keys \
  -f "title=mergepath-mac signing key" \
  -f "key=$(cat "$pub")"
```

The bot PATs already carry the `admin:ssh_signing_key` scope, so no re-auth is required for routine uploads. The `/user/ssh_signing_keys` endpoint operates on the authenticated user, so `GH_TOKEN` is honored directly — no author wrapper or stored-account selection step is needed (unlike core guarded reviewer writes covered by the wrapper contract above).

**On a new machine.** The key-id column above is per-machine; a second machine joining the rotation will have its own ids and should use a distinguishing title (e.g. `mergepath-linux-signing-key`). The verification + re-upload commands above are machine-agnostic.

### No-self-approve scoping

The no-self-approve rule applies **only** to PRs that meet `external_review_threshold` or match `external_review_paths` (the Phase 4 PRs). For those, the agent's own reviewer identity posts `--comment` only — the merge gate is the external reviewer (Phase 4a Codex 👍 via gate (b) branch 2, or Phase 4b CLI handoff `APPROVED`). Posting `--approve` from your reviewer identity on a Phase 4 PR would short- circuit the cross-agent gate the threshold exists to enforce.

For PRs that do **not** meet the threshold (no Phase 4 step in the flow), the reviewer identity posting `gh pr review --approve` once CodeRabbit has cleared the current HEAD with no unaddressed `Potential issue` / `⚠️` findings is the **intended** path: it satisfies branch protection's required-approving-review requirement without bouncing the change to an external agent for a process-overkill approve on a small, self-contained PR. This matches the Phase 2 "Steps 4–6 repeat until the reviewer identity approves" text below.

### Operation-to-Identity Matrix

The current contract is token-attributed for the guarded core `gh` write surface. The #410 spike verified that tested `gh pr` / `gh issue` writes attribute to the process-local `GH_TOKEN` when it is set; #411 makes that the enforced path by requiring wrappers that verify the token before the write.

| Operation | Required path | Effective identity |
|-----------|---------------|--------------------|
| `gh pr create` | `scripts/gh-as-author.sh -- gh pr create ...` | `nathanjohnpayne`; wrapper verifies the author token and then verifies the created PR author with that same token |
| `gh pr merge` (squash/rebase) | `scripts/gh-as-author.sh -- gh pr merge ...` | `nathanjohnpayne` |
| `gh pr edit` (general — title/body/labels) | `scripts/gh-as-author.sh -- gh pr edit ...` | `nathanjohnpayne` |
| `gh pr edit --remove-label <protected>` | **BLOCKED** by `scripts/hooks/label-removal-guard.sh` for `needs-external-review` / `needs-human-review` / `policy-violation` / `human-hold`; use `scripts/request-label-removal.sh` | n/a |
| `gh pr comment` | `GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> scripts/gh-as-reviewer.sh -- gh pr comment ...` | reviewer identity verified from the token |
| `gh pr comment "@codex review"` (Codex trigger) | `scripts/gh-as-author.sh -- gh pr comment ... --body "@codex review"` | `nathanjohnpayne`; `codex-review-request.sh` uses this because the Codex App only monitors author-authored triggers (#405) |
| `gh pr review --comment` / `--request-changes` | `GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> scripts/gh-as-reviewer.sh -- gh pr review ...` | reviewer identity verified from the token |
| `gh pr review --approve` (under-threshold) | reviewer wrapper | reviewer identity; allowed when PR's `Authoring-Agent:` matches the agent and Phase 4 does not apply |
| `gh pr review --approve` (over-threshold, same agent) | **BLOCKED** by `scripts/hooks/gh-pr-guard.sh` per § No-self-approve scoping | n/a |
| `gh pr review --approve` (over-threshold, cross-agent) | reviewer wrapper for the cross-agent reviewer | `nathanpayne-<other-agent>` per Phase 4 |
| `gh pr view` (read) | direct read with `GH_TOKEN=<read PAT>` | no write byline |
| `gh issue create` | not hook-gated (#317 byline guard reverted) | author or reviewer token, depending on the workflow |
| `gh issue comment` | reviewer wrapper | reviewer identity verified from the token |
| `gh issue close` | not hook-gated by #411 | token selected by caller |
| `gh api GET ...` | direct read with `GH_TOKEN=<read PAT>` | no write byline |
| `gh api graphql resolveReviewThread` | `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT"` plus `identity-check.sh --expect-token-identity <reviewer>` before mutation | reviewer token |
| `gh workflow run` | direct with an author or reviewer PAT that has `workflow` scope | no comment/review byline |

Notes on the token-wrapper contract:

- **Wrapper-mandatory writes.** `scripts/hooks/gh-pr-guard.sh` blocks bare and inline-token forms of the guarded write commands before they can run. Use the author wrapper for author operations and the reviewer wrapper for reviewer comments/reviews. The hook checks command structure, including wrapper spoofing such as a wrapper path in an `echo` before a bare `gh pr create`.

- **Token verification.** `scripts/lib/gh-token-resolver.sh` selects a token from the expected preflight env var or `gh auth token --user <login>`, then verifies it with `scripts/identity-check.sh --expect-token-identity <login>`. No token material is printed. A mismatch exits before the wrapped write starts.

- **Legacy keyring assertions.** `scripts/identity-check.sh` still has keyring assertion modes for helper paths that have not moved to the wrapper contract yet. Those modes are compatibility checks, not the canonical path for the core guarded `gh` writes listed above.

## Workflow

### Phase 0: Credential Preflight

> Run this once at the start of every PR review or deploy session. It front-loads all 1Password credential reads and SSH key authorization into a single burst of biometric prompts (~15 seconds), so the human can step away for the rest of the session.

```bash
# Session start (one biometric burst). `--mode review` is the DEFAULT
# (changed from `--mode all` in #282) — most agent work only needs the
# reviewer/author PATs + SSH warming, not deploy credentials.
eval "$(scripts/op-preflight.sh --agent claude --mode review)"

# Every subsequent tool call (idempotent, NEVER prompts for biometric):
eval "$(scripts/op-preflight.sh --agent claude --check)"
```

The `--check` (alias `--status`) mode is the lightweight idempotent re- validation pattern: it loads the cached export statements without invoking `op`, without warming SSH, and without reading ADC. On a missing or stale cache it exits non-zero with a remediation message pointing back at `--mode review`. Combined with `OP_PREFLIGHT_QUIET=1` the cache-hit path collapses to a single stderr line, so noisy agent sessions don't accumulate a verbose preflight block on every tool call. See nathanjohnpayne/mergepath#282.

Replace `claude` with `cursor` or `codex` depending on which agent is running. The `--mode` flag controls what is loaded:

| Mode | What's loaded |
|------|--------------|
| `review` | Reviewer PAT + author PAT + SSH keys (**DEFAULT**) |
| `deploy` | GCP ADC credential + Cloudflare cache-purge token |
| `all` | Everything |

After preflight, these environment variables are set:
- `OP_PREFLIGHT_REVIEWER_PAT` — use with `GH_TOKEN=` for reviewer-identity read-path API calls and as the preferred token source for `scripts/gh-as-reviewer.sh`. The wrapper verifies the token's effective login before any reviewer write.
- `OP_PREFLIGHT_AUTHOR_PAT` — use with `GH_TOKEN=` for author-identity read-path API calls and as the preferred token source for `scripts/gh-as-author.sh`. The wrapper verifies the token before author writes and performs same-token author verification after `gh pr create`.
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
3. The agent files a PR from the feature branch to the target branch under `nathanjohnpayne`. The PR description must include an `Authoring-Agent:` line identifying which agent wrote the code (e.g., `Authoring-Agent: claude`). This is required because all PRs share the `nathanjohnpayne` author identity, and the workflow uses this line to assign the correct reviewer identity for internal self-peer review. The title and description must describe the work itself, not the session that produced it — see `docs/agents/operating-rules.md` § "PR and issue titles/descriptions: describe the work, not the session".

### Phase 2: Internal Review (Self-Peer Review)

4. The agent switches its Git identity to its reviewer account (e.g., `nathanpayne-claude`).
5. The reviewer identity checks out the PR branch, reviews the diff, and posts review comments on the PR with specific, actionable feedback.
6. The agent switches back to `nathanjohnpayne` and addresses each comment—pushing fix commits to the same branch.
7. Steps 4–6 repeat until the reviewer identity approves the PR with no outstanding issues. The mechanism of "approves" is scope-dependent: for under-threshold PRs (Phase 3 below), the reviewer identity posts `gh pr review --approve` to satisfy branch protection's required-approving-review check. For above-threshold PRs (Phase 4), the reviewer identity posts `gh pr review --comment` only — the cross-agent merge gate is carried by Phase 4 (Codex 👍 in branch 2 of gate (b), or external reviewer's `APPROVED` in Phase 4b). See [No-self-approve scoping](#no-self-approve-scoping) above.

**All review rounds are captured as GitHub PR comments and commits.** The back-and-forth should read like two developers collaborating.

### Phase 2.5: Automated External Review (CodeRabbit)

> **Applies only to repos with `coderabbit.enabled: true` in `.github/review-policy.yml`.** Skip this phase for repos where CodeRabbit is not enabled.

> **Config posture & runbook:** the `.coderabbit.yml` posture audit (why we run `profile: chill`, the `base_branches`/`learnings.scope`/`auto_pause_after_reviewed_commits` decisions), the `@coderabbitai rate limit` diagnostic, and the author-seat coverage procedure live in [`docs/agents/coderabbit-audit.md`](docs/agents/coderabbit-audit.md) (#491). Consult it before changing `.coderabbit.yml` or debugging a "CodeRabbit never ran" case.

After internal review passes (Phase 2), CodeRabbit provides an independent automated review:

1. **Wait for CodeRabbit.** CodeRabbit automatically posts a review when the PR is opened or updated. Prefer `scripts/coderabbit-wait.sh <PR#>` over an ad-hoc poll loop — the script anchors its "cleared" signal on the current HEAD committer date, so it will not treat a stale review from a prior HEAD as current; it also handles CodeRabbit's rate-limit state, which the platform does NOT auto-retry (see nathanjohnpayne/mergepath#138), and CodeRabbit's auto-pause state (see nathanjohnpayne/mergepath#490). On exit code `0` CodeRabbit has cleared with no high-severity markers; on `2` it has findings to address; on `4` the `coderabbit.max_wait_seconds` grace window elapsed (the agent may log a warning and proceed since CodeRabbit is advisory); on `5` the rate-limit retry budget was exhausted — alert the human rather than proceed, *unless* the Codex failover engaged (`codex_failover_requested: true`; see the rate-limit → Codex failover paragraph below), in which case `5` is a non-blocking note and the PR proceeds via Phase 4a; on `6` CodeRabbit auto-review is skipped and not (re-)invocable — see the auto-pause / skip paragraph below. If exit `4` occurs and `coderabbit.status_probe_enabled` is true, the helper has posted `@coderabbitai, how is the review going?`, waited the bounded `coderabbit.status_probe_wait_seconds` window, and surfaced CodeRabbit's narrative reply in the output JSON's `status_probe` field. That reply is narration only; it is never counted as a review or clearance signal.

   **Auto-pause and other skips (exit `6`, #490).** CodeRabbit auto-pauses incremental review after `reviews.auto_review.auto_pause_after_reviewed_commits` reviewed commits (we set this deliberately in `.coderabbit.yml`; the upstream default is 5) and posts a durable "Reviews paused" NOTE that it does NOT auto-resume. Our long agent-loop PRs cross that threshold, so the helper detects the pause via the stable `review paused by coderabbit.ai` marker, posts **`@coderabbitai resume`** (a one-shot `@coderabbitai review` would re-pause after the next push), and resumes polling — bounded by `coderabbit.max_resume_retries`. The `paused` state is distinct from `rate_limit` (#489) and `in_progress`. If resume retries are exhausted, the helper exits `6` with `status: "paused"` and `skip_reason: "paused"`; raise `auto_pause_after_reviewed_commits` or intervene. The helper also surfaces — without re-invoking — the static skips where auto-review will never fire: a PR whose base branch is not in `reviews.auto_review.base_branches` (`skip_reason: "non-base-branch"`) and a draft PR when `drafts: false` (`skip_reason: "draft"`). All exit-`6` cases set the JSON `skip_reason` field so the caller can act (retarget the base, mark the PR ready, or escalate) rather than waiting out a full timeout.

   **Rate-limit → Codex failover (exit `5`, #489).** When CodeRabbit reports rate-limited and `coderabbit.codex_failover_on_rate_limit` is true (the default), the helper requests `@codex review` once — HEAD-pinned and idempotent — by invoking `scripts/codex-review-request.sh --trigger-only` with `MERGEPATH_PHASE_4A_GATED=true`, so the PR advances via Codex (the real blocking gate) instead of idling on CodeRabbit's hourly allowance. It composes with `codex.request_by_default` (#486) but fires regardless of it, and it is time-boxed/self-reverting: a single trigger per run with no permanent Codex pin, so once CodeRabbit recovers the steady-state posture returns. The failover is recorded in the output JSON as `codex_failover_requested: true`. Its effect on the exit-`5` contract: a `rate_limit_stalled` that engaged the failover is a **non-blocking note**, not a hard human-alert — Codex was requested and the normal Phase 4a flow + `Merge clearance gate` carry the merge. Only an exit `5` with `codex_failover_requested: false` (the knob off, or `codex.enabled: false` so there is nothing to fail over to) still requires alerting the human. In the **agent-driven wait**, the agent (in-session) then proceeds via the normal Phase 4a flow. In the **auto-merge workflow** (`agent-review.yml`'s `Wait for CodeRabbit` step), which bridges the author token to the failover (`OP_PREFLIGHT_AUTHOR_PAT` ← `AUTHOR_MERGE_TOKEN`, so the author-attributed `@codex review` can post in CI), the exit-`5` downgrade is **scoped to externally protected PR heads** — the unit-tested, fail-closed `scripts/coderabbit-automerge-rate-limit-gate.sh` proceeds only when `codex_failover_requested: true` **and** `scripts/merge-clearance-gate.sh --derive-rate-limit-protection` returns `true`. That query uses the live head's intrinsic threshold/protected paths, label force-on, and propagation-lane exemption, never label events alone; it returns `true` when the active `Merge clearance gate` external arm will hold the merge until Codex/external clearance lands, or when intrinsic external review applies and `codex-review-check.sh` already confirms current-head Codex/Phase-4b clearance (#713, the label-cleared-by-approval timing case). **Unprotected or vacuously gated** rate-limit stalls (under threshold, no protected paths, no label, or a lane-exempt verified head) keep blocking the auto-merge job, exactly as before this feature: merge clearance passes vacuously for them and `--trigger-only` does not wait for Codex, so proceeding would let such a PR auto-merge with neither bot having reviewed it (#512 round-3 Codex finding). Opt out per repo with `coderabbit.codex_failover_on_rate_limit: false`.
2. **Read both API endpoints.** CodeRabbit posts two types of comments that must both be checked:
   - **PR-level summary:** `gh api repos/{owner}/{repo}/issues/{pr_number}/comments` — contains the high-level walkthrough and summary.
   - **Inline review comments on the diff:** `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` — contains line-by-line findings anchored to specific code.
3. **Scan for potential issues.** Before proceeding, grep CodeRabbit's inline review comments for `Potential issue` or `⚠️`. These markers indicate findings CodeRabbit considers high-severity. Every such finding must be explicitly addressed (fixed or dismissed with reasoning). When `feedback_policy` marks additional CodeRabbit tiers `required` (e.g. `p2` / `nitpick`, or `mode: address-all`), disposition those too — map each finding onto the shared ladder per [§ Feedback Disposition Policy](#feedback-disposition-policy). The tier-aware CodeRabbit gate that *enforces* this at merge time shipped in #577 (`scripts/coderabbit-severity-gate.sh`, merged in #590); this step remains the agent-discipline complement that reviews and dispositions the findings the gate checks for.
4. The agent addresses substantive CodeRabbit findings — fixing issues or posting a reply explaining why a finding is not applicable.
5. The agent is not required to fix every CodeRabbit comment. Use judgment: fix genuine issues, dismiss false positives with a brief explanation. However, all `Potential issue` / `⚠️` findings require an explicit response.
6. **Record the feedback disposition (#584).** After adjudicating each CodeRabbit finding (step 4), record a per-finding verdict via `scripts/coderabbit-record-feedback.sh <PR#> [--scan | --findings-json <FILE|->] --verdict <comment_id>=<verdict>[:<reason>]`:

   - **Validated as real and actioned (fixed)** → `--verdict <id>=fixed` (disposition `fixed`).
   - **Determined to be a false positive / rebutted** → `--verdict <id>=false-positive[:<reason>]` (disposition `rebutted`).

   This is the CodeRabbit counterpart of the Codex step 13a-bis recorder, with **one by-nature asymmetry**: Codex ends each finding with *"Useful? React with 👍 / 👎."*, so `scripts/codex-record-feedback.sh` POSTs the solicited reaction. CodeRabbit does **not** solicit per-finding reactions, so `scripts/coderabbit-record-feedback.sh` is **disposition-logging only** — it NEVER posts a reaction (or any other write) to GitHub; every GitHub call it makes is a read (REST GETs plus the read-only GraphQL `reviewThreads` query for the `resolved` bit). The helper:

   - Classifies each finding with the shared `coderabbit_tier_of` (the same classifier `scripts/coderabbit-severity-gate.sh` keys on), so the ledger tier vocabulary cannot drift.
   - Is **HEAD-pinned**: `--scan` collects only the current HEAD's CodeRabbit inline findings (bot-authored AND `commit_id`/`original_commit_id` == HEAD — the same current-finding scope the severity gate gates on). Findings supplied via `--findings-json` inherit the producer's scoping.
   - Is **idempotent / append-only**: re-recording a comment with the same disposition is a no-op; a different disposition appends a superseding row flagged `superseded_prior: true` without rewriting prior rows.
   - Writes a **durable per-finding verdict** (comment_id, tier, verdict, disposition, optional reason, resolved bit) to a JSONL ledger (`.mergepath/coderabbit-feedback-ledger.jsonl` by default) so CodeRabbit review precision is trackable over time, symmetric with the Codex ledger from #487.

   This step is disposition-tracking, not a merge gate — CodeRabbit remains advisory. It records the same fix/rebuttal decisions the agent already made in step 4; skipping it leaves the CodeRabbit ledger empty but does not block the merge.
7. CodeRabbit review is advisory. It does not block merge via CI and does not submit a "Changes Requested" review state.

CodeRabbit's advisory status does **not** override GitHub branch protection's `required_conversation_resolution` gate. A CodeRabbit comment may be left unfixed only when it is not an unresolved GitHub review conversation, or when the agent has posted an explicit rationale and used the allowed bot-thread resolution path in the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate).

**CodeRabbit runs on ALL PRs** in enabled repos, regardless of size or whether the external review threshold is met. It provides a consistent automated second opinion on every change.

The agent proceeds to Phase 3 (Threshold Check) after addressing CodeRabbit comments, even if some non-blocking comments remain open. CodeRabbit is an additional review layer, not a replacement for the existing threshold-based external agent handoff or the pre-merge conversation-resolution gate.

#### CodeRabbit Review Checklist

Before moving past Phase 2.5, confirm all of the following:

- [ ] CodeRabbit has posted its review on the current HEAD (use `scripts/coderabbit-wait.sh <PR#>` — exit `0` or `2`; `4` is a grace-window timeout that may be logged and skipped since CodeRabbit is advisory)
- [ ] If `scripts/coderabbit-wait.sh` exited `5` (rate-limit stalled) **with `codex_failover_requested: false`**, the human has been alerted rather than the agent proceeding (an exit `5` with `codex_failover_requested: true` is a non-blocking note — the Codex failover engaged and the PR proceeds via Phase 4a, #489)
- [ ] If `scripts/coderabbit-wait.sh` exited `6` (auto-review skipped — `skip_reason` is `paused` / `non-base-branch` / `draft`), the named cause has been resolved (raise `auto_pause_after_reviewed_commits` or wait out the bounded resume retries for `paused`; retarget the base for `non-base-branch`; mark the PR ready for `draft`) rather than the agent treating it as a clean clearance
- [ ] Read PR-level comments via `issues/{pr}/comments` endpoint
- [ ] Read inline diff comments via `pulls/{pr}/comments` endpoint
- [ ] Grepped inline comments for `Potential issue` and `⚠️` — all flagged findings addressed
- [ ] Substantive findings fixed or dismissed with reasoning
- [ ] Recorded each finding's disposition (fixed / rebutted) via `scripts/coderabbit-record-feedback.sh` (disposition-logging only — no reaction posted; #584)

### Pre-Merge Review Conversation Gate

Every merge path must pass this gate immediately before calling `gh pr merge`, and must repeat it after any push or review-thread reply that can change GitHub conversation state.

1. Query GitHub's review-thread state, not just flat PR comments. Use `scripts/resolve-pr-threads.sh <PR#> --list` or an equivalent GraphQL `reviewThreads` readback that reports each thread's `isResolved` value.
2. Confirm there are **zero unresolved review conversations**. GitHub's branch-protection error "All comments must be resolved" is driven by this review-thread state; `gh pr checks`, issue comments, and pull request review comments alone are not sufficient readback.
3. For bot-authored current-head threads only, if the finding has already been fixed or rebutted on-thread, resolve it. **Fixing review feedback includes resolving the associated review thread, not just pushing a code commit** — a fix that leaves its thread open still blocks the conversation-resolution gate and still surfaces in the weekly unresolved-feedback sweep. The two resolve paths are split by **disposition** — each records a different `[mergepath-resolve:<class>]` tag, and the daily rollup / weekly sweep read that tag as the disposition of record, so pick the mode that matches what actually happened to the feedback (#575):
   - `scripts/resolve-pr-threads.sh <PR#> --resolve-actioned` is the tool for **fixed or rebutted** feedback — the default on a PR you pushed fixes to. It resolves **only** threads whose fix or rebuttal is demonstrable from the current PR state, tagging the truthful classes — `addressed-elsewhere` (an agent commit touching the anchored file, after the latest re-raise) or `rebuttal-recorded` (a substantive agent rebuttal after the latest re-raise). Routing-only classes (`canonical-coverage`, `templated-render`) are deliberately **not** treated as actioned here: they indicate where a durable fix belongs, not that one happened, so a fresh finding on a canonical path is left unresolved rather than auto-resolved by routing alone. The gate evaluates action **independently of routing**, so a canonical/templated thread that *does* carry action evidence (a fix commit touching it, or a rebuttal) is still resolved. Every non-actioned thread is left for the weekly sweep.
   - `scripts/resolve-pr-threads.sh <PR#> --auto-resolve-bots` is the tool for **explicit deferral** — current-HEAD bot threads deliberately left unfixed on this PR because they are tracked elsewhere (the standard case: canonical-coverage findings on sync mirrors, deferred to a follow-up issue via `--rationale`). It resolves **every** current-HEAD bot thread, which is what clears the `required_conversation_resolution` gate to merge, and tags each thread `deferred-to-followup` so the daily rollup re-surfaces it. It is **not** the tool for fixed or rebutted findings — that mis-records them as deferred (#571). As a guard, a thread that is demonstrably actioned (per the same evidence gate `--resolve-actioned` uses) is auto-upgraded to its truthful `addressed-elsewhere`/`rebuttal-recorded` tag with an INFO line.
   - `scripts/resolve-pr-threads.sh <PR#> --resolve-verified-propagation` is the tool for **verified canonical propagation** — routing-class threads (`canonical-coverage`, `templated-render`) whose durable fix already landed in mergepath and demonstrably reached this consumer. It resolves a thread only when the consumer file at the compared ref — the PR's own head while the PR is open (so a pre-merge run never resolves over drift the PR itself carries), the default-branch HEAD once it is closed/merged — byte-matches the mergepath canonical source (or, for templated entries, the rendered template output for that consumer), the consumer tree entry's mode/type matches the source (chmod flip / symlink swap rejection), and the mergepath source has a fix commit strictly newer than the finding (upstream-fix evidence; a pre-dating fix skips conservatively — resolve manually with evidence), tagging `verified-propagation` (#572, #616). Any lookup, fetch, or render failure is a fail-closed skip, never a resolve. A thread with action evidence is auto-upgraded to its truthful actioned class first (#575); unverifiable threads are left for the weekly sweep.

   Each path runs an identity-checked `resolveReviewThread` followed by a `reviewThreads`/`nodes(ids:)` readback confirming `isResolved: true`, and exits non-zero (fail closed) if any resolve cannot be confirmed. Then query `reviewThreads` again. For stale bot-authored threads whose finding was fixed by a later commit, use the identity-checked `resolveReviewThread` path directly. If the resolution is not demonstrable from the current HEAD or on-thread rebuttal, request a fresh bot review instead of resolving the thread.
4. Registered agent-reviewer threads (`available_reviewers`, for example `nathanpayne-claude`, `nathanpayne-cursor`, and `nathanpayne-codex`) are agent-authored, not real-human-authored. Resolve them only with an identity-checked `resolveReviewThread` path after the finding has been fixed or rebutted and the reviewer identity has accepted the fix, approved the current HEAD, or posted an on-thread acknowledgment.
5. Never auto-resolve real human-authored threads. If a thread authored by `nathanjohnpayne` or another non-agent human account remains unresolved, stop before merge and wait for the human to resolve it or give explicit direction.

This gate is a branch-protection requirement, not a review-disposition choice. It applies to under-threshold PRs, Phase 4a, Phase 4b, and propagation-lane PRs.

### Phase 3: External Review Threshold Check

> **Note on automation timing:** CI workflows may apply the `needs-external-review` label automatically when a PR is opened or updated, as an early advisory based on line count and protected paths. The label blocks merge via the label-gate until external review clears. When the label is present, the agent's responsibility after internal review passes is to proceed to [Phase 4](#phase-4-external-review) — which routes the PR to Phase 4a (automated via the Codex GitHub App) or Phase 4b (manual handoff) depending on `codex.enabled` and on whether 4a converges. The label itself does NOT imply immediate human mediation; Phase 4b only posts the handoff message when the fallback path is actually taken. On `synchronize`, the labelers compute an external-review fingerprint across every changed file once external review is required, including both the head-side and merge-base-side tree entries for those files. If a prior affirmative Codex verdict reviewed the same fingerprint, a pure base-only sync or update-branch merge does not re-add `needs-external-review` or request a redundant Codex pass; any real content or reviewed-diff change produces a different fingerprint and re-enters Phase 4 (#705).

8. After internal review passes, the agent evaluates whether the PR meets the external review threshold (see [Review Policy Configuration](#review-policy-configuration)).
9. If the threshold is **not** met: when `codex.request_by_default` is `true` (the default) and `codex.enabled` is not `false`, the agent first requests a Codex review by running `scripts/codex-review-request.sh <PR#>` (without `MERGEPATH_PHASE_4A_GATED`) so the `@codex review` trigger is posted on this under-threshold PR — see [`codex.request_by_default`](#codexrequest_by_default--request-codex-on-every-pr-486). The agent **is** the caller; there is no separate workflow auto-caller. This trigger is **advisory and does not gate the merge** — the threshold (not `request_by_default`) governs the merge gate, so an exit `4` (timeout) or `5` (`NO_TRIGGER_REQUESTED`) does not block. The agent then runs the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate) and merges the PR as `nathanjohnpayne` once that gate is clean. Done.
10. If the threshold **is** met, the agent proceeds to [Phase 4: External Review](#phase-4-external-review). Phase 4 itself routes the PR to Phase 4a (automated, via the Codex GitHub App) or Phase 4b (manual handoff) based on `codex.enabled` in `.github/review-policy.yml` and on whether 4a's automated loop converges. The agent does NOT post a handoff message directly from this step — Phase 4b posts its own handoff message if and when the fallback path is taken.

### Phase 3.5: Propagation PR review lane

A **propagation PR** — one opened by `scripts/sync-to-downstream.sh` to mirror canonical/kit paths from `mergepath` into a downstream consumer — is a special case of the threshold check. Its content was **already reviewed in the upstream `mergepath` PR** that introduced it; the propagation PR only re-applies that already-reviewed content verbatim. It is also large by construction (a `--sync-all` PR mirrors the full canonical surface) and always touches `.github/**`, so both the line-count threshold *and* the `external_review_paths` check would flag every sync PR for a redundant Phase 4 review of non-novel code.

The lane closes that mismatch. `.github/workflows/pr-review-policy.yml`'s External Review Check recognizes a propagation PR and **exempts it from the `needs-external-review` label** — and removes the label if a prior run applied it — when **all** of the following hold:

1. The lane is enabled. **Default: ON** ([#434](https://github.com/nathanjohnpayne/mergepath/issues/434)) — an absent `propagation_prs:` block (or absent `enabled` key) in `.github/review-policy.yml` counts as enabled; an explicit `propagation_prs.enabled: false` opts the repo out. The flag originally required an explicit `enabled: true`, but `review-policy.yml` is intentionally never propagated, so no consumer had the block and the lane was dormant fleet-wide — an enable flag must not live solely in a never-synced file. The default adds no new trust: recognition is still gated on criterion 4's byte-level verification, and a PR cannot grant itself the default because the config is read from the PR's base commit.
2. The PR branch name starts with `propagation_prs.branch_prefix` (default `mergepath-sync/` when absent; must match `SYNC_BRANCH_PREFIX` in `scripts/sync-to-downstream.sh`).
3. The PR author is `author_identity` — the propagation actor.
4. The PR is a **verified byte-for-byte faithful mirror** of `mergepath` at the source commit. This is the load-bearing teeth.

A regression net rides the weekly drift audit: `scripts/audit-propagation-lane.sh` checks every consumer's live default branch for the three lane preconditions a file-drift audit alone can't see together (lane code present in the synced workflow, no unexpected `enabled: false`, `author_identity` present) and fails the `weekly-drift-audit.yml` run when the lane would not fire on a consumer.

Path-confinement alone is **not** sufficient — `.github/workflows/*` *is* propagation surface, so a check that only asked "is every changed file under a manifest path?" would let a `mergepath-sync/**` PR hand-edit a workflow and skip review (Codex P1 on [#268](https://github.com/nathanjohnpayne/mergepath/issues/268)). Criterion 4 is therefore a real content comparison:

- The `<sha>` in the branch name (`mergepath-sync/[sync-all-]<sha>`) is checked out from **public** `nathanjohnpayne/mergepath` — no token needed.
- `mergepath@<sha>`'s **own** `scripts/workflow/verify-propagation-pr.sh` byte-compares every file the PR changes against `mergepath@<sha>`'s content, using `mergepath@<sha>`'s manifest as the authoritative path list. Every changed file must be under a manifest path **and** byte-match `mergepath@<sha>` (both-present-equal, or both-absent for a faithful delete-propagation).
- All trust inputs are sourced away from the PR's own checkout, which the PR could tamper with: the **config** (criteria 1–3) is read from the PR's **base** commit, and the **verifier + manifest + canonical content** all come from the immutable, public `mergepath@<sha>`. The PR controls only its own content — which is exactly what the byte-compare checks.

A lane PR is **not** un-reviewed. It is still subject to the full under-threshold path: required CI green, CodeRabbit advisory review (on the wave canary — fan-out mirrors opened with `--coderabbit-ignore` skip the advisory pass; see Wave audit below), and an internal reviewer-identity `APPROVED`. The lane removes **only** the cross-agent Phase 4 external review, because re-reviewing a byte-verified mirror of already-reviewed content adds latency without adding signal.

Worked example: in a `--sync-all` wave, the pure-mirror consumer PRs verify clean and take the lane (merge via the under-threshold path); a consumer PR that also carries a hand-edit — even one touching a manifest path, e.g. a one-off convergence commit — fails the byte-compare, keeps `needs-external-review`, and goes through normal Phase 4.

**Prompt gate re-evaluation (#658).** The lane's head-pinned `mergepath-propagation-lane verified-head=<sha>` marker (a `github-actions[bot]` issue comment) is also the signal the `Merge clearance gate` required check reads to exempt a verified propagation head (`scripts/merge-clearance-gate.sh` `lane_verified()`). Before #657's triage change, the `needs-external-review` add/remove dance produced a PAT-driven `unlabeled` event that re-ran the gate; once triage stopped adding the label there was nothing to re-trigger it, so a verified sync PR rode a fail-closed spurious-red gate until the 15-minute scheduled sweep. The marker comment itself cannot re-trigger the gate — it is posted with the workflow's `GITHUB_TOKEN`, and GITHUB_TOKEN-authored events create no workflow runs — so instead the lane, right after posting a fresh marker, sends a PAT-driven `merge-clearance-recheck` `repository_dispatch`, and `merge-clearance-gate.yml`'s `dispatch-recheck` job resolves the PR from the payload, re-runs the gate, and posts a fresh `check_run` to the PR head. The dispatch is best-effort (any failure just falls back to the sweep, so it never fails the lane) and adds no trust: it only schedules a re-run — clearance is still re-derived from the head-pinned `github-actions[bot]` marker in `lane_verified()` on the current head, and label events remain untrusted (not head-pinned proof).

**Wave audit (#662).** The lane removes the per-PR external gate; the wave-level fresh-eyes review runs ONCE instead of once per consumer. `scripts/wave-audit.sh` dispatches a scoped automated Phase 4b review (§ Phase 4b) against the wave canary, over the canonical range since the last `wave-audit-pass/<sha>` watermark tag, under the `propagation_audit:` posture in `.github/review-policy.yml`. It fails closed unless the canary head is lane-verified (a range-scoped APPROVED is only sound over a byte-verified mirror), and paths newly added to the manifest are audited in full against the empty tree rather than escaping the range diff as unchanged. On APPROVED the watermark advances (tag pushed) and the fan-out mirrors merge on consumer CI + lane byte-verification only — opened with `sync-to-downstream.sh --coderabbit-ignore`, with no `@codex review` trigger posted on mirrors. On CHANGES_REQUESTED the fix lands at the mergepath source and the wave is re-cut, never patched in the mirror; the superseded canary takes the blocking review with it. If the reviewer is unavailable (quota, timeout, automation off), the wave may proceed on CI + lane, and the un-audited range chains into the next wave audit automatically because the watermark only advances on a posted APPROVED. Full procedure: `docs/agents/propagation-ordering.md` § Wave audit.

### Phase 4: External Review

Phase 4 has two sub-phases that together cover the two ways external review can run:

- **Phase 4a — Automated external review** via the ChatGPT Codex Connector GitHub App. This is the default happy path. The authoring agent drives the review loop without human intervention until Codex signals clearance, then runs a merge-gate check and merges.
- **Phase 4b — Manual CLI fallback** via a different agent's CLI session (e.g., Codex CLI as `nathanpayne-codex`, or Cursor, or Claude Code). This is the escape hatch when 4a escalates (disagreement or runaway), times out, or is unavailable because `codex.enabled: false`. The human mediates the handoff.

An agent proceeds to 4a first. If 4a escalates, times out, or is disabled, the agent falls back to 4b and surfaces the handoff to the human per [Handoff Message Format](#handoff-message-format).

#### Phase 4a: Automated External Review (Codex GitHub App)

> **Applies only to repos with `codex.enabled: true` in `.github/review-policy.yml`.** The **ChatGPT Codex Connector GitHub App must also be review-ready on the repository**, meaning installed, with Code Review enabled at [chatgpt.com/codex/cloud/settings/code-review](https://chatgpt.com/codex/cloud/settings/code-review), AND with a Codex environment configured at [chatgpt.com/codex/cloud/settings/environments](https://chatgpt.com/codex/cloud/settings/environments). "Installed" alone is not sufficient — a PR in a repo where the App is present but the environment is not configured will receive a "create an environment for this repo" comment from `chatgpt-codex-connector[bot]` instead of a review (observed on PR #62 on 2026-04-14). The only verification available from an agent reviewer PAT is observational: check whether a recent PR in this repo received a Codex review from `chatgpt-codex-connector[bot]` (auto-posted or in response to an explicit `@codex review` — the auto-review is unreliable, so a triggered one counts); `gh api repos/{owner}/{repo}/installation` requires a GitHub App JWT and is NOT usable from normal tokens. If any of these conditions is not met, skip directly to Phase 4b.

11a. The authoring agent runs `scripts/codex-review-request.sh <PR#>` to **explicitly trigger** a Codex review — always, on every round including the first. Do NOT rely on the Codex App's "Automatic reviews" (on-open / ready-for-review) setting to have reviewed the PR for you: it is best-effort and frequently does not fire (observed on #648 — an opened Phase-4 PR drew zero Codex activity until an explicit `@codex review` was posted, after which Codex acked 👀 within seconds and reviewed normally). The script is idempotent: it dedups on an existing HEAD-anchored Codex signal, so calling it is safe even when Codex has already reviewed the current HEAD — it posts `@codex review` only when no current signal exists, then polls.

> **The `@codex review` trigger MUST be authored by `nathanjohnpayne`.** The Codex GitHub App only monitors trigger comments from the repo's author/human identity; a trigger posted by a reviewer/bot identity (`nathanpayne-claude`/`-codex`/`-cursor`) is silently ignored and the poll runs to timeout (observed empirically on #405: a reviewer-authored trigger drew no response in 600s, an author-authored one drew a review in ~20s). `codex-review-request.sh` posts the trigger through `gh-as-author.sh` for exactly this reason — do not bypass that wrapper with a reviewer-token write.

After posting a trigger, `codex-review-request.sh` waits a short, bounded window for Codex's documented 👀 acknowledgment on that exact trigger comment. In GitHub's REST reactions payload the content value is `eyes`. If the acknowledgment is absent, the helper re-posts the exact `@codex review` trigger through the same author wrapper up to `codex.max_ack_retries`, then continues the normal review wait. The acknowledgment is not clearance: only a Codex review on HEAD with no unaddressed required-tier findings (P0/P1 by default), or a fresh 👍 / `+1` reaction on the PR issue, can satisfy the Phase 4a signal.

12a. `codex-review-request.sh` polls the PR until one of the following:

     > **Canonical completion check (#684).** Codex's two output shapes are NOT interchangeable, and checking only one endpoint can miss a completed review in either direction: (1) a **findings round** — one or more unaddressed inline comments — is delivered **exclusively** as a `COMMENTED` review object on `pulls/{pr}/reviews`, with **no accompanying issue comment at all**; (2) a **clean/affirmative verdict** is delivered as a summary **issue comment** on `issues/{pr}/comments`, not a review object. Seeing nothing on one endpoint therefore does NOT mean Codex hasn't reviewed — it may have posted to the other one. The correct check is always the UNION of both endpoints, filtered to `chatgpt-codex-connector[bot]`, HEAD-anchored (review objects via the structured `commit_id` field equaling HEAD; issue-comment verdicts via their `Reviewed commit: <sha>` line prefixing HEAD), where a 👀 reaction is ack-only and never a completion signal. `scripts/codex-review-request.sh` (wait mode) and `scripts/codex-review-check.sh` already implement this union+HEAD-anchor check — call them rather than hand-rolling a poll; a reviews-only watcher missed a HEAD-anchored issue-comment verdict on #567, and the complementary mistake — an issue-comments-only watcher missing a findings-round review object for 15+ minutes — recurred on #679.

     - **Codex posts a review.** Always in `COMMENTED` state — the Codex GitHub App never uses `APPROVED` or `CHANGES_REQUESTED`. The review body itself carries a `Reviewed commit: <sha>` line (in addition to the review's structured `commit_id` field), and findings appear as **inline comments on the diff** (`/pulls/{pr}/comments` endpoint), not in the top-level review body. Inline findings carry priority markers: `![P0 Badge]`, `![P1 Badge]`, `![P2 Badge]`, or `![P3 Badge]`. This is the ONLY shape a findings round takes — it never also produces an issue comment.
     - **Codex reacts 👍 / `+1`** on the PR issue with no review body. This is Codex's no-findings clearance signal per the ChatGPT Codex Connector documentation.
     - **Codex posts a summary issue comment** — "Codex Review: …" with a `Reviewed commit: <sha>` line — on the PR conversation (`issues/{pr}/comments`), NOT a review object. When that sha prefixes the current HEAD and there are no unaddressed required-tier (P0/P1 by default) inline findings on HEAD, the verdict is a clearance signal too. Check issue comments, not only review objects and reactions: Codex routes its verdict here, so a `pulls/{pr}/reviews`-only check can miss a completed re-review (#567). The automated merge gate `scripts/codex-review-check.sh` **honors** this HEAD-anchored issue-comment verdict for gate (b) branch 2 and gate (c) as of #600 (in addition to review objects and 👍 reactions): a `chatgpt-codex-connector[bot]` comment matching Codex's stable affirmative phrasing (`Didn't find any major issues`) whose `Reviewed commit: <sha>` **prefixes** the current HEAD, with zero unaddressed required-tier findings on HEAD, is accepted as clearance. It **fails closed** on a stale-HEAD, findings-bearing, changes-requested, or unrecognized verdict — so an ambiguous comment never clears the gate. `codex-review-request.sh`'s automated poll recognizes the same HEAD-anchored issue-comment verdict as a terminal signal (#609): a verdict of either disposition ends the poll instead of running to `review_timeout_seconds`, and an affirmative verdict with zero unaddressed required-tier findings on HEAD clears it, via the same latest-signal-wins (reaction / review / verdict) decision the merge gate uses.
     - **Account-/connection-level block (#722).** Codex answered the trigger with a plain comment reporting account-level quota exhaustion (`blocked_reason: "usage_limit"` — "You have reached your Codex usage limits for code reviews…") or that the App is not connected (`blocked_reason: "not_connected"` — "To use Codex here, connect your GitHub account…"). Such a comment carries no findings, no `Reviewed commit:` anchor, and no reaction, so it is not a review, verdict, or clearance signal — but it is terminal: re-polling or re-triggering cannot produce a review until a human acts (upgrade / add credits / connect the App). `codex-review-request.sh` detects it via the shared `scripts/lib/codex-failure-markers.sh` regexes (the same patterns `scripts/audit-codex-latency.sh` classifies retrospectively), **short-circuits the wait immediately** instead of running out `review_timeout_seconds`, and exits `4` (`FALLBACK_REQUIRED`) with the reason surfaced in the output JSON's `blocked_reason` field and in its log line. Route to Phase 4b as for a timeout, but name the real cause in the handoff (a human account action, not "wait longer") rather than reporting a generic latency timeout.
     - **Timeout.** No review and no reaction within `codex.review_timeout_seconds` (default: 840s / 14 min, retuned from the measured verdict p99 in #623). The script exits with code `4` (`FALLBACK_REQUIRED`) with `blocked_reason: null`.

13a. If Codex posted inline findings, the agent dispositions each finding in a **`required`** tier by either:

     - **Fixing the code** and pushing a new commit to the same branch, or
     - **Replying on the finding thread** with a clear rebuttal explaining why the finding does not apply (for false positives or scope disagreements).

     Which tiers are `required` is governed by `feedback_policy` in `.github/review-policy.yml` — see [§ Feedback Disposition Policy](#feedback-disposition-policy). The **default**, and the behavior when the block is absent, is **P0/P1 required** (as above) and **P2/P3 discretionary** — addressed at the agent's judgment, so not every cosmetic or nit-level finding needs a fix or a rebuttal. A repo may mark additional tiers `required`, or set `mode: address-all` so that **every** finding must be fixed or rebutted before merge. The same tier policy applies to CodeRabbit findings (Phase 2.5), mapped onto the shared ladder.

13a-bis. **Record the feedback reaction (#487).** Every Codex finding ends with a solicitation: *"Useful? React with 👍 / 👎."* After adjudicating a finding, the agent answers that prompt with a **validated** reaction via `scripts/codex-record-feedback.sh <PR#> --findings-json <request-script-json> --verdict <comment_id>=<verdict>[:<reason>]`:

     - **Validated as real and actioned (fixed)** → react `+1` (👍).
     - **Determined to be a false positive / rebutted** → react `-1` (👎).

     "Validate" means more than a blanket 👍 — confirm the finding is legitimate before a 👍 (the referenced `path:line` exists on HEAD; the claim reproduces or a fix commit addresses it). A 👎 on a genuine false positive is itself a validated signal. The helper:

     - Only reacts to findings whose body contains the exact solicitation (it never reacts on bot comments that do not solicit feedback).
     - Posts the reaction through `scripts/gh-as-reviewer.sh` under the **reviewer identity** (e.g. `nathanpayne-claude`), not the author token — this is the first place Mergepath POSTs a reaction, and it is a reviewer-attributed write. It targets the reactions endpoint matching where the finding lives (`repos/{owner}/{repo}/pulls/comments/{id}/reactions` for an inline diff finding, `…/issues/comments/{id}/reactions` for a PR-level comment).
     - Is **idempotent**: if a reaction by the reviewer identity already exists on the comment, it leaves it (no double-react, no flip).
     - Is **HEAD-pinned**: `--scan` collects only the current HEAD's latest Codex review round (consistent with `codex-review-request.sh`'s findings scoping), so a finding a later commit already fixed is not 👎'd.
     - Writes a **durable per-finding verdict** (comment_id, priority, verdict, reaction, optional reason) to a JSONL ledger (`.mergepath/codex-feedback-ledger.jsonl` by default) so Codex review precision is trackable over time and can feed the daily rollup / `pr-audit`.

     This step closes the Codex loop in the other direction from the 👀 eyes-ack read (#419): companion to the request-by-default trigger (#486), Mergepath now both requests the review and records a validated grade on each finding.

14a. The agent increments its round counter and re-runs `scripts/codex-review-request.sh` to request a re-review of the new HEAD.

> **Pushing a fix commit does NOT re-trigger a Codex review, and the on-open / ready-for-review auto-review is unreliable.** The only dependable trigger is an explicit `@codex review` comment: the App's on-open / ready auto-review frequently does not fire (#648), and a plain push (`synchronize`) is not on its trigger list at all. Step 11a's / 14a's run of `codex-review-request.sh` is therefore mandatory on every round including the first, not a formality: skip it and the prior round's stale HEAD remains the last review Codex ever produced, the merge gate's HEAD-anchored verdict check (step 16a) never sees a current clearance, and the PR sits red on `Merge clearance gate` with no review in flight and nothing arriving to fix it (#631).

15a. The loop continues until one of the following terminates it:

     - **Clearance (happy path).** Codex posts a review with no unaddressed **`required`-tier** inline findings (P0/P1 by default; see [§ Feedback Disposition Policy](#feedback-disposition-policy)) on the current HEAD, OR reacts 👍 on or after the current HEAD commit, OR posts a HEAD-anchored affirmative issue-comment verdict (`Didn't find any major issues` + a `Reviewed commit: <sha>` line whose sha prefixes HEAD) with no unaddressed required-tier findings on HEAD (#600/#567). Proceed to step 16a. A verdict-only response is recognized by both the request poll (step 12a) and the merge-gate check (step 16a, `codex-review-check.sh` as of #600) — `codex-review-request.sh`'s poll terminates on it rather than reaching `review_timeout_seconds` (#609).
     - **Disagreement (escalate).** Codex re-flags the same finding after the agent posted a rebuttal. This is "repeat-after-rebuttal." See [Disagreements and Tiebreaking](#disagreements-and-tiebreaking).
     - **Runaway (escalate).** The round counter exceeds `codex.max_review_rounds` (default: 2). The 3rd round trips this guard. See [Disagreements and Tiebreaking](#disagreements-and-tiebreaking).
     - **Timeout or account block (fall back).** `codex-review-request.sh` exits with code `4` (`FALLBACK_REQUIRED`) for the current round — either a genuine timeout (`blocked_reason: null`) or a detected account-/connection-level block (`blocked_reason: "usage_limit" | "not_connected"`, #722; short-circuited immediately rather than waited out). The agent falls back to Phase 4b either way. There is no "second timeout" escalation — a single timeout already routes to human mediation via the 4b handoff — but on a non-null `blocked_reason` the handoff should name the account action required, since re-triggering cannot help until a human resolves it.

16a. Before merging, the agent runs `scripts/codex-review-check.sh <PR#>` to verify the merge gate. All of the following must be true:

     - `gh pr checks` reports all required CI checks green
     - **Gate (b)** — one of:
       - **Branch 1 (cross-agent):** a reviewer identity from `available_reviewers` has posted an `APPROVED` review (Phase 2 internal self-peer review by a DIFFERENT agent than the author)
       - **Branch 2 (same-agent fallback, #170):** when `codex.enabled: true`, the PR's `Authoring-Agent:` matches an entry in `available_reviewers` AND `chatgpt-codex-connector[bot]` has EITHER a fresh 👍 reaction on the PR issue (timestamped at-or-after the same `REACTION_THRESHOLD` gate (c) uses) OR a HEAD-anchored affirmative issue-comment verdict (`Reviewed commit` prefixes HEAD, so no time-window is needed; #600). This is the normal path for single-agent sessions where the no-self-approve rule prohibits the author's reviewer identity from approving — Codex's external review is the cross-agent signal that substitutes for an APPROVED state. The verdict-comment branch matters because the 👍 reaction expires and Codex does not reliably re-post it on a re-review.
     - **Gate (c)** — when `codex.enabled: true`, Codex has signaled clearance on the current HEAD via one of the three forms in step 12a (COMMENTED review with no unaddressed required-tier findings, a fresh 👍 reaction, or a HEAD-anchored affirmative issue-comment verdict with no unaddressed required-tier findings; #600), OR Codex previously posted an affirmative issue-comment verdict for a commit with the same external-review fingerprint as the current head and the current head has no newer Codex signal of its own (#705), OR a Phase 4b substitute clearance has landed (an `APPROVED` review on the current HEAD from a non-author identity in `available_reviewers`). The same-fingerprint carry-forward is limited to base-only/update-branch churn: once external review is required, the fingerprint hashes the tree object IDs for every changed file in both the head and that head's merge base against the PR base, so any changed reviewed content or changed reviewed diff invalidates the carry-forward and requires fresh clearance. The Phase 4b substitute is the merge gate's understanding of Phase 4b clearance — without it, a PR that clears via Phase 4b would leave gate (c) failing forever and the auto-clear workflow would not remove `needs-external-review`. When `codex.enabled: false`, `scripts/codex-review-check.sh` ignores Codex bot reviews/reactions and gate (c) can clear only through the Phase 4b substitute path. Toggle via `codex.allow_phase_4b_substitute: true|false` in `.github/review-policy.yml` (default `true`; #218).

     **The merge gate must never require an `APPROVED` review state from `chatgpt-codex-connector[bot]` — the app does not emit that state.** This point is load-bearing; a merge gate that looks for Codex APPROVED will never be satisfied and the Phase 4a happy path will be unreachable.

     **No-self-approve rule + branch 2 interaction:** the rule "agents do not `--approve` a PR they authored under their own reviewer identity" applies to Phase 4 PRs (above `external_review_threshold` or matching `external_review_paths`) — that's the scope this section is in. For under-threshold PRs the reviewer identity is allowed and expected to `--approve`; see [No-self-approve scoping](#no-self-approve-scoping) above. Branch 2 is what makes the rule operational for the Phase 4 case — without it, same-agent PRs would deadlock on gate (b) with no escape short of human override. With branch 2, the agent posts a `--comment` review under its reviewer identity (per the rule), and the Codex 👍 carries the cross-check weight.

17a. On a passing merge gate, the agent runs the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate). If any unresolved thread remains, stop before merge and address or resolve it through the allowed path.

18a. After the merge gate and review-conversation gate are both clean, `nathanjohnpayne` merges the PR with `gh pr merge <n> --squash --delete-branch`. Never `--admin` unless the human explicitly authorizes a break-glass override in chat.

The non-Dependabot `auto-merge-on-approval` workflow is opt-in only: it may call `gh pr merge` only when the repo has an `AUTHOR_MERGE_TOKEN` Actions secret and that token resolves to `author_identity` (normally `nathanjohnpayne`). If the secret is absent, the workflow stops after validation and leaves manual author merge as the default. Reviewer tokens such as `REVIEWER_ASSIGNMENT_TOKEN` must not be used for PR merges.

Arming is not one-shot on the approval event. The job arms on three triggers: the original `pull_request_review` + `approved` event; a `pull_request` `synchronize` / `reopened` **re-arm** path (#495); and a `pull_request` `unlabeled` **settle re-arm** path (#620), which fires when a removed label is one of the four blocking names (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`) — the state-settled signal for the label race where a synchronize-time arming run hard-fails on a transient label that auto-clear removes moments later. Triage deliberately does not run on `unlabeled` (it would re-apply the label just removed), so the arming job accepts a skipped triage result on that path only; and because the `needs-external-review` removal IS the trigger there, the CodeRabbit rate-limit branch derives external-review protection by asking `scripts/merge-clearance-gate.sh --derive-rate-limit-protection` — the same intrinsic threshold/protected-paths computation the required check runs, with the label as a force-on signal and the propagation lane's verified-head marker as the exemption, evaluated on the live head, plus a current-head `codex-review-check.sh` clearance check when the active merge-clearance external gate is disabled (#713). It never derives protection from label events, which are not head-pinned proof of a downstream gate or clearance. Downgraded runs re-run that derivation just before merge and abort on head drift, so state that changes during the waits (a push, a lane verification landing) cannot ride an earlier disposition. Label removals fire this trigger only when performed with a PAT — GITHUB_TOKEN-driven events create no workflow runs (#315/#324) — so `auto-clear-blocking-labels.yml` and `pr-review-policy.yml`'s propagation lane both remove blocking labels under a PAT. The synchronize/reopened path retries `gh pr merge --auto` after a fix-commit — the common case where a late Codex finding lands at or after the author's approval and the fix push would otherwise never re-arm. Every re-arm path acts only when the PR already carries a valid non-author latest-state `APPROVED` review (the same latest-state-per-reviewer collapse the merge gate uses, so a withdrawn approval does not re-arm). A push with no existing approval does NOT arm. Every gate (CodeRabbit wait, `AUTHOR_MERGE_TOKEN` identity, blocking-label re-verify) re-applies on the new HEAD, and the call is idempotent when `--auto` is already enabled.

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

19b. The agent runs the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate). If any unresolved thread remains, stop before merge and address or resolve it through the allowed path.

20b. `nathanjohnpayne` merges the PR. Done.

**Auto-clear of `needs-external-review` on Phase 4b clearance.** The `auto-clear-blocking-labels.yml` workflow's gate-evaluation script (`scripts/codex-review-check.sh`) accepts a Phase 4b external reviewer's `APPROVED` on the current HEAD as gate (c) clearance equivalent to Codex (governed by `codex.allow_phase_4b_substitute` in `.github/review-policy.yml`, default `true`; #218). When `codex.enabled: false`, this Phase 4b substitute is the only gate-(c) clearance path; stray Codex bot reviews/reactions are ignored even if the GitHub App is still installed. The auto-clear workflow then removes `needs-external-review` on the next event-driven trigger or scheduled sweep — no human-driven label removal is needed on the Phase 4b happy path. Set the knob to `false` for repos that genuinely require Codex-only clearance (e.g., where the Codex App provides domain-specific checks no other reviewer matches).

**Automated Phase 4b (reference implementation).** `scripts/phase-4b-review.sh` can drive the cross-agent Phase 4b review by shelling out to a reviewer CLI (Codex or Claude) under the operator's **subscription plan** (never a pay-per-token API key), then posting the resulting `APPROVED` / `CHANGES_REQUESTED` verdict under the reviewer PAT — the same Phase 4b substitute clearance described above. Mergepath itself runs it **enabled** (`phase_4b_automation.enabled: true`, 2026-07-02; `high` effort on both adapters since #669 — measured default, with xhigh as the documented per-run, per-adapter env escalation); the template mirror resets the switch to `false` so a new repo opts in explicitly. **Invocation (enabled repos):** after Phase 4a clearance requires a 4b leg, the authoring agent runs `scripts/phase-4b-review.sh <PR#> --repo <owner/repo>` itself instead of posting the manual handoff — executing the orchestrator, adapters, and `gh-as-reviewer.sh` **from a trusted main-ref checkout, never from the PR-under-review's own checkout** (the PR is passed by number/head and its diff reviewed as data, so a PR that edits the phase-4b scripts cannot shape its own verdict — Codex P1 on #628). Exit 1 means a CHANGES_REQUESTED review posted — a completed round: fix, push, rerun. Exits 2/3/4/5 (config or infra error, fail-closed fallback, disabled) fall back to the manual handoff below. Knobs live in the `phase_4b_automation` block of `.github/review-policy.yml`:

- **Per-adapter timeout + effort (#589):** `adapter_timeout_seconds` (shared, integer in `[1, 3600]`, default `900`) with optional `codex_timeout_seconds` / `claude_timeout_seconds` overrides; `claude_effort` (`low|medium|high|xhigh|max`, default `medium`) and `codex_effort` (`minimal|low|medium|high|xhigh`, default the Codex CLI default). Codex and Claude can therefore be tuned without editing the adapter scripts. A missing, non-integer, or out-of-range value is rejected **fail-closed** (the orchestrator exits non-zero rather than running the CLI unbounded or with an invalid effort).
- **Enablement evidence (#586):** before flipping `enabled: true`, run `scripts/phase-4b/collect-enablement-evidence.sh` in the environment that will post reviews to record `codex --version` / `claude --version`, per-adapter plan-auth status, a scan proving no disallowed API-key env vars are set, and an optional live dry-run. It exits non-zero when BLOCKED.
- **Approval-loop accounting (#602):** with `phase_4b_automation.accounting.enabled` (default `true` under the disabled parent), every automated `APPROVED` review body carries a "## Phase 4b Approval Accounting" block plus an embedded machine-readable `p4b-accounting:v1` record. How to read it: the **loop table** lists every adapter attempt (not just the posted one) with per-loop severity counts — a fail-closed row there is *positive* safety evidence (an unsafe approval that was refused), not a defect; the **rigor table** is proof-of-work for zero-finding approvals — a row is ✅ only when the backing signal was actually captured, and `n/a — reason` otherwise, so a wall of green cannot be faked; the **cost section** separates the billed cost (always `$0.00` — reviewer CLIs run on the operator's subscription plan) from the clearly labeled **notional** metered-API equivalent (priced from the versioned `scripts/phase-4b/prices.json`, `price_table_version` stamped; `n/a` when no price is configured), alongside wall-clock, CLI-exposed token counts (`unavailable` means the CLI exposed nothing — counts are never estimated), throttle events, and the human-shuttle-avoided range (~30 min–3 h, § Phase 4b Triggers); the **running totals** footer names its source (`github-derived` / `ledger-cache`) or states `unavailable` with the reason — it never guesses. Accounting is advisory to safety: a report-generation failure means the plain-summary approval posts instead; it can never block or fabricate an approval, and a posted `APPROVED` can never carry a required-tier finding (asserted fail-closed at build and render).

Full detail (child-env credential isolation, verdict schema, dry-run, accounting) lives in [`scripts/phase-4b/README.md`](scripts/phase-4b/README.md).

### Phase 4b Triggers

Phase 4b is documented above as a fallback (4a unavailable / escalates / times out). Per empirical evidence from matchline (#158: 9 PRs of the same author through both 4a and 4b — 4b caught 6+ real bugs on state-machine + concurrency + transactional changes that 4a cleared past), Phase 4b ALSO has high catch-rate value as a **first-class proactive gate** on a specific class of PR — not just as a fallback.

The `phase_4b_default` field in `.github/review-policy.yml` controls when 4b fires proactively:

| Value | Behavior (intended; full wiring lands in #186 + #187) |
|-------|---------|
| `fallback-only` | Current behavior. 4b only on 4a unavailability/escalation/timeout. |
| `complex-changes` | Run `scripts/phase-4b-classifier.sh` AFTER 4a clears; if any trigger matches, post the 4b handoff before merging. |
| `always` | Skip the classifier; post the 4b handoff for every external-review-threshold PR. |

**Operating instructions:** the runtime branching that consumes `phase_4b_default` is documented in [CLAUDE.md step 8.5](CLAUDE.md) (and summarized in AGENTS.md § Workflow Summary). Agents read the field via `scripts/codex-review-check.sh` (which parses and exports `PHASE_4B_DEFAULT`), then on `complex-changes` run `scripts/phase-4b-classifier.sh <PR#>` between Phase 4a clearance and merge. The classifier's exit code is load-bearing: 0 (no 4b → merge), 1 (invoke 4b → post handoff per § Handoff Message Format), 2 (config/API error → stop), 3 (bad args → fix invocation).

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
  │  Advisory via CI; conversations still clear later        │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  PHASE 3: THRESHOLD CHECK                                │
  │  Lines changed ≥ threshold OR protected paths touched?   │
  │                                                          │
  │  NO ──→ Pre-merge review conversation gate               │
  │          then nathanjohnpayne merges. Done.              │
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
  │  PRE-MERGE CONVERSATION  │  │  GitHub Issues             │
  │  GATE: zero unresolved   │  │                            │
  │  review conversations    │  │  Pre-merge conversation    │
  │                          │  │  gate: zero unresolved     │
  │  Addressed bot threads   │  │  review conversations.     │
  │  may be resolved; human  │  │                            │
  │  threads stop the merge. │  │  nathanjohnpayne merges.   │
  └──────────┬───────────────┘  │  Done.                     │
             │                  │                            │
             ▼                  │                            │
  ┌──────────────────────────┐  │                            │
  │  nathanjohnpayne merges  │  │                            │
  │  (--squash). Done.       │  │                            │
  └──────────────────────────┘  │                            │
                                └────────────────────────────┘
```

## Feedback Disposition Policy

The `feedback_policy` block in `.github/review-policy.yml` controls **which bot-review findings the authoring agent must disposition before merge**. A *disposition* is one of: **fix** the code, **or** post a **rebuttal** reply explaining why the finding does not apply — and then **resolve the thread**. It governs disposition *requirements* only; it does not change who reviews or the external-review threshold.

### Normalized severity ladder

Both reviewers are mapped onto one ladder so a single policy covers them:

| Tier | Meaning | Codex (exact) | CodeRabbit (heuristic) |
|------|---------|---------------|------------------------|
| `p0` | critical / blocker | `![P0 Badge]` / `**P0` | — (Codex-only; CodeRabbit tops at p1) |
| `p1` | high / blocking | `![P1 Badge]` / `**P1` | `⚠️ Potential issue` / `🟠 Major` |
| `p2` | minor | `![P2 Badge]` / `**P2` | `🟡 Minor` |
| `p3` | cosmetic / trivial | `![P3 Badge]` / `**P3` | `🔵 Trivial` |
| `nitpick` | style / nit | — (Codex P3 maps to `p3`) | `🧹 Nitpick` |

The CodeRabbit column mirrors `classify_severity` (`scripts/lib/daily-feedback-rollup-helpers.sh`), the repo's canonical badge parser: CodeRabbit findings are keyed off the severity badge, top out at `p1` (Major / Potential issue / ⚠️), and never map to `p0` — `p0` is Codex-only. A Refactor suggestion or a stray "security" mention carries no severity badge, so it is unclassified (discretionary).

Codex emits an explicit machine-readable badge per finding; CodeRabbit has no numeric scale, so its tier is derived heuristically (category + a `Critical`/`Major`/`Minor` qualifier) by `coderabbit_tier_of` in `scripts/lib/feedback-policy-helpers.sh`.

### Schema

```yaml
feedback_policy:
  mode: by-priority        # by-priority | address-all
  priorities:              # consulted only when mode: by-priority
    p0: required           # required | discretionary | ignore
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
```

- **`mode: by-priority`** (default) — each tier is independently `required` (must fix-or-rebut + resolve; merge-blocking), `discretionary` (agent's judgment; never blocks), or `ignore` (never surfaced).
- **`mode: address-all`** — every finding at every tier is `required`; the `priorities:` map is ignored. This is "address or rebut all feedback."

### Defaults & backward compatibility

An **absent** `feedback_policy` block reproduces today's behavior exactly: disposition defaults of **P0/P1 required, P2/P3 discretionary**, and the merge gates enforce **P1 only**. The default lives in the parser (`resolve_required_tiers`), not just in this file, because `.github/review-policy.yml` is not synced to consumers — the same default-on-absent posture as `phase_4b_default` and `propagation_prs`.

### Enforcement (two symmetric gates)

The blocking tier set resolved from this block is enforced by two required-check gates that share `scripts/lib/feedback-policy-helpers.sh`, so the two reviewers' blocking sets cannot drift apart:

- **Codex** — `scripts/codex-p1-gate.sh` (required check `Codex P1 Gate / Codex P1 unresolved threads`), gated by `codex.p1_gate.enabled`. It classifies each Codex inline finding with `codex_tier_of` and blocks merge on any unresolved thread whose tier is in the resolved `required` set. The required-check **name is unchanged** (branch protection depends on it) even though the gate now spans the full tier set rather than only P1.
- **CodeRabbit** — `scripts/coderabbit-severity-gate.sh` (required check `CodeRabbit Severity Gate / CodeRabbit unresolved blocking findings`), gated by `coderabbit.severity_gate.enabled`. It classifies each CodeRabbit inline finding with `coderabbit_tier_of` and blocks on the same `required`-tier set. Shipped in #577 (merged in #590), but the knob defaults `false` everywhere — a clean no-op until a repo opts in, so it is safe to add to required checks ahead of enabling.

Both gates clear a finding the same way: **resolve the thread** (the GitHub UI "Resolve conversation" button or the `resolveReviewThread` mutation) once it is fixed or rebutted. An absent `feedback_policy` block resolves to `{p1}`, so the Codex gate stays byte-identical to its pre-#574 P1-only behavior.

The same tier resolution also drives the **agent-facing surfacing** (advisory, never merge-blocking): `scripts/codex-review-request.sh` tags each emitted finding with `blocking: true|false`, and `scripts/coderabbit-wait.sh` reports a `blocking_tier_unresolved` count in its JSON when the block is present.

> **Rollout note (#574).** Sub-issue #576 shipped the schema above and the shared parser/classifier library. Sub-issue #577 makes the gates **act**: `codex-p1-gate.sh` is generalized beyond P1 and `coderabbit-severity-gate.sh` is added, both honoring the resolved `required` tiers, plus the agent-facing `blocking` surfacing above. `feedback_policy` is therefore now enforced, not just documentary (an absent block still reproduces the prior Codex-P1-only behavior exactly).

> **CodeRabbit profile dependency.** `nitpick: required` only has teeth when `.coderabbit.yml` uses `reviews.profile: assertive`; the shipped `chill` profile suppresses the 🧹 Nitpick category entirely, so the requirement is a no-op there. `coderabbit-severity-gate.sh` emits a non-fatal warning when it sees `nitpick: required` under a chill profile. See [`docs/agents/coderabbit-audit.md`](docs/agents/coderabbit-audit.md).

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

### Chat-side handoff block

The PR-side comment above is the durable record on the PR itself. The **chat-side handoff block** is an additive, copy-paste-friendly summary the originating agent emits **into chat** at the same moment it alerts the human — it does NOT replace the PR-side comment. The human pastes the chat-side block directly into the external reviewer's CLI session (typically `nathanpayne-codex`) to brief that session in one keystroke; the external agent then opens the PR for the full context surfaced by the PR-side comment.

Use the **single-PR variant** when the agent is handing off exactly one PR. Use the **batch variant** when alerting the human about two or more Phase 4b-eligible PRs at once (e.g., a propagation wave where several consumer mirror PRs each need an external `APPROVED` review).

**Single-PR variant** — emit verbatim into chat (substitute the angle-bracket placeholders):

```
PR ready for external review (Phase 4b):

  <PR URL>  head <short_sha>  (base <base_short_sha>)

Context: <one line — content classification (novel work, verbatim
         mirror of mergepath@<sha>, sync + N convergence commits, ...)>
Gate: post APPROVED as nathanpayne-codex on the listed HEAD, OR a
      Codex bot review / 👍 reaction newer than the HEAD committer date.
Threads: <N> unresolved (resolve addressed bot or agent-reviewer threads
         per the pre-merge gate; never resolve real-human threads
         automatically).
```

**Batch variant** (>1 PR) — emit a markdown table with one row per PR, followed by a single fenced prompt the human can paste into the external reviewer's CLI session:

| Repo | PR # | HEAD short SHA | Unresolved threads | Content note |
|------|------|---------------|-------------------|--------------|
| `nathanjohnpayne/<repo-a>` | [#<num>](https://github.com/nathanjohnpayne/<repo-a>/pull/<num>) | `<short_sha>` | <N> | <content classification> |
| `nathanjohnpayne/<repo-b>` | [#<num>](https://github.com/nathanjohnpayne/<repo-b>/pull/<num>) | `<short_sha>` | <N> | <content classification> |

```
PRs ready for external review (Phase 4b):

  <PR URL #1>  head <short_sha>  (base <base_short_sha>)
  <PR URL #2>  head <short_sha>  (base <base_short_sha>)
  ...

Context: <one line — shared content classification if all PRs share
         one, e.g. "all verbatim mirrors of mergepath@<sha>"; otherwise
         "mixed — see table above">
Gate: for each PR, post APPROVED as nathanpayne-codex on the listed
      HEAD, OR a Codex bot review / 👍 reaction newer than the HEAD
      committer date.
Threads: see "Unresolved threads" column (resolve addressed bot or
         agent-reviewer threads per the pre-merge gate; never resolve
         real-human threads automatically).
```

The chat-side block is **additive** to the existing PR-side comment template above. Agents emit both: the PR-side comment is the durable record on the PR; the chat-side block is the human-facing summary that flows into the external CLI session. Neither replaces the other.

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

Agents must never modify the `needs-external-review`, `needs-human-review`, or `policy-violation` labels on any PR — these are human-action labels. Agents may add `human-hold` to freeze a PR, but must never remove it; `human-hold` is a human-remove-only hard hold that supersedes every merge gate, including Codex clearance, reviewer approvals, Dependabot auto-merge, and break-glass agent merge variables. The `scripts/hooks/label-removal-guard.sh` PreToolUse hook enforces this at the mechanism layer; chat authorization does not bypass it. To request a label removal, run `scripts/request-label-removal.sh <PR#> <label>` — this posts a structured ask on the PR and (if `MERGEPATH_NOTIFY_IMESSAGE_TO` is set) pings the human via iMessage. The human clears the label from any device; the PR can proceed once the normal merge gates are green.

**Sanctioned automation exceptions.** Two — and only two — automated paths may remove `needs-external-review`. Both are GitHub Actions workflows (not interactive agent sessions); both are reconciling a label the policy automation itself is responsible for, which is categorically different from an agent clearing a human-action label.

1. **`auto-clear-blocking-labels.yml`** (shipped in [#195](https://github.com/nathanjohnpayne/mergepath/issues/195) per parent [#191](https://github.com/nathanjohnpayne/mergepath/issues/191)) removes the label once the merge gate clears. It re-runs `scripts/codex-review-check.sh` on `pull_request_target` / `pull_request_review` / `workflow_run` events AND on a 5-minute `schedule` cron sweep (#197/#324 — catches the 👍-after-last-push case where no event-driven trigger fires), and removes the label when the merge gate passes per the full gate logic in [`scripts/codex-review-check.sh`](scripts/codex-review-check.sh) — gate (a) CI green AND gate (b) reviewer-identity APPROVED OR same-agent + Codex 👍 (per [#170](https://github.com/nathanjohnpayne/mergepath/issues/170)) AND gate (c) Codex cleared on current HEAD. The byline on the removal is `github-actions[bot]` (not an agent identity); the workflow's `if:` guards prevent self-fire loops AND skip the event-driven job on schedule events (cron only runs the sweep); checkout pins to the default branch so a malicious PR cannot supply its own gate-script. If an immediate post-removal verification read fails, the workflow re-reads the label state before surfacing a synthetic failure check-run; when that final read proves the label is already absent, it posts a matching success check-run instead of leaving a stale failure on the PR.

2. **`pr-review-policy.yml`'s External Review Check** (the propagation-PR review lane, [#264](https://github.com/nathanjohnpayne/mergepath/issues/264) / [#268](https://github.com/nathanjohnpayne/mergepath/issues/268)) removes the label when a PR is verified to be a faithful propagation mirror — see [§ Phase 3.5](#phase-35-propagation-pr-review-lane). It does not consult the merge gate; it acts on the orthogonal fact that the PR's content was already reviewed upstream, established by `scripts/workflow/verify-propagation-pr.sh`'s byte-comparison against `mergepath@<sha>`. Same `github-actions[bot]` byline; same not-an-agent-override rationale.

These exceptions apply ONLY to those two workflows. An interactive agent session (claude / cursor / codex) calling `gh pr edit --remove-label` for any of the four protected labels remains forbidden — the `scripts/hooks/label-removal-guard.sh` PreToolUse hook enforces this independently. The hook intentionally only fires for `Bash` tool calls from agent sessions; a workflow's `gh` call inside a GitHub Actions runner does not pass through that surface, so the hook does not (and should not) block CI workflows. `needs-human-review`, `policy-violation`, and `human-hold` remain manual-only by design.

**Automated merge identity.** Non-Dependabot automatic PR merge is not a sanctioned reviewer-identity exception. If enabled, it must use an author-owned `AUTHOR_MERGE_TOKEN` Actions secret and verify the token resolves to `author_identity` immediately before the merge path. Repos without that secret keep the normal manual merge flow under `scripts/gh-as-author.sh`.

**Disabling the scheduled sweep.** The 5-minute cron is opt-out via `auto_clear_labels.scheduled_sweep_enabled: false` in `.github/review-policy.yml`. Default is `true`. Set to `false` if your repo has high PR volume and the event-driven path is reliably fast enough that the cron becomes pure noise — but expect occasional stuck `needs-external-review` labels on the 👍-after-last-push case (which the sweep would otherwise catch). The event-driven path remains active regardless of this setting.

## Implementation notes for branch protection gates

### Required status checks (per-repo setup)

The workflows shipped under `.github/workflows/` ENFORCE merge gating only when configured as **required status checks** in branch protection. Without that bit, a failed check is advisory and the PR merges anyway. The 2026-04-27 weekly audit caught `matchline#76` and `matchline#93` merging past `needs-human-review` for exactly this reason — `Label Gate` was running and failing, but wasn't in the required-checks list.

Each repo using this template must mark these as required on `main` (Settings → Branches → Branch protection rule):

- **`Label Gate`** — fails when any of `needs-external-review`, `needs-human-review`, `policy-violation`, or `human-hold` is on the PR. The hard gate behind the doctrine in [Agent prohibitions](#agent-prohibitions). Those four are its **complete** blocking set. The `decision-needed` label is deliberately **not** in it: `decision-needed` is an issue-triage marker (an issue awaiting a human decision before work proceeds), not a PR merge-stop, so applying it to a PR does **not** block merge. To freeze a PR pending a human decision, use `human-hold` (or `needs-human-review` for an agent-disagreement hold). This resolves the contradiction in #496, where `decision-needed`'s label description implied a merge block the gate never enforced.
- **`Self-Review Required`** — fails when the PR body lacks a `## Self-Review` section (Dependabot-exempt).
- **`Codex P1 unresolved threads`** — fails when any Codex inline-finding thread on the current HEAD whose tier is in the resolved `feedback_policy` `required` set is unresolved (`codex.p1_gate.enabled`, #235; generalized beyond P1 in #577 — the check **name is unchanged** for branch-protection stability). A no-op (always green) when the knob is off, so it is safe to require everywhere.
- **`CodeRabbit unresolved blocking findings`** — the CodeRabbit twin of the Codex gate: fails when any CodeRabbit inline-finding thread on the current HEAD whose mapped tier is in the resolved `required` set is unresolved (`coderabbit.severity_gate.enabled`, shipped in #574/#577, merged in #590). A no-op (always green) when the knob is off — default `false` everywhere — so it is safe to require everywhere ahead of enabling it per repo.
- **`Merge clearance gate`** — the HEAD-pinned, merge-time enforcement of clearance (#427/#428). Fails when a Dependabot PR has no reviewer-identity `APPROVED` review on the current HEAD (`dependabot.reviewer_gate.enabled`), or when a `needs-external-review` PR is not cleared on the current HEAD by `scripts/codex-review-check.sh` (`codex.external_review_gate.enabled`). It re-evaluates on every push (and via a scheduled sweep for no-event transitions), so a clearance recorded on an earlier HEAD — or an approval dismissed by a rebase push — cannot ride a new HEAD to merge. This closes the two escapes that previously surfaced only in the weekly retroactive audit: a Dependabot dev-deps bump merged with no approval on HEAD (matchline#245), and an external-review PR merged on a HEAD with no `APPROVED` CLI review and no Codex review (nathanpaynedotcom#405). A no-op (always green) when both knobs are off. **Caveat:** a required check is bypassable by an admin "merge without waiting for requirements"; both escapes were admin merges, so pair this with branch-protection `enforce_admins: true` to fully close the human-merge path.

Audit a repo's branch protection with `scripts/audit-branch-protection.sh` (read-only; exits 3 if any canonical check is not required, with a fix recipe). Re-run after every protection change.

The audit reads `GET /repos/{owner}/{repo}/branches/{branch}/protection` and falls back to the rulesets endpoint when classic protection isn't configured. Both endpoints require the `Administration:read` scope. Reviewer PATs commonly lack this scope — the audit will exit 2 with an auth diagnostic in that case rather than emitting a false "PR merges are completely unprotected" verdict (#177, #285). To run a full audit, use an author/admin PAT (e.g. `GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"`).

### `resolveReviewThread`

The GitHub GraphQL `resolveReviewThread` mutation may be used by agents **only** when both:

- The agent has demonstrably addressed the inline finding (a fix is on the current HEAD, or a rebuttal is posted on the thread), AND
- The bot author has not auto-resolved within a reasonable window, OR the registered agent-reviewer author has accepted the fix, approved the current HEAD, or posted an on-thread acknowledgment.

It is the clean-up mechanism used by the [Pre-Merge Review Conversation Gate](#pre-merge-review-conversation-gate) for the `required_conversation_resolution: true` branch-protection gate, NOT a policy override. It does not authorize removing blocking labels, bypassing required reviews, or merging past unaddressed findings. **If the thread author is a real human (not a bot and not a registered agent-reviewer identity), agents must not call this mutation regardless of state.**

Every `resolveReviewThread` call must be **confirmed by a follow-up readback**: re-read the thread (via `reviewThreads` or the top-level `nodes(ids:)` lookup) and verify it reports `isResolved: true`. A mutation that returns success but does not read back resolved (state drift, eventual-consistency lag, or a token that could write but a later read that cannot) must be treated as a failure — **never infer a thread is resolved from an unconfirmed write** (fail closed). `scripts/resolve-pr-threads.sh` does this automatically: after resolving, it reads back every thread it resolved and exits non-zero if any does not confirm `isResolved: true`.

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
  max_wait_seconds: 1245                   # grace window for scripts/coderabbit-wait.sh (measured full-fleet max + one poll interval, #623)
  post_clearance_max_wait_seconds: 240     # shortened ceiling for the #727 auto-merge post-clearance fast path (HEAD already has verified Codex/Phase-4b clearance + reviewer APPROVED); only ever shortens the wait
  status_probe_enabled: true               # ask CodeRabbit for narrative status before exit-4 timeout
  status_probe_wait_seconds: 60            # bounded extra wait for the status-probe reply
  max_rate_limit_retries: 2                # retries after CodeRabbit posts "Rate limit exceeded"
  max_resume_retries: 2                     # @coderabbitai resume retries on auto-pause (#490); exit 6/paused when exhausted
  wallclock_freshness_window_seconds: 1800 # HEAD_ANCHOR floor; closes cherry-pick false-clear

# Codex (Phase 4a automated external review) — see Phase 4a above.
# Same semantics note as coderabbit: this flag governs agent behavior,
# not app runtime. The ChatGPT Codex Connector App runs based on its
# per-repo install state and its "Automatic reviews" setting.
codex:
  enabled: true
  request_by_default: true                    # post `@codex review` on EVERY PR, not just above-threshold (#486)
  bot_login: "chatgpt-codex-connector[bot]"   # REST API form, with [bot] suffix
  cli_login: nathanpayne-codex                # manual CLI fallback (Phase 4b)
  max_review_rounds: 2                        # runaway guard; 3rd round escalates
  review_timeout_seconds: 840                 # per-round poll timeout (measured verdict p99/max, #623)
  require_ci_green: true                      # merge gate
  allow_phase_4b_substitute: true             # accept Phase 4b APPROVED on HEAD as gate (c) clearance (#218)
  p1_gate:
    enabled: true                             # required check `Codex P1 unresolved threads` (#235)
  external_review_gate:
    enabled: true                             # required check `Merge clearance gate`, external-review arm (#428)

# Dependabot HEAD-pinned reviewer-approval merge gate (#427).
# When reviewer_gate.enabled is true, the required check `Merge clearance
# gate` blocks a Dependabot PR unless a reviewer identity (≠ author) has a
# latest-state APPROVED review whose commit_id == the current HEAD.
# Default false everywhere except mergepath (narrow-start, then propagate).
dependabot:
  reviewer_gate:
    enabled: true
```

> **Note on `enabled` flags (both `coderabbit` and `codex`).** These flags govern **agent behavior only** — whether the authoring agent waits for the corresponding review in its phase. They do NOT control whether the underlying GitHub App runs. Both apps run based on their own install state on GitHub, independent of what this YAML says. Setting `coderabbit.enabled: false` alone will cause the agent to skip the CodeRabbit phase while the app continues to post reviews silently in the background. Setting `codex.enabled: false` routes the agent to Phase 4b and makes `scripts/codex-review-check.sh` ignore Codex bot reviews/reactions for the merge gate, but the Codex App may still post comments unless it is disabled in ChatGPT/GitHub. To fully disable an integration, uninstall or disable the GitHub App AND set the flag to false.

### `codex.request_by_default` — request Codex on every PR (#486)

`codex.request_by_default` (default `true`) decouples the `@codex review` trigger from the external-review threshold. It governs whether **the agent** posts `@codex review` on every PR: the agent is the caller that runs `scripts/codex-review-request.sh` from the workflow, and there is no separate workflow auto-caller that posts the trigger on its own.

- **`true`** — the agent runs `scripts/codex-review-request.sh` on **every** PR, independent of `external_review_threshold` / `external_review_paths`, so the `@codex review` trigger is posted on under-threshold PRs too. For an under-threshold PR the agent posts it during [Phase 3 step 9](#phase-3-external-review-threshold-check) **before merging**, and the trigger is **advisory** — it does not gate the merge (the threshold governs the merge gate; see [Threshold Evaluation](#threshold-evaluation) below). For an above-threshold PR the same trigger is the Phase 4a entry that *does* gate the merge. This is the full-automation default ([#483](https://github.com/nathanjohnpayne/mergepath/issues/483)).
- **`false`** — the pre-#486 behavior: the agent requests Codex only when the PR independently qualifies for Phase 4a (lines ≥ threshold **or** a protected-path match), i.e. only as the Phase 4a entry. Under-threshold PRs get no `@codex review`.

The key is **orthogonal to `codex.enabled`**: it governs only *when* the trigger is posted, never *whether* Codex participates. When `codex.enabled: false`, Phase 4a is off and no trigger is posted regardless of `request_by_default`.

`scripts/codex-review-request.sh` parses both keys (via the same `codex_field` helper as the rest of the `codex:` block) and applies them as a Phase 4a entry gate *before* any signal scan or trigger write. It does not recompute the threshold itself — the caller (the agent) tells the worker whether the PR independently qualifies for the gating Phase 4a path by exporting `MERGEPATH_PHASE_4A_GATED=true` (consulted only when `request_by_default` is `false`); the under-threshold Phase 3 step 9 call omits it. When the gate decides to skip, the script emits JSON with `trigger_requested: false` and exits `5` (`NO_TRIGGER_REQUESTED`) — distinct from a timeout (`4`) or an API error (`3`).

### Threshold Evaluation

A PR requires external review if **either** condition is true:

1. Total non-generated lines changed (additions + deletions) ≥ `external_review_threshold`. Lockfiles (`*.lock`, `*lock.json`), minified files (`*.min.js`, `*.min.css`), and generated files (`*.generated.*`) are excluded from the count.
2. Any file in the PR diff matches a pattern in `external_review_paths`

The agent evaluates this after internal review passes, before merging. CI workflows may also evaluate and label earlier as an advisory (see Phase 3 note above). Independently of this threshold, when `codex.request_by_default: true` (the default) the agent posts `@codex review` on every PR — for an under-threshold PR it does so in [Phase 3 step 9](#phase-3-external-review-threshold-check) before merging, via `scripts/codex-review-request.sh`; see [`codex.request_by_default`](#codexrequest_by_default--request-codex-on-every-pr-486) above. The threshold still governs the **merge gate** (whether external clearance is *required* to merge): on an under-threshold PR the Codex trigger is **advisory** and never blocks the merge, while on an above-threshold PR the same trigger is the gating Phase 4a entry. `request_by_default` governs only whether the Codex trigger is *posted*, not whether clearance is required.

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

The canonical convention is documented in [Reviewer PAT Quick Start](#reviewer-pat-quick-start). Short form:

- **Read paths** (`gh api user`, GETs, `gh pr view`, `gh pr checks`) use an explicit `GH_TOKEN` for the command.
- **Core guarded writes** (`gh pr create`, `gh pr merge`, `gh pr edit`, `gh pr comment`, `gh pr review`, `gh issue comment`) use the author/reviewer wrappers. The wrappers select and verify the effective token immediately before the write and do not mutate the gh keyring.

```bash
# ── Read-path: explicit GH_TOKEN ──

# Verify which identity a PAT resolves to (read path):
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq '.login'
# expected: nathanpayne-claude

# Read-only helper:
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-check.sh <PR#>

# coderabbit-wait.sh may POST a retry nudge; it uses the cached PATs
# loaded by preflight.
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/coderabbit-wait.sh <PR#>

# codex-review-request.sh uses the reviewer PAT for reads, then posts
# the '@codex review' trigger through gh-as-author.sh so the trigger is
# authored by nathanjohnpayne (#405).
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-request.sh <PR#>

# ── Write-path: wrapper verifies the token, then sets GH_TOKEN ──

GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> \
  scripts/gh-as-reviewer.sh -- gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch
scripts/gh-as-author.sh -- gh pr create --title "..." --body "..."
```

- Use the item ID from the [PAT lookup table](#pat-lookup-table) for your agent identity. Do not use the 1Password item title.
- Verify token identity with `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login` or by letting the wrapper call `identity-check.sh --expect-token-identity` before the write. Do not use `gh auth status` as an attribution proof.
- If `op whoami` says you are not signed in, still run the `op read ...` command in an interactive TTY. That is what triggers the 1Password biometric prompt on local machines.
- If GitHub returns `Review Can not approve your own pull request`, you either the PR author is wrong, the reviewer token resolved to the author identity, or the [No-self-approve scoping](#no-self-approve-scoping) rule applies. Confirm the PR author and token identity before retrying.

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

The SSH-remote-switch covers every repo on the operator's machine (template
+ consumers + docs). Current set:

<!-- bootstrap-loop-list-start -->
- mergepath
- swipewatch
- nathanpaynedotcom
- device-platform-reporting
- device-source-of-truth
- overridebroadway
- friends-and-family-billing
- docs
<!-- bootstrap-loop-list-end -->

```bash
# Explicit path to mergepath/REVIEW_POLICY.md — pwd may not be the
# mergepath repo when the operator runs this (see #252 Codex P1).
for repo in $(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
              ~/Documents/GitHub/mergepath/REVIEW_POLICY.md | grep '^- ' | sed 's/^- //'); do
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

## Recovery: PR created under the wrong identity

If `gh pr create` lands a PR under the wrong account, the PR is unrecoverable in place: any review attempt under the same account that authored the PR returns `Can not approve your own pull request`, and the `Authoring-Agent:` fingerprint in the body now disagrees with `author.login`, breaking downstream audit. See #241 for the historical keyring-switch bug and `nathanjohnpayne/friends-and-family-billing#262` for the canonical incident. Under the current wrapper contract, the equivalent failure is a wrong effective token.

### Prevention (the primary path)

Always wrap author-identity writes in `scripts/gh-as-author.sh`:

```bash
scripts/gh-as-author.sh -- gh pr create --title "..." --body "..."
```

The wrapper resolves a token for `nathanjohnpayne`, verifies that token with `scripts/identity-check.sh --expect-token-identity`, runs the wrapped command with process-local `GH_TOKEN`, and never changes the gh keyring. For `gh pr create` specifically, it also runs a post-create `gh pr view --json author` verification using the same token and exits non-zero (code 5) if `author.login` does not match the expected identity. The `gh-pr-guard.sh` PreToolUse hook independently blocks bare `gh pr create` and inline-token substitutes before they can run.

### Detection

If you suspect the wrong-identity failure (e.g., the PR was just created and review attempts return `Can not approve your own pull request`), confirm with:

```bash
gh pr view <PR#> --repo <owner>/<repo> --json author --jq .author.login
```

Expected: `nathanjohnpayne`. If the output is your agent identity (e.g. `nathanpayne-claude`) or another reviewer identity, close and recreate the PR from the same branch.

### Recovery procedure

Close the wrong PR and recreate from the same branch. The commits and the branch survive the close — what's lost is the PR's review thread history, prior CI results, and any `chatgpt-codex-connector[bot]` / CodeRabbit comments. There is no in-place fix: GitHub does not expose an API to change `author.login` on an existing PR.

```bash
# 1. Close the wrong-author PR with a comment explaining the recreate.
gh pr close <PR#> --repo <owner>/<repo> \
  --comment "Wrong author identity (see #241). Recreating from the same branch."

# 2. Recreate from a fresh shell and route through gh-as-author.sh so the
#    new PR uses a verified author token.
scripts/gh-as-author.sh -- gh pr create \
  --repo <owner>/<repo> \
  --base main --head <same-branch> \
  --title "..." \
  --body "..."

# 3. Verify the new PR landed under the right identity (the wrapper also
#    does this automatically):
gh pr view <NEW_PR#> --repo <owner>/<repo> --json author --jq .author.login
# expected: nathanjohnpayne
```

The fresh shell in step 2 is belt-and-suspenders: any `GH_TOKEN` / `GH_HOST` / `GITHUB_TOKEN` env vars exported earlier in the session are gone, and the wrapper selects the author token again before the create.

### What's lost vs. what survives

| Item | After recreate |
|------|----------------|
| Commits on the branch | survive (`git push` is unaffected) |
| Branch ref | survives |
| PR review threads | LOST (closed-PR threads do not carry over) |
| CodeRabbit comments | LOST (will re-run on the new PR if enabled) |
| Codex Connector review | LOST (will re-trigger on the new PR if review-ready) |
| CI run history | LOST (jobs re-run on the new PR) |
| PR number | new one assigned |
| Authoring-Agent fingerprint | regenerated (now matches `author.login`) |

Filing a post-merge issue noting the recreated-PR situation is optional but helpful for audit trails — link both the closed PR and the new one so a later reader can follow the thread.

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
8. The `.coderabbit.yml` file at the repo root ships with the template and works out of the box. The template defaults to `reviews.profile: chill` — per CodeRabbit's docs, the 🧹 Nitpick category is "only in Assertive mode," so `chill` keeps substantive findings while suppressing per-thread nit ceremony (see #237 for the 2026-05-13 sweep data that motivated this default). Override per-repo by setting `reviews.profile: assertive` locally if you want the polish pass on that repo specifically. Customize `reviews.path_instructions` to add repo-specific review guidance (e.g., flag currency rounding in billing code, verify type compatibility in shared packages).

### CodeRabbit Removal

To reverse the CodeRabbit integration (e.g., if the trial ends):

1. Uninstall the CodeRabbit GitHub App from the `nathanjohnpayne` GitHub account.
2. In each repo where CodeRabbit was enabled: set `coderabbit.enabled: false` in `.github/review-policy.yml` and delete `.coderabbit.yml`.
3. No documentation changes are needed — all agent instructions use conditional language (`"if coderabbit.enabled: true"`) and will skip Phase 2.5 automatically.
4. Optionally remove `.coderabbit.yml` from the template if CodeRabbit will not be used for future repos.
