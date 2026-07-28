# Shared Agent Operating Rules

> Canonical source: `mergepath/docs/agents/shared-operating-rules.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. A change here reaches every repo through a propagation wave, so every sentence must be true in all of them.

This file is the **shared core** of the agent operating rules: the rules that hold, unchanged, in every repository that receives it. It carries no repo-specific content — no tech stack, no architecture, no build or deploy specifics, no references to tooling a receiving repo does not have.

Each repository keeps its own `docs/agents/operating-rules.md` as the **local overlay**: reading order, conflict resolution, architecture and coding conventions, log access, and anything else that is true only there. Read this file first, then the local overlay. Where the two overlap, this file is the baseline; the overlay may add repo-specific detail on top of it but should not contradict it. If a rule in the overlay turns out to be true everywhere, it belongs here instead — raise it at the canonical source rather than copying it between repos.

Issue references below use the fully-qualified `nathanjohnpayne/mergepath#NN` form on purpose. These rules were decided in the mergepath hub, and a bare `#NN` in a propagated file silently resolves against whichever repository you are reading it in.

## Always paginate PR comment / review / check-run list reads

Any `gh api` list read against a PR's comments, reviews, or check-runs MUST use `--paginate` (or, for a GraphQL connection, a cursor loop). This is not optional past round 1 of a Phase 4a review loop. `gh api` without `--paginate` fetches exactly one page --- 30 items by default, at most 100 with `per_page=100` --- and returns cleanly with no error or warning that more data exists. On a long-lived PR that has been through many review rounds, the current data routinely sits past that boundary, so an unpaginated read silently returns a stale or empty result that reads as "no new activity" or "no findings" when the opposite is true. This has repeatedly produced false all-clear conclusions and can silently defeat a merge gate (nathanjohnpayne/mergepath#691).

This applies to every hand-rolled, mid-session investigative query, not just the shipped helper scripts. An agent manually inspecting a PR's live state is the common case, and it is exactly the query that skips the paginated helpers. The endpoints that truncate, and the correct form:

- Inline diff comments --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/comments"`. By round 4+ a PR easily exceeds 30 of these (findings, plus replies, plus resolve-tool tag-replies), so the newest findings land on page 2 and an unpaginated read returns nothing for them.
- PR-level (issue) comments --- `gh api --paginate "repos/OWNER/REPO/issues/PR/comments"`. This is where a Codex clean verdict lands.
- Review objects --- `gh api --paginate "repos/OWNER/REPO/pulls/PR/reviews"`. This is where a Codex findings round lands.
- Check-runs / commit statuses --- `gh api --paginate "repos/OWNER/REPO/commits/SHA/check-runs"` and `.../statuses`. A single head commit can accumulate 100+ check-runs from repeated scheduled-sweep re-evaluations (194 observed on nathanjohnpayne/mergepath#687), so even `per_page=100` without `--paginate` silently drops a live failure onto page 2.

`gh pr view --json comments|reviews|statusCheckRollup` has the same trap and CANNOT be fixed with `--paginate`: the `--json` GraphQL shape caps each connection at the first 100 entries and strips the `pageInfo` you would need even to detect the truncation. For any connection that can exceed 100 (check-runs above all), read the REST endpoint with `gh api --paginate`, or walk the GraphQL connection with a Relay cursor loop --- see the `statusCheckRollup` cursor loops in `scripts/codex-review-check.sh`. A single-item read (`repos/.../issues/comments/ID`, `repos/.../pulls/PR`) is not a list and does not need `--paginate`.

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
   > "1Password auth failed. Would you like to run credential preflight to cache all credentials at once? `eval \"$(scripts/op-preflight.sh --agent {your-agent} --mode review)\"`"
   >
   > (Use `--mode deploy` or `--mode all` instead if a deploy is in scope; the default is now `review` per nathanjohnpayne/mergepath#282.)
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

## Daily feedback rollup — the deferred-and-forgotten class

Every repository that receives these rules runs a daily rollup that catches review feedback which was closed out but never actually addressed. Agents should know when it fires and which issue to triage, so the same items are not chased twice.

**`.github/workflows/daily-feedback-rollup.yml`** runs daily at `55 23 * * *` UTC. It scans yesterday's MERGED PRs and surfaces bot review threads that were RESOLVED **without** an associated fix commit or substantive reply. The output splits into two clearly-labeled tracks (substantive / polish) so the high-severity stream stays high-signal even on days with a lot of nit volume.

This catches the class that motivated nathanjohnpayne/mergepath#234 / nathanjohnpayne/mergepath#286 / nathanjohnpayne/mergepath#287: a CodeRabbit Major or Codex P2 the agent resolved as "non-blocking, will fix in a follow-up" — and then nobody wrote down. Captured while the resolving agent's context is still hot.

See `scripts/daily-feedback-rollup.sh` (workhorse) + `scripts/lib/daily-feedback-rollup-helpers.sh` (classifier helpers) + `scripts/resolve-pr-threads.sh --auto-resolve-bots` (the upstream emit-side that tags each resolve with `[mergepath-resolve:<class>]` so the classifier prefers agent-recorded rationale over heuristics).

Which issue to act on:

- Routine end-of-day triage → the substantive `deferred-feedback-rollup YYYY-MM-DD` issue from the daily cron. Items aged 0-7 days, context fresh.
- Polish/nit batch triage → the `polish-feedback-rollup YYYY-MM-DD` issue from the same daily cron. Lower urgency; can batch across multiple days.

The rollup is per-repo: the workflow runs in the repository it is installed in and opens its issues there. Cross-repo aggregation is an explicit non-goal; the per-repo design preserves operator focus on the repo whose context they are currently in.

## PR and issue titles/descriptions: describe the work, not the session

Titles and descriptions — for both pull requests and issues — must describe the final state of the change (what it does and why) for a reader who arrives with no knowledge of the session that produced it.

- Do not narrate the session's path: no pivots, abandoned approaches, "originally did X, then switched to Y," or commentary on how the plan evolved.
- When a pivot changes what the work is, update the title/description to reflect the new end state — not the fact that a pivot happened.
- Once a title or description already describes the work accurately, treat it as read-only. Do not reword or "refresh" it to fold in later session context.
- This bans narrating the session, not documenting the work. Design rationale, an "Alternatives considered" section, or contrasting the change with the prior committed code (e.g. "replaces the hard-coded `null` with a threaded value") all describe the end state for a cold reader and are fine. The test: would the text help someone who never saw the session? Rationale and prior-code contrast pass; "I first tried X, then switched" does not.

This is advisory guidance for judgment, not a `repo_lint`/CI gate — the narration-vs-rationale distinction is not reliably lintable, and a reviewer (human or bot) should apply it as judgment rather than minting false-positive findings from words like "originally" or "instead." See nathanjohnpayne/mergepath#654.
