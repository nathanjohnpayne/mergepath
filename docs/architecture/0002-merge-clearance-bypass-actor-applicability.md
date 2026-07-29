# 0002: Merge-clearance enforcement probe — bypass-actor applicability

## Status

Accepted. Implemented for [#781](https://github.com/nathanjohnpayne/mergepath/issues/781) item 11, refining the rule [#775](https://github.com/nathanjohnpayne/mergepath/pull/775) shipped for [#772](https://github.com/nathanjohnpayne/mergepath/issues/772).

Recorded as an ADR rather than left in review threads because two review rounds on #775 argued opposite sides of the same trade-off, and `docs/agents/decision-records.md` requires the disposition to be written down at the place a later reader will look. Without it, the next reader of `merge_clearance_check_enforced()` cannot tell whether the strict rule was never questioned, questioned and kept, or loosened by accident.

## Date

2026-07-28

## Context

`scripts/merge-clearance-gate.sh --derive-rate-limit-protection` answers one narrow question for `agent-review.yml`'s CodeRabbit rate-limit branch: is this PR protected from bot-unreviewed auto-merge? Arm 1 answers it by proving that `Merge clearance gate` is an ENFORCED required status check on the PR's base branch. One of the two surfaces it reads is repository/organization rulesets.

A ruleset that lists bypass actors does not necessarily bind the account that runs the final `gh pr merge`. The `repos/{owner}/{repo}/rules/branches/{branch}` endpoint filters to rules enforced on the REQUESTING identity — the CI reviewer token — while the merge itself runs under the author token, so a ruleset the author can bypass still appears in that response.

Two review rounds on #775 reached opposite conclusions about what to do with that:

| | Round 2 (P1, implemented in #775) | Round 5 (P2, deferred to #781 item 11) |
| --- | --- | --- |
| Concern | a bypassable ruleset is counted as protection | a *non-applicable* bypass actor blocks a protected merge |
| Fails toward | availability loss | safety loss |
| Rule proposed | any bypass actor ⇒ ruleset not counted | compare actors against the merging identity |

Both are correct about their own failure mode. They trade safety against availability at different points on the same axis, and the disagreement is genuine rather than one side being mistaken.

Exposure at the time of writing is zero in both directions: no repository in the fleet uses rulesets at all (`rules/branches` and `rulesets` return `[]` fleet-wide, re-verified on 2026-07-28 against `mergepath`, `nathanpaynedotcom` and `matchline`), and per [#774](https://github.com/nathanjohnpayne/mergepath/issues/774) `Merge clearance gate` is not a required check on any repository, so arm 1 is unreachable today regardless.

## Decision

**Keep Round 2's conclusion as the default and narrow it with an allowlist of actors that provably cannot BE the merging identity.** A bypass actor disqualifies its ruleset unless it appears on that allowlist; the allowlist is closed and every unrecognized form falls back to disqualifying.

The merging identity is `author_identity` from the governing review policy — the same value `REVIEW_POLICY.md` § Automated merge identity requires `AUTHOR_MERGE_TOKEN` to resolve to before any automated merge, and the value `scripts/hooks/gh-pr-guard.sh` enforces on manual author writes.

Per GitHub bypass-actor type:

| `actor_type` | Ruled out? | Reasoning |
| --- | --- | --- |
| `DeployKey` | Yes | Deploy keys authenticate git transport only. The REST and GraphQL APIs reject them, so a deploy key can never perform the pull-request merge whose protection this probe asserts. |
| `Integration` | Yes, when `actor_id` is a number other than the trusted Actions app id | A GitHub App is a different principal from the user account `author_identity`, and the merge is required to run under a token verified to resolve to that user. The trusted Actions app is EXCLUDED from the rule-out because workflow steps in this repository do authenticate as it. |
| `OrganizationAdmin` | No | A set of accounts that can contain `author_identity`. Deciding membership needs an org-membership read this token is not guaranteed to have, and membership can change between the probe and the merge. |
| `RepositoryRole` | No | Same set-membership problem, plus GitHub does not publish a stable role-id to permission-level mapping. |
| `Team` | No | Same set-membership problem; needs a team-membership read. |
| anything else, or a missing `actor_type` | No | An allowlist, not a blocklist: an actor type GitHub adds after this was written disqualifies by default rather than passing silently. |

Two further conditions gate every rule-out:

- `author_identity` must be present in the governing policy. Absent, the merging identity is unknown, nothing is ruled out, and behaviour is byte-identical to the Round 2 rule.
- `author_identity` must not be a `[bot]` login. The `Integration` rule-out rests on the merger being a user account; an app-shaped merging identity breaks that premise.

The ruleset payload must still expose `bypass_actors` as an array. An absent key or a non-array value is an unrecognized shape, not proof of zero bypass actors — the direction #772 round 4 established this probe must never move in.

## Alternatives considered

**Resolve membership by API.** Read `orgs/{org}/memberships/{user}`, `repos/{owner}/{repo}/collaborators/{user}/permission`, and team membership, then decide `OrganizationAdmin` / `RepositoryRole` / `Team` on evidence. Discarded: those reads need scopes the write-scoped reviewer PAT this query runs under is not guaranteed to have, so in practice they fail and the requirement to fail closed lands on exactly the same verdict — at the cost of three more API dependencies on a merge-gate path, and a time-of-check/time-of-use window in which membership can change between the probe and the merge.

**Keep Round 2 unchanged and close item 11 as won't-fix.** Defensible on exposure grounds alone. Discarded because the narrowing above needs no new API surface, no new token scope, and no membership inference — the two rule-outs are properties of the actor kind itself, not of who happens to be in a group today — so the availability gain is free of the risk that motivated the objection.

**Trust `bypass_mode`.** Discarded: both `always` and `pull_request` permit bypassing on a pull-request merge, so the field does not separate the applicable case from the inapplicable one.

## Consequences

- A ruleset whose only bypass actors are deploy keys or unrelated GitHub Apps now counts as enforcement, so arm 1 can return `true` where it previously fell through to arm 2.
- The Round 2 defect stays fixed: `OrganizationAdmin`, `RepositoryRole` and `Team` bypass actors continue to disqualify a ruleset, and `tests/test_merge_clearance_gate.sh` Protection 1i / 1v / 1v2 hold that line.
- Consumers whose review policy carries no `author_identity` are unaffected — they keep the strict rule.
- Every failure to read or parse still resolves to "not enforced", which costs availability and never safety: the query falls through to arm 2's positive-proof current-head clearance check.
- Widening the allowlist later is a safety-relevant change and should be argued against this record, not decided in a review thread.
