# Review Feedback Accounting

Feature: every bot-authored or registered external-reviewer finding on a pull request is mechanically reconciled with finding-bound disposition evidence before another Codex review is requested, before a Phase 4b reviewer is dispatched, and before merge. The accounting answer comes from GitHub's complete paginated review history rather than from merge-state fields, a success count, current-HEAD-only scans, or review-thread resolution state. This closes the failure classes recorded in #1000: unread findings hidden by automatic resolution, a finding carried only in a top-level review body, prior-head findings stranded by a push, and a late `COMMENTED` review that never changes GitHub's merge-state summary.

## Finding inventory

- `scripts/review-feedback-accounting.sh <PR_NUMBER> [REPO]` resolves the policy governing the pull request from its base branch, then reads all pages of `pulls/{pr}/comments`, `pulls/{pr}/reviews`, and `issues/{pr}/comments`. A same-repository default-base invocation uses the trusted checkout policy without a contents API call; a non-default base or cross-repository invocation materializes the target repository's base policy through `resolve_base_policy.sh`. A failed or unparseable policy or history read is an infrastructure error, never an empty finding set.
- An inline finding is a root-thread Codex or CodeRabbit comment whose body is classified by the shared `codex_tier_of` / `coderabbit_tier_of` ladder. A bot re-raise in the same root thread supersedes the earlier instance, so the latest classified bot comment is the one logical finding that needs evidence after its staleness floor.
- A top-level Codex, CodeRabbit, or registered `available_reviewers` review body whose body is classified by the applicable ladder is an independent review-body finding. Review objects are not assumed to be summaries: a `COMMENTED` or `CHANGES_REQUESTED` review can carry the only copy of a finding.
- A Codex or CodeRabbit PR-level issue comment whose body is classified by the same ladder is an independent issue-comment finding. This covers summary-only findings that have neither an inline comment nor a review object.
- CodeRabbit PR-level and review-body surfaces are scanned outside CommonMark fenced code and outside a structurally paired `pre_merge_checks_walkthrough` block. Quoted source markers and check-table warnings are not invented into reviewer findings; an unpaired block marker fails toward classification rather than suppressing the remainder of the body.
- When one top-level body carries multiple classified severity markers, the inventory excludes ignored markers and assigns the strongest remaining tier (`p0` through `nitpick`) after excluding those non-finding regions. An ignored marker therefore cannot hide a required or discretionary finding regardless of their relative strength or document order.
- Inventory is intentionally not HEAD-pinned. A push does not erase the obligation to disposition a finding from an earlier head. Tiers configured as `ignore` are excluded; required and discretionary tiers remain inventoried because both represent surfaced feedback.
- Markerless review bodies and unclassified bot narration are not invented into findings.

## Disposition evidence

- An inline finding is accounted when, after its latest reviewer raise or edit, a configured author/reviewer identity posts a substantive reply in that thread. The evidence object must be an actual reply with `in_reply_to_id` bound to the finding root; a registered reviewer's root finding can never count as its own reply. The reply must contain at least two alphanumeric tokens and twelve normalized characters; punctuation, emoji, and generated `[mergepath-resolve: ...]` tags do not count. Codex-solicited reactions and recorder ledgers remain required analytics inputs, but neither is standalone accounting evidence: reactions can be deleted without an event that reruns the required check, while `.mergepath/` ledgers are worktree-local and gitignored, so accepting either would let different checkouts or later reaction state compute different answers.
- CodeRabbit can append `✅ Confirmed as addressed by @<identity>` to its finding after the named identity's substantive reply, advancing the comment's `updated_at` without changing or re-raising the finding. When that exact confirmation line immediately precedes CodeRabbit's generated-comment/reply footer and names a configured identity, the named identity's substantive reply after the finding's creation remains evidence. Other edits still invalidate older replies.
- A top-level review-body finding is accounted by a PR-level comment whose first line is exactly the emitted `[mergepath-review-ack: <review id> <fingerprint>]` token and whose rationale below it is at least 12 normalized characters containing at least two alphanumeric tokens. The fingerprint covers the whole review body, including trailing newlines represented by GitHub's JSON string, so editing a review invalidates an earlier acknowledgement without requiring the review id to change.
- A PR-level issue-comment finding uses the equivalent emitted `[mergepath-comment-ack: <comment id> <fingerprint>]` token and rationale. Its staleness floor is the finding comment's latest edit, and its fingerprint covers the whole current body.
- The acknowledging identity must be the configured author identity or one of `available_reviewers`. A bot, an unrelated account, an earlier comment, a bare token, or a token embedded below the first line is not evidence.
- A resolved review thread is not disposition evidence by itself. Resolution is a separate conversation-state gate and cannot make an unread finding disappear from accounting.

## CLI contract

The script emits one compact JSON object with `status`, `repo`, `pr_number`, `posted`, `accounted`, `missing_count`, `findings`, and `missing`. Every finding carries its shape, reviewer, tier, identifier, disposition state, and evidence kind; review-body and issue-comment misses also carry the exact acknowledgement token needed to retire them.

The governing policy is parsed once into JSON and all accounting decisions consume that representation, so block-style and flow-style YAML are equivalent. Runtime validation requires `jq` plus one YAML parser: mikefarah `yq`, Python 3 with PyYAML, or Ruby with its standard YAML library. If none is available, or if parsing/schema validation fails, the gate exits `2` rather than applying layout-dependent defaults.

- Exit `0`: every inventoried finding is accounted (`posted == accounted`).
- Exit `1`: one or more findings are unaccounted. JSON is still emitted and stderr names the remediation for each missing finding.
- Exit `2`: usage, configuration, cryptographic-tooling, or GitHub API failure. Callers fail closed.

## Enforcement points

- `scripts/codex-review-request.sh` runs the gate immediately before an author-attributed `@codex review` write. An accounting miss exits `6` and posts no trigger.
- `scripts/phase-4b-review.sh` runs the gate immediately before the reviewer adapter, including on dry-runs because the scarce operation is the reviewer reasoning round. An accounting miss exits `7`, dispatches no adapter, and renders no manual handoff.
- `scripts/post-phase-4b-handoff.sh` runs the same gate before rendering a manual-review handoff. An accounting miss exits `4` and emits no handoff, so consumers with automated Phase 4b disabled get the same dispatch-time protection.
- `scripts/codex-p1-gate.sh` runs accounting default-on in every consumer before consulting the legacy current-HEAD required-tier toggle. This supplies a merge-time CI backstop for top-level review-body and PR-level findings, plus discretionary-tier findings that review-thread state cannot represent; `codex.p1_gate.enabled: false` disables only the older thread scan.
- Every human- or agent-driven merge path also runs the accounting command immediately before merge, alongside the independent zero-unresolved-thread and recorder checks.

## Safe write and readback rule

Disposition replies and top-level acknowledgements are posted through the identity-checked author/reviewer wrappers using `--body-file` (or an equivalently structured stdin/JSON payload). Shell-sensitive Markdown is never interpolated into a double-quoted `--body` argument. After a write, the caller re-reads the GitHub object and reruns accounting; a wrapper's exit code or printed success count is not proof that the intended payload landed.

## Non-goals

- The gate does not judge whether a rationale is persuasive; it verifies that a finding-bound disposition record exists.
- The gate does not replace severity-specific merge policy, external-review clearance, reviewer approval, or GitHub conversation resolution. Those remain independent gates.
- The gate does not auto-resolve threads, post acknowledgements, react to findings, push commits, or merge.
