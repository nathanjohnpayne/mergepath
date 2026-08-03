# CodeRabbit Review Sensing

Feature: corroborated CodeRabbit barrier evidence on the Phase 4b rc-7 path. When `scripts/coderabbit-wait.sh --probe` (#814) finds a HEAD-pinned CodeRabbit review object whose PR-level summary has not published, it returns rc 7 `observed=awaiting-summary` — deliberately not a report, because the summary can carry the ONLY blocking marker (the #535 summary-only class, e.g. the auto-pause note). On #866 that state persisted for hours while the head was in fact fully reviewed (two COMMENTED head objects plus a per-SHA status success), and the barrier held not-yet until it escalated. This spec pins the additive evidence the probe now emits on that one path and the conjuncts under which the CodeRabbit arm of the Phase 4b same-head barrier (`p4b_barrier_class_coderabbit` in `scripts/phase-4b/lib.sh`) counts that state as reported. Comment-classification behavior is unchanged by this feature and is out of its scope.

## Acceptance criteria

### Probe rc-7 evidence contract

- rc 7 (PROBE_NO_REVIEW) is `--probe`-only: no terminal signal on this head; `probe.observed` names the surface the scan landed on (`none | rate_limit | paused | in_progress | summary-without-head-review | awaiting-summary`), and the JSON may still carry head-anchored evidence for the barrier to weigh. Polling mode never exits 7.
- On the rc-7 review-object (`awaiting-summary` family) path — and only there — the probe samples the per-SHA CodeRabbit StatusContext into `probe.context_state` (success|failure|pending|error|missing) and `probe.context_updated_at` (the newest status' refresh time), both null everywhere else, and both gated on `coderabbit.trust_status_context_for_clearance` (null when the policy opts out, which fails closed at the barrier).
- The rc-7 `reviews`-endpoint evidence additionally carries `review.submitted_at` — the evidence object's own timestamp, emitted explicitly for the barrier's temporal comparison.
- The StatusContext is never existence evidence on its own (CodeRabbit can flip a spurious success while rate-limited, #595/#596); its sole probe-mode role is this conjunctive ride-along, seconding a claim the head-pinned review object already made.
- Bounded re-scan (TOCTOU): the issue-comments snapshot predates the status read, so when the sampled status reads `success` while no summary was seen, the probe re-fetches the issue comments exactly once and re-scans — a summary found on the second pass takes the normal rc-0/rc-2 verdict (with the rc-7-only context fields cleared to null, preserving the null-outside-rc-7 contract), a failed re-fetch is infra rc 3 (emitting the success payload after a failed re-fetch would recreate the unscanned-summary hazard), and only a still-absent summary emits the rc-7 evidence; the re-scan reuses the single status sample rather than reading a status surface postdating the one it corroborates.

### Phase 4b barrier — CodeRabbit arm reported conditions

- rc 0 maps to `reported` only when the result's `head_sha` equals the head under review (#794 stale-clearance posture); rc 2 and rc 3 escalate; rc 4 and every rc 6 skip are `not-yet`; rc 5 is `waived` only when the #489 failover engaged, else escalate.
- rc 7 maps to `reported` only when ALL hold: `head_sha` matches the head under review; `probe.observed` is in the completion family (`awaiting-summary` or `terminal` — an active `rate_limit` / `paused` / `in_progress` observed state, or a missing/unmodelled value, fails closed); the evidence endpoint is `reviews` (a HEAD-pinned review object — `issues` evidence never opens); `probe.context_state` is `success`; and `probe.context_updated_at` is at-or-after `review.submitted_at` (same-run correlation — a success left over from a previous run against the same sha predates the new object and must not open past its pending summary). Any missing field or unparseable timestamp fails closed to `not-yet`.
- The classifier is pure — jq over the passed JSON string only, no I/O — so every condition above is decidable from the probe emission alone.

## Non-goals

- Verdict quality: rc 0 in probe mode asserts a report exists, not that it is clean; inline-finding disposition stays owned by `scripts/coderabbit-severity-gate.sh` and the conversation-resolution gate.
- Comment classification: how CodeRabbit comment bodies (including the finished-with-limit-note actions reply observed on #866) are classified is unchanged here and deferred to the dedicated classification-redesign issue, which will key on CodeRabbit machine markers rather than prose.
- Closing the disclosed #595 residual: a spurious per-SHA success that lands on the exact head, postdates that head's own review object, and coexists with no adverse pending notice can still open the barrier while the summary is in flight; the pre-#869 alternative was a full-budget escalation on every #866-shaped wedge.
