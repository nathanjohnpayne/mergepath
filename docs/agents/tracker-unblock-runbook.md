# Runbook: Unblocking Downstream Trackers

How to run a multi-ticket session whose goal is to unblock one or more consumer-repo trackers through Mergepath work: refresh the live scope, deliver canonical fixes and their reviewed propagation, verify consumer acceptance, and leave honest evidence on every tracker.

**This runbook sequences existing rules. It does not create new ones.** It is written for any registered agent: `<agent>` below is the running session's agent (`claude`, `codex` or `cursor`), and `nathanpayne-<agent>` is that agent's reviewer identity. Never substitute another agent's identity or cache. [REVIEW_POLICY.md](../../REVIEW_POLICY.md), `.github/review-policy.yml`, [AGENTS.md](../../AGENTS.md) and the `docs/agents/` files it indexes are the authority. Where this file disagrees with them, they win and this file is out of date. A session prompt that points here should supply only what is specific to the run: the trackers, the starting scope, dated context, owner decisions, authorizations, and limits (see [§ What the session prompt supplies](#what-the-session-prompt-supplies)).

## 1. Session start

1. **Read the authority first.** Read `AGENTS.md`, the `docs/agents/` files it lists, `REVIEW_POLICY.md`, `.github/review-policy.yml`, [templated-propagation.md](templated-propagation.md), [propagation-ordering.md](propagation-ordering.md), [high-priority-scope-discipline.md](high-priority-scope-discipline.md) for `priority:high` tickets, and any nested instructions under the paths you will touch.
2. **Verify the checkout.** Check the root (`git rev-parse --show-toplevel`), the `origin` URL, the branch, and write permission. Work only in worktrees placed per [worktree-placement.md](worktree-placement.md). Use `git -C <worktree>` rather than `cd`, because absolute-path edits from a nested worktree can land in the main checkout.
3. **Verify identity and signing.** After step 4 warms the cache, verify both cached tokens: `GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" scripts/identity-check.sh --expect-token-identity nathanjohnpayne` and `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/identity-check.sh --expect-token-identity nathanpayne-<agent>`. The write wrappers re-verify with `--expect-write-identity` on every write. Confirm that `git config user.signingkey` resolves and that a test commit verifies as `nathanjohnpayne`.
4. **Warm credentials once.** Run `eval "$(scripts/op-preflight.sh --agent <agent> --mode review)"`. Before every later credentialed call, revalidate with `eval "$(scripts/op-preflight.sh --agent <agent> --check --print-exports)"`, which never prompts. Never print token values, and never change the gh keyring's active account.
5. **Find other sessions before touching shared state.** The preflight cache is keyed per agent (`op-preflight-<agent>.env`), so every session of the same agent on this machine shares it. Check for other sessions with an app-wide or machine-wide view, such as the desktop app's session list. `ListAgents` alone is not enough: it lists only this session's own team and subagents, so it can report no peers while another top-level session shares the cache. Refresh the live ownership of any PRs or issues the prompt says another session owns: their author, latest pushes, labels and open comments. Do not alter another session's PRs, branches, holds, review budgets or cache.

## 2. Building the work set

Rebuild the scope from live GitHub. Treat the prompt's issue list as a starting point, not as the current state.

For each candidate issue, read:

- the full body and **all** comments (paginate; `gh pr view --json` silently caps connections at 100);
- linked owner decisions, including decisions recorded in comments and surfaced per [decision-records.md](decision-records.md);
- project fields: priority, size, implementation model, reasoning effort;
- dependencies (`gh api repos/<o>/<r>/issues/<n>/dependencies/blocked_by`), sub-issues, and `human-hold` or other blocking labels;
- existing PRs (open, merged and closed) and their merge state.

Then compare the current canonical source against each reported weakness. Classify every open ticket into exactly one **remaining-work class**:

| Class | Meaning | Typical disposition |
| --- | --- | --- |
| `implement` | The canonical fix is missing or incomplete | Canonical PR |
| `propagate` | The canonical fix has merged, but consumers lack it | Reviewed propagation PR |
| `verify` | Consumers have it, but acceptance evidence has not been recorded | Verification comment; close the criteria actually met |
| `owner` | Blocked on a decision only the owner can make | Propose-only (§ 4) |
| `credential` / `external` | Blocked on a human credential, setting, rotation or deployment action | Prepare the evidence and the exact ask; do not perform it |

Reuse existing fixes, PRs and tracking issues. Never build a second competing implementation of something that already has a canonical owner issue.

### Work table

Present one compact table before you start executing, and update it at each batch boundary:

| Issue | Priority / impact | Class | Remaining size | Depends on / holds | Model | Effort | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |

## 3. Ordering and concurrency

- **Order:** priority tier first; within a tier, smallest remaining size first; dependencies override both.
- **Concurrency:** at most **two** PRs in review at once, and exactly one merge at a time. Start the next ticket while a PR waits on review or CI, but do not open a third. Each additional open PR multiplies rebases, expired approvals and spend against the shared token budgets (`GITHUB_TOKEN` 1k/hr/repo, PAT 5k/hr/account).
- **Model and effort:** use the ticket's project fields. A session cannot change its own model, so when a ticket specifies a different model or effort, delegate that ticket's implementation to a subagent configured with it. When a field is unset, keep the session's setting. When a specified setting is unavailable, record the mismatch in the ledger, ask once, and continue other work.

