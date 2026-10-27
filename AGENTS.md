# AGENTS.md

Agent instructions are organized into focused sub-files under `docs/agents/`. Read the relevant file(s) before taking action in this repository.

## Sections

1. **[Repository Overview](docs/agents/repository-overview.md)** --- Project description, tech stack, agent role
2. **[Shared Agent Operating Rules](docs/agents/shared-operating-rules.md)** --- The fleet-wide operating rules, identical in every repo (synced canonical core). Read before the local operating rules below
3. **[Agent Operating Rules](docs/agents/operating-rules.md)** --- This repo's local overlay: reading order, conflict resolution, and anything true only here
4. **[Code Modification Rules](docs/agents/code-modification-rules.md)** --- File creation, duplication, directory constraints
5. **[Documentation Rules](docs/agents/documentation-rules.md)** --- When and what to update; which `docs/**` paths are directly editable vs generated mirrors
6. **[Testing Requirements](docs/agents/testing-requirements.md)** --- Coverage expectations, test deletion policy, repo-lint fast/deep execution modes
7. **[Deployment Process](docs/agents/deployment-process.md)** --- Build/deploy flow, 1Password-backed auth
8. **[Worktree Placement](docs/agents/worktree-placement.md)** --- Where agent-created worktrees/checkouts live on disk (synced canonical convention)
9. **[Decision Records](docs/agents/decision-records.md)** --- Recording the path taken when a PR reverses direction, and surfacing a comment-recorded decision from the issue body (synced canonical convention)
10. **[Prose Line-Wrapping](docs/agents/prose-line-wrapping.md)** --- Soft-wrap Markdown prose, one physical line per paragraph (synced canonical convention); this repo's in-scope path allowlist and gate live in Documentation Rules above
11. **[Code Review Requirements](docs/agents/code-review-requirements.md)** --- Thin pointer: all review behavior is governed by REVIEW_POLICY.md and `.github/review-policy.yml` (synced canonical pointer)
12. **[Cloud Agent Environments](docs/agents/cloud-environments.md)** --- Setting up Claude Code cloud and Codex cloud sessions to write under the right identities, what they still cannot do, and the capability probe that tells a session which case it is in (synced canonical convention)
13. **[Cloudflare MCP Servers](docs/agents/cloudflare-mcp-servers.md)** --- Capability note: the five remote MCP servers the `cloudflare` plugin ships, their auth model, and the write-capability hazard
14. **[Operating Rules for `priority:high` Work](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/high-priority-scope-discipline.md)** --- How to decide what a `priority:high` PR should build when automated review keeps finding more (hub-only, so the link is absolute: `AGENTS.md` is mirrored to consumers and this document is not)
15. **[Runbook: Unblocking Downstream Trackers](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/tracker-unblock-runbook.md)** --- Sequencing a multi-ticket session that unblocks consumer trackers through Mergepath work: live scope refresh, ordering and concurrency, owner-decision proposals, the pre-merge checklist, security evidence, and the run ledger (hub-only, so the link is absolute)
16. **[Runbook: the `dependabot-reviewer` Environment](https://github.com/nathanjohnpayne/mergepath/blob/main/docs/agents/dependabot-reviewer-environment.md)** --- Owner-performed setup of the dedicated Dependabot approval PAT: its scopes and residual risk, the environment and secret in each repository, the read-only readback, and the pilot proof (hub-only, so the link is absolute)

Item 2 is the stable entrypoint for shared rules: it is one canonical file mirrored to every repo, so a new fleet-wide rule lands by editing it at the canonical source, not by editing every repo's index again.

## Repository Layout

Most top-level directories are described by the `docs/agents/` files above or are self-evident. One carries its justification out-of-line, per the [Code Modification Rules](docs/agents/code-modification-rules.md) requirement that new top-level directories document their justification here or in a `plans/` entry:

- **`.codex/`** --- Codex CLI per-repo configuration; currently just `hooks.json`, which wires the `PreToolUse` guards (`scripts/hooks/gh-pr-guard.sh`, `scripts/hooks/label-removal-guard.sh`) for Codex sessions, the way `.claude/settings.json` does for Claude Code. Tracked deliberately: left untracked it is invisible to CI and to propagation, absent on a fresh clone, and free to drift per machine — and it did drift, into a form that resolved the guard through a variable Codex does not set, so the guard failed open (see the `.gitignore` stanza that re-includes it, and the manifest entry that propagates it). Real Codex *state* lives in `~/.codex`, not here, so nothing machine-local is committed.
- **`packaging/`** --- placeholder package scaffolds that reserve the `mergepath` name on the npm and PyPI registries (name-squatting prevention). Rationale and publish steps live in [`packaging/README.md`](packaging/README.md); see issues [#92](https://github.com/nathanjohnpayne/mergepath/issues/92) (npm) and [#93](https://github.com/nathanjohnpayne/mergepath/issues/93) (PyPI). The directory is whitelisted in `.repo-template.yml`.

## Code Review Policy

This repository uses a multi-identity AI agent code review system. The full policy is in REVIEW_POLICY.md. The per-repo configuration is in .github/review-policy.yml.

### Identity Rules

- All agents author code as nathanjohnpayne. The committer on a merged commit may be GitHub's `GitHub <noreply@github.com>` / `web-flow` identity when GitHub creates it during squash merge, `update-branch`, or a web-UI merge; that server-side identity is not selectable by the agent and is not an agent identity.
- Each agent reviews code under its own reviewer identity (e.g., nathanpayne-claude, nathanpayne-cursor, nathanpayne-codex).
- An agent never reviews code under the same identity that authored it.
- Only nathanjohnpayne merges to the target branch.
- Agents may add `human-hold` to freeze a PR, but must never remove it. The label is human-remove-only and supersedes all merge paths.

To freshen a `BEHIND` PR under `required_status_checks.strict: true`, merge the base locally from the PR's worktree using the existing `nathanjohnpayne` identity and signing configuration:

```bash
git -C <pr-worktree> fetch origin
git -C <pr-worktree> merge --no-edit origin/main
git -C <pr-worktree> push origin HEAD
```

For routine freshening, do not use `gh pr update-branch` or `PUT .../pulls/<n>/update-branch`: those create a commit with GitHub's `web-flow` committer, inviting identity findings that cost a review round ([mergepath#1288](https://github.com/nathanjohnpayne/mergepath/issues/1288)). A local merge keeps both author and committer on `nathanjohnpayne` and signs the commit under the local signing configuration. When no local checkout is possible, `update-branch` remains allowed as an exception; the identity rules above still apply.

### Workflow Summary

Use [REVIEW_POLICY.md § Workflow](REVIEW_POLICY.md#workflow) for credential preflight, author/reviewer identities, review rounds and merge gates. The [agent operating rules](docs/agents/operating-rules.md) and [testing requirements](docs/agents/testing-requirements.md) cover local execution details.

1. Author as `nathanjohnpayne`, file the PR through `scripts/gh-as-author.sh`, and include the required `Authoring-Agent:` and `## Self-Review` body fields.
2. Review under a registered reviewer identity. Resolve eligible bot conversations and registered agent-reviewer conversations after that reviewer accepts the fix; stop for real-human conversations unless the human explicitly directs otherwise. Follow the policy's complete-history feedback accounting before merging.
3. Run `scripts/coderabbit-should-invoke.sh` to select Phase 2.5. When that phase observes a CodeRabbit rate-limit or included-quota refusal, request Codex immediately; do not wait out the provider window or post a CodeRabbit retry. See [Phase 2.5](REVIEW_POLICY.md#phase-25-automated-external-review-coderabbit).
4. A rate-limited under-threshold PR still needs exact-head Codex clearance before reviewer approval. Record the provider and full SHA in the later approval as required by [Phase 2.5](REVIEW_POLICY.md#phase-25-automated-external-review-coderabbit).
5. Use the configured threshold, protected paths and the force-on `needs-external-review` label to route [Phase 4](REVIEW_POLICY.md#phase-4-external-review). Apply the governing policy's request budgets, external-review requirements and human escalation rules.
6. Outside an active native merge-queue rollout, merge one current, review-cleared head as `nathanjohnpayne` through the author wrapper only after all applicable gates, any approvals required by the governing policy, and review conversations clear. During an active rollout, follow the [canonical native merge-queue policy](https://github.com/nathanjohnpayne/mergepath/blob/main/REVIEW_POLICY.md#native-merge-queue-boundary-1058) and leave activation, queue actions and any direct merge to the human owner. Preserve human holds, reviewer disagreements and actual in-flight Codex review stops.

### Review Feedback Accounting (#1000)

Before requesting another Codex review, before dispatching Phase 4b, and immediately before merge, run `scripts/review-feedback-accounting.sh <PR#>` and require exit `0` with `posted == accounted`.

**One scoped exception, for the Codex request only (#1100).** `scripts/codex-review-request.sh` refuses on undispositioned findings **from the provider it is requesting** — Codex's own findings, and any reviewer identity including a Phase 4b adapter review — rather than from every provider. Phase 4b dispatch and the pre-merge run are unchanged and still require `posted == accounted` across all providers. The exception exists because the Phase 4b barrier waits for Codex to be terminal on the current head while its Codex arm is read-only, so this script is the only thing that can make Codex terminal: an all-provider precondition meant CodeRabbit's findings refused the Codex request, dispositioning them required fix commits, and each commit was a new head for CodeRabbit to find more on. The providers that may be skipped are enumerated (never the providers that must block), so an unmodelled, renamed or absent reviewer keeps refusing, and they are resolved from the governing **base** policy — the same one accounting classifies findings with — so a PR cannot nominate its own skippable set. The command reads every paginated inline comment, review object, and PR-level comment across all heads. A resolved thread, a prior-head finding, a `COMMENTED` review that never changes merge state, or a finding carried only in a top-level review body or PR-level summary therefore cannot disappear from the checklist.

`scripts/codex-review-request.sh` enforces this immediately before the author-attributed Codex review command write; exit `6` means feedback is unaccounted and no trigger was posted. `scripts/phase-4b-review.sh` enforces it before the reviewer adapter and verifies its approval acknowledgment after posting; exit `7` means feedback is unaccounted and no manual handoff was rendered. If the emitted JSON says `review_posted: true`, repair the posted approval's acknowledgment without repeating the review; otherwise no reviewer round ran, so disposition the named earlier findings and rerun. Exit `7` is not one of Phase 4b's manual-fallback exits. `scripts/post-phase-4b-handoff.sh` enforces the same rule for the manual path and exits `4` without rendering when feedback is missing. `scripts/codex-p1-gate.sh` runs accounting default-on in every consumer; `codex.p1_gate.enabled` controls only its legacy current-HEAD thread scan.

An inline finding needs a substantive finding-thread reply after its latest raise or edit. The validated Codex `+1` / `-1` reaction and repo-local recorder ledgers remain required for analytics, but neither is standalone accounting evidence: reaction deletion emits no workflow event that reruns the required check, and ledgers are worktree-local across the author, trusted-review, and CI checkouts. A classified top-level review-body finding is independent of that review's inline findings and uses the `[mergepath-review-ack: <review id> <body fingerprint>]` token printed by the accounting command. A PR-level issue-comment finding uses the corresponding `[mergepath-comment-ack: <comment id> <body fingerprint>]` token. An inline finding removed by an edit or deletion no longer has a replyable thread, so disposition its archive with the `[mergepath-inline-ack: <comment id> <fingerprint>]` token. Put the fix, rebuttal, or deferral rationale on following lines. Thread resolution alone does not count as reading or dispositioning a finding.

Post Markdown through the identity-checked wrapper using `--body-file` (or an equivalent structured stdin/JSON payload). Never interpolate shell-sensitive Markdown such as backticks into a double-quoted `--body` argument. Re-read the posted GitHub object and rerun accounting; a command's zero exit or printed success count is not proof that the intended payload landed.

This rule is additive to workflow steps 5–10 above and controls their sequencing: record per-finding evidence before a push can make a HEAD-pinned `--scan` miss the round, require accounting before any later review round, and merge only after accounting, the merge gate, and the zero-unresolved-thread gate are all clean. Full contract: [`specs/review_feedback_accounting.md`](specs/review_feedback_accounting.md).

### Disagreements

If the internal reviewer and external reviewer disagree on whether code is ready to merge, the human is the tiebreaker. Surface both positions clearly and wait.

In Phase 4a specifically, the agent escalates automatically on any of three signals: **repeat-after-rebuttal** (Codex re-flags a finding after the agent posted a rebuttal reply), **runaway** (the Phase 4b barrier's `runaway` stop at a spent request ceiling: every request `codex.max_review_rounds` allowed drew a blocking review whose findings were not all fixed, as REVIEW_POLICY.md § Disagreements and Tiebreaking signal 2 defines fixed; the ceiling alone is cost exhaustion, not a runaway), or **blocking-review budget** (requester exit `7` with `cap_exhausted.kind: "blocking-reviews"`: the PR already holds `codex.max_blocking_reviews` solicited Codex responses that are blocking, unknown-tier or conflicting, default 10, #1560). A spent **request ceiling** (requester exit `7` with `cap_exhausted.kind: "request-ceiling"`) is not one of them: run `scripts/phase-4b-review.sh`, whose barrier dispatches the adapter when no human stop holds and exits `8` when one does (#1560 slice 3). On escalation, the agent stops the loop, posts a comment on the PR summarizing both positions with links to the review rounds, alerts the human, and does not merge or route to automated Phase 4b. Only the owner can release a Phase 4b dispute or runaway stop, for one head, with the marker comment REVIEW_POLICY.md § Disagreements and Tiebreaking describes; the head then still goes to the Phase 4b adapter, and an agent never writes the filled-in marker. For blocking-budget exhaustion, or a cap-related Phase 4b exit `8`, the comment instead reports the configured and consumed counts (requests, and blocking reviews), any provider-block diagnostic, and the observed final-request/response state (or that it is unknown); opposing positions and rebuttal links are not required. Timeout (exit code `4` from `codex-review-request.sh`) is NOT a disagreement — it falls back to Phase 4b directly. Full detail in REVIEW_POLICY.md § Disagreements and Tiebreaking.

### Adding a New Agent

1. Create a GitHub account: nathanpayne-{agent}
2. Add it to available_reviewers in .github/review-policy.yml.
3. Configure the agent environment with credentials for both nathanjohnpayne and the new reviewer identity.

For the complete policy including the handoff message format, post-merge issue creation rules, and git identity switching instructions, read REVIEW_POLICY.md.