## 4. Owner decisions: propose, don't implement

Some tickets require an owner decision, for example a change to merge authorization or a security model choice. For those:

1. Write the decision proposal on the issue: options, recommendation, and the evidence that would distinguish them. Use the top-of-body callout convention from [decision-records.md](decision-records.md) once a decision exists.
2. Mark the ticket `owner` in the work table and the ledger.
3. Do not implement dependent work speculatively. Continue with other actionable tickets.

A stronger reviewer model, a prompt warning or a schema validation is not a substitute for an owner decision, and it is not evidence of an independent authorization source.

## 5. The per-PR loop

Follow REVIEW_POLICY.md's workflow. The scripts it relies on are listed below. Always pass the PR number **and** the target repository: helpers that omit the repository fall back to `gh repo view` in the shell's current checkout, which in a cross-repo session can be a different repo with a same-numbered PR.

| Step | Script |
| --- | --- |
| Author writes (create, edit, comment, merge) | `scripts/gh-as-author.sh -- gh …` |
| Reviewer writes | `GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> scripts/gh-as-reviewer.sh -- gh …` |
| Should CodeRabbit be invoked? | `scripts/coderabbit-should-invoke.sh <PR#> --repo <owner/repo>` |
| Wait out a CodeRabbit window | `scripts/coderabbit-wait.sh <PR#> <owner/repo>` (sleep only the remaining `retry_after` window) |
| Request Codex | `MERGEPATH_PHASE_4A_GATED=true scripts/codex-review-request.sh <PR#> <owner/repo>` on a Phase 4 PR (recommended; without the flag, when `codex.request_by_default` is false or unset, the default since #2240, the requester derives the Phase 4 gate from the PR and skips with exit `5` only a PR it reads as under the threshold, #2257) (never hand-roll the `@codex review` trigger) |
| Read the Codex verdict | `scripts/codex-review-check.sh <PR#> <owner/repo>` |
| Record per-finding verdicts | `scripts/codex-record-feedback.sh <PR#> <owner/repo> --verdict …`, `scripts/coderabbit-record-feedback.sh <PR#> --repo <owner/repo> …` |
| Complete-history accounting | `scripts/review-feedback-accounting.sh <PR#> <owner/repo>` (require exit `0` and `posted == accounted`) |
| Resolve threads | REVIEW_POLICY.md § Pre-Merge Review Conversation Gate (`scripts/resolve-pr-threads.sh <PR#> --repo <owner/repo>`) |
| Automated Phase 4b | `scripts/phase-4b-review.sh <PR#> --repo <owner/repo>`, **only** from a trusted main-ref checkout and only when policy enables it |

Rules that come up repeatedly:

- Disposition each finding in real time: reply, then fix, record and resolve. Do not batch them at the end of a round.
- Do not infer a completed CodeRabbit review from a mutable summary's assessment marker. Do not retry a refusing provider before its `retry_after` window has elapsed.
- On a Phase 4b `HELD` result (exit `6`), read the emitted reason first. A hold that clears on its own, such as external review not yet reaching the head, is a bounded wait: sleep the JSON's `retry_after` and rerun. A hold caused by persistent PR state, such as a draft or a non-base target, will not clear by waiting; fix the state instead. Treat a human-tiebreaker outcome as a required decision.
- Never reset review counters, and never restart an exhausted loop without an explicit owner decision.

### Stop conditions

A spent Codex request ceiling (`CAP_EXHAUSTED`, `kind: request-ceiling`) is cost exhaustion, not a reason to park: route the PR to Phase 4b as REVIEW_POLICY.md directs. When `phase_4b_automation.enabled` is true, run the automated leg and let its barrier decide whether to dispatch the adapter or stop for a human tiebreaker; when it is false or absent, use the manual Phase 4b CLI handoff.

Park a PR and move to other work, recording why in the ledger and on the PR, when any of these happen:

- an escalation signal from REVIEW_POLICY.md fires (repeat-after-rebuttal, the Phase 4b barrier's `runaway` stop, or a blocking-review ceiling), or Phase 4b returns a human-tiebreaker outcome;
- `scripts/coderabbit-wait.sh` exits `5` (rate-limit stalled) with `codex_failover_requested: false` in its JSON. Alert the human and do not proceed toward merge. When the failover did engage (`codex_failover_requested: true`), exit `5` is a non-blocking note and the PR continues through Phase 4a;
- the PR needs a decision that § 4 classifies as an owner decision;
- a required-tier finding would enlarge the PR's contract rather than find a defect in it, and `feedback_policy` does not permit deferring it (see [high-priority-scope-discipline.md](high-priority-scope-discipline.md)). A finding whose tier permits deferral is recorded as a follow-up or accepted residual and the PR continues through the normal accounting and merge gates.

## 6. Immediately before every merge

Do every step, every time, even if you just did it:

1. Read the live full head SHA.
2. Confirm the required approvals exist **on that head**.
3. Confirm every required check source is green on that head. The newest run of **each** lineage must pass, and a check that never reported is not passing.
4. Confirm there are no `human-hold` or other blocking labels.
5. Run both feedback recorders, then `scripts/review-feedback-accounting.sh <PR#> <owner/repo>`, and require `posted == accounted`.
6. Run the Pre-Merge Review Conversation Gate and require zero unresolved conversations. Resolve actioned bot threads and accepted registered-agent threads only through the identity-checked paths. Never resolve or alter human-authored conversations, and never remove `human-hold`.
7. Merge: `scripts/gh-as-author.sh -- gh pr merge <PR#> --repo <owner/repo> --squash --delete-branch --match-head-commit <full-head-sha>`. Always pass `--repo` (or the full PR URL): a session working across repos with `git -C` would otherwise resolve the PR number against whatever checkout the shell is in.

### Break-glass

`--admin` requires an explicit human authorization in chat (REVIEW_POLICY.md step 18a). A session prompt may pre-authorize it only for stuck workflow infrastructure, and only after every non-infrastructure gate above is satisfied. When you use it:

- bind the authorization to the exact PR number and full head SHA;
- record the evidence in a top-of-body callout on the PR: the failing workflow run URLs, the approvals on that head, and a link to the authorization;
- explain the precise reason on any policy-violation ticket that the action creates.

Break-glass never waives a real source failure, a required finding, a human hold or an escalation decision.

## 7. Security work: what counts as evidence

| Claim | Not sufficient on its own |
| --- | --- |
| A consumer is remediated | A canonical merge. You need the consumer's propagated revision plus a verified behavior check. |
| Live credential exposure is remediated | A hub-only audit, or an environment-only scrub (on-disk caches can remain readable) |
| A Security Cloud finding is fixed | Source reproduction. Record the evidence and leave the finding's status to its owner. |
| Resistance to a hostile diff | A stronger model, a prompt warning or schema validation |

Use safe adversarial fixtures with fake credentials. Keep fixtures scanner-clean, because a realistic `ghp_` string reds the whole fleet. Never run a live exploit, rotate a credential, deploy to production, run a paid API experiment, change a repository setting or weaken review policy without human authorization; prepare the concrete evidence and the proposal instead.

## 8. Propagation

Implement shared tooling at the canonical Mergepath source, and deliver consumer changes through the reviewed propagation path in [templated-propagation.md](templated-propagation.md). Read each consumer's current instructions before changing it. Never hand-edit generated mirrors, and never commit on a mirror branch. Per-repository-owned files such as a consumer's `REVIEW_POLICY.md` are not covered by propagation. A guard over them must scan the consumer corpus, and its migration findings must preserve legitimate fixture identity setup and explicit exemptions.

## 9. The ledger

Keep one durable ledger per run as a single comment on the run's primary tracker issue, edited in place. Its first line is `Run ledger: <session start date>`. It must not contain credentials or private job-search content. It records:

- the dependency closure and the class of each ticket;
- source and consumer revisions (SHA-pinned);
- decisions, with links to where each was recorded;
- acceptance coverage per criterion: met (with evidence link), unmet, or owner/credential-blocked;
- per PR: full head, review state, CI state, and the next useful check time;
- feedback dispositions that remain open;
- merged results, and the rollout or owner actions that remain.

## 10. Batch boundaries and reporting

After each batch's PRs are confirmed merged:

1. Run `scripts/op-preflight.sh --agent <agent> --check`.
2. **If valid:** refresh the live closure, update the work table and ledger, and continue with the next actionable batch without asking.
3. **If missing, stale or invalid:** pause credential-dependent work and report what is done, what is outstanding, and the exact human action needed. Do not re-warm credentials without the human present.

Send a short update when a PR opens, when it merges, when a blocker appears, and at each batch boundary. Stay quiet otherwise.

## 11. Session end

1. Update the upstream and downstream trackers with linked, current evidence. Close a downstream tracker only when its consumer criteria are verified.
2. Sync `main`. Preserve recovery evidence, including any necessary ignored files, before cleanup.
3. Remove only the worktrees and branches this task created (`scripts/worktree-cleanup.sh` audits candidates).
4. Finalize the credential cache **only if a machine-wide check (§ 1 step 5) shows no other session of the same agent is active**; if you cannot establish that, leave the cache in place. `scripts/op-preflight.sh --agent <agent> --purge` deletes the cache that every session of that agent shares; never purge another agent's cache. Never use `--purge-all`.

## What the session prompt supplies

A prompt that points here should contain only:

- the downstream trackers, and the starting Mergepath issue list;
- dated context to revalidate ("as of YYYY-MM-DD");
- owner decisions already made, and which tickets are propose-only;
- authorizations (implementation, PRs, propagation, merges, and any scoped break-glass);
- limits: maximum merged PRs or a time box, and anything explicitly out of scope;
- other sessions' owned PRs or issues to avoid;
- where the ledger lives, if not on the primary tracker.
