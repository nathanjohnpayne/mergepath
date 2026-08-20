# 0002: Branch-Protection Enforcement Posture

## Status

Decision recommendation — recorded 2026-07-28 under [#774](https://github.com/nathanjohnpayne/mergepath/issues/774), awaiting the repository owner's acceptance.

The half of #774 that this record covers, the automation that measures conformance against the posture below, is implemented: `scripts/audit-branch-protection.sh --fleet` and `.github/workflows/branch-protection-audit.yml`. The other half — actually changing branch-protection settings on the ten repos — is an owner-authorised settings change on live repositories ([#774](https://github.com/nathanjohnpayne/mergepath/issues/774) item 1) and has deliberately not been done. Until it is, the audit will report drift every week, which is the intended behaviour: the gap is now visible instead of silent.

Per `docs/agents/decision-records.md`, this is filed as a *recommendation* rather than a settled decision because acceptance is the owner's, and the wording here should be promoted to `Accepted` (with a date and a link to the accepting comment) at that point rather than rewritten.

## Date

2026-07-28

## Context

Mergepath ships five workflows whose jobs are intended to gate merges on `main`:

| Check name | Workflow | What it blocks |
| --- | --- | --- |
| `Label Gate` | `pr-review-policy.yml` | merge while `needs-external-review` / `needs-human-review` / `policy-violation` / `human-hold` is on the PR |
| `Self-Review Required` | `pr-review-policy.yml` | merge of a PR body with no `## Self-Review` section |
| `Codex P1 unresolved threads` | `codex-p1-gate.yml` | merge with an unresolved Codex finding in the `required` tier |
| `CodeRabbit unresolved blocking findings` | `coderabbit-severity-gate.yml` | merge with an unresolved CodeRabbit finding in the `required` tier |
| `Merge clearance gate` | `merge-clearance-gate.yml` | merge of a Dependabot or `needs-external-review` PR that is not cleared on the *current* HEAD |

A GitHub Actions job only gates a merge when it is listed as a **required status check** in the repository's branch protection. Absent that listing the job still runs and still goes red — and the PR merges anyway. The five names above are the canonical set encoded in `CANONICAL_REQUIRED_CHECKS` in `scripts/audit-branch-protection.sh`.

That constant has never been backed by an explicit decision. It was written as an implementation detail of the audit, and "every repo should require all five" has been an implicit consequence of a list in a script rather than a position anyone took on the record. #774 measured what that produced: on 2026-07-28 the audit exited 3 on all ten repos in the fleet, eight enforced zero of the five, and three (`nathanpaynedotcom`, `overridebroadway`, `gaycruisebingo`) had no protection on `main` at all. mergepath itself enforced two of five. Nobody had decided that; nobody had decided against it either.

## Decision

**Every repository in `.mergepath-sync.yml`, plus the hub, should require all five canonical checks on its default branch. There is no consumer class exempt from any of the five.**

### Why requiring all five is safe everywhere

The objection to a uniform posture is normally that it forces a repo to adopt machinery it has not opted into. That objection does not apply here, because each of the three optional gates is a **no-op that reports success** when its per-repo knob in `.github/review-policy.yml` is off:

- `Codex P1 unresolved threads` is green when `codex.p1_gate.enabled` is false;
- `CodeRabbit unresolved blocking findings` is green when `coderabbit.severity_gate.enabled` is false (the fleet default);
- `Merge clearance gate` is green when both `dependabot.reviewer_gate.enabled` and `codex.external_review_gate.enabled` are false.

So requiring a gate a repo has not enabled costs that repo nothing at merge time. What it buys is that the *enabling* of the gate is a one-line config change rather than a config change plus a branch-protection change that someone has to remember. The failure mode this closes is precisely the one #774 found: a repo turns a gate on, the gate works, and the gate is advisory — because the protection half was never done.

`Label Gate` and `Self-Review Required` have no knob and are unconditional in every repo that receives the workflows, so requiring them is not a posture question at all: without them, the label-based merge block that `docs/agents/shared-operating-rules.md` and `REVIEW_POLICY.md` describe as a hard gate is decoration.

### Repo classes

The posture is uniform, but the *reasons* differ by class, and so does the blast radius of adopting it.

**Hub (`mergepath`).** The hub authors the gates, so a hub whose own protection does not require them cannot claim they are enforced anywhere. The hub additionally needs `enforce_admins: true`: the two escapes that motivated the merge-clearance gate (#427/#428) were both admin merges, and a required check is bypassable by an admin "merge without waiting for requirements". That requirement is audited, not merely stated: the fleet loop passes `--require-admin-enforcement` for the hub and no other repo, so a hub that lists all five canonical checks while leaving admins unconstrained is DRIFT rather than PASS. Under rulesets the equivalent posture is an empty bypass list, since a ruleset has no `enforce_admins` field and anyone in `bypass_actors` merges past its required checks. GitHub enforces classic protection and every applicable ruleset simultaneously rather than as alternatives, so the audit answers both halves of the posture over the union of the two surfaces: a canonical check counts as required if *either* surface requires it, and counts as skippable only when *every* source that requires it also allows a bypass — one unbypassable source keeps the gate shut for everybody. That posture has to be auditable by a **read-only** token, which constrains how it is checked: GitHub returns `bypass_actors` only to a caller with write access to the ruleset, so the audit reads `current_user_can_bypass` — which read-only callers do receive — after confirming from `GET /repos/{owner}/{repo}` `.permissions.admin` that the auditing identity is a repository admin. Under rulesets nobody bypasses implicitly (unlike classic protection, where every admin does until `enforce_admins` is set), so `never` from a confirmed admin is genuine evidence that the admin role is not in the bypass list. The decision **not** to buy the full list by granting the audit token `Administration:write` is deliberate: a weekly, unattended, fleet-wide credential that can rewrite branch protection is a worse exposure than the drift it would detect, and the narrower read still answers the #427/#428 question this ADR is about. Where a token *does* hold write access the full `bypass_actors` list is used instead, because it also catches a bypass actor that is not the auditing identity — the one gap the read-only signal cannot see, and which the audit states in its own output rather than papering over. Adopting `Merge clearance gate` on the hub has immediate blast radius on in-flight work — every open PR gains a new required check, and any Phase-4 PR without current-head clearance blocks until cleared — so it should be done when the PR queue is quiet, not mid-wave.

**Consumers.** A consumer receives the gate workflows through propagation whether or not it has enabled the corresponding knobs, so the workflows are already running there. The only thing the protection change adds is that their verdicts count. Two consumer-specific notes:

- Whichever consumer is the **canary for a given wave** carries that wave's audit on its verdict, so it has the strongest case of any consumer for being gated, not the weakest — and since the canary is chosen per wave by the dominant risk of the change ([propagation-ordering.md](../agents/propagation-ordering.md)), any consumer can hold that role. That is an argument for gating **all** consumers rather than for gating one named repo. (`swipewatch` is the documented **ESLint** canary specifically; that is one axis, not a standing propagation-wave appointment.)
- `matchline` additionally requires zero approving reviews. That is orthogonal to the five checks and is not decided here; #774 tracks confirming it is intentional.

**Ordering constraint, not an exception.** GitHub only offers a check name in the required-checks dropdown once that workflow has run at least once in the repo. The three repos with no protection therefore need a PR to land first before their checks can be required. That is a sequencing constraint on *how* the posture is adopted, not a class of repo that is exempt from it.

### Exceptions

A repo that intentionally differs must record the exception in this file, with the repo, the check, and the reason. An undocumented difference is drift by definition — the audit cannot tell "we decided this" from "nobody noticed", which is the whole reason this record exists.

No exceptions are recorded at this time.

## Enforcement

Conformance is audited automatically. `.github/workflows/branch-protection-audit.yml` runs `scripts/audit-branch-protection.sh --fleet` every Monday at 08:30 UTC across the hub and every consumer in `.mergepath-sync.yml`, and opens or updates a single rollup issue labelled `branch-protection-drift` in this repository when any repo falls short. A clean audit closes that issue. Each repo is audited on its own default branch, resolved per repo from `GET /repos/{owner}/{repo}` — the posture above is stated in terms of a repo's default branch, so a fleet-wide hard-coded `main` would inspect a branch a renamed or `master`-defaulted repo may not even have and file the miss as drift.

The audit is read-only. It never calls a protection-mutating endpoint, so adopting this posture stays a deliberate human action; the automation only removes the ability for a lapse to go unnoticed.

An off-schedule run is triggered with a `repository_dispatch` of type `branch-protection-audit`, not `workflow_dispatch`. The audit reads protection under an admin-scoped PAT (`BRANCH_PROTECTION_AUDIT_TOKEN`), and `workflow_dispatch` lets the dispatcher choose the ref whose workflow *definition* runs — so any in-file guard against a non-default ref sits in the file the dispatcher can rewrite. `repository_dispatch` has no ref parameter and always runs the default-branch definition.

Three properties of that automation are load-bearing and are covered by `tests/test_audit_branch_protection.sh` and `tests/test_audit_branch_protection_workflow.sh`:

- an unreadable repo exits 2 (infrastructure) rather than 3 (drift), and the workflow fails on 2 without touching the rollup issue. Reading branch protection needs the `Administration:read` scope, which reviewer PATs lack — so a token that loses that scope 403s uniformly across the fleet, and the wrong classification would present that as either a clean audit or a fleet with no findings. A repo whose default branch cannot be resolved is classified the same way, for the same reason;
- the rollup issue body is assembled findings-first, with the compact per-repo verdict table in whole and the verbose output truncated under a byte budget. A rollup that lets GitHub's body cap eat findings under-reports exactly when the fleet is at its worst;
- the rollup issue is maintained by a read-then-write pair (look up the open issue, then create or update it), so the workflow serializes its runs under a concurrency group and treats a failed lookup as a job failure rather than as "nothing is open". Both shortcuts would break the single-rollup guarantee: concurrent runs would open duplicates, and a lookup error on a clean run would silently leave a genuine drift issue open.

### Provisioning `BRANCH_PROTECTION_AUDIT_TOKEN`

The audit cannot run at all until this secret exists, and it is deliberately not something the repository can provision for itself: minting a credential is an owner action. Every run of the workflow between the day it landed and the day the secret is set aborts at its preflight guard, which is correct — a guard that refused to run is the only honest alternative to an audit that reports a fleet-wide all-clear it never verified (#989).

What the owner must create:

1. **A fine-grained PAT, read-only.** The only permission it needs is `Administration: read`, granted on this hub and on every repo listed in `.mergepath-sync.yml`. Do not grant `Administration: write`: this is a weekly, unattended, fleet-wide credential, and write would give it the power to rewrite the exact protection it exists to audit — strictly worse than the drift being detected. The audit never calls a protection-mutating endpoint, so write buys nothing.
2. **Under an identity that is a repository admin on the hub.** The hub's admin-enforcement check (see § Enforcement above) reads `current_user_can_bypass`, because GitHub withholds a ruleset's full `bypass_actors` list from a read-only caller. That field describes the *calling* identity, so it is evidence about admins only when the caller is one — a non-admin identity makes the audit exit 2 (unreadable) rather than report clean. In practice this is the author identity `nathanjohnpayne`, not a reviewer identity.
3. **Stored in 1Password alongside the other machine PATs**, looked up by item ID rather than item title, per the PAT lookup table in `REVIEW_POLICY.md`.
4. **Installed as the `BRANCH_PROTECTION_AUDIT_TOKEN` Actions secret** on `nathanjohnpayne/mergepath` — Settings → Secrets and variables → Actions → New repository secret. If installing it from the CLI, guard the value against being unset, because an empty secret still exists, still bumps `updated_at`, and is indistinguishable from a populated one on the Settings page — an empty write is precisely the failure mode that produced #989:

   ```bash
   : "${BP_AUDIT_PAT:?refusing to write an empty BRANCH_PROTECTION_AUDIT_TOKEN}"
   printf '%s' "$BP_AUDIT_PAT" | gh secret set BRANCH_PROTECTION_AUDIT_TOKEN --repo nathanjohnpayne/mergepath
   ```

5. **Verify off-schedule rather than waiting a week**, with `gh api repos/nathanjohnpayne/mergepath/dispatches -f event_type=branch-protection-audit`, and confirm the run reaches a verdict instead of aborting at the preflight guard.

The reviewer PAT (`REVIEWER_ASSIGNMENT_TOKEN`) is not a substitute and pointing the workflow at it is not a fix: it lacks `Administration:read` and 403s on every repo (#177, #285). Because that failure is uniform across the fleet, it is the one most easily mistaken for "nothing to report", which is why the workflow classifies an unreadable repo as exit 2 (infrastructure) and never as exit 0.

## Alternatives considered

**Per-consumer opt-in — require only the gates a repo has enabled.** Rejected. It makes the protection posture a function of a config file that changes independently, so every knob flip silently creates a new gap and there is no single moment at which anyone is prompted to close it. It also produces a fleet where the audit's expected set differs per repo, which means a drift report has to be interpreted rather than read.

**Narrow the canonical set to the two unconditional gates** (`Label Gate`, `Self-Review Required`) and treat the three optional ones as per-repo. Rejected for the same reason, and because it inverts the risk: the three optional gates are the ones guarding the highest-consequence merges (Dependabot without an approval on HEAD, external-review PRs without current-head clearance), and they are free to require while off.

**Leave the posture implicit and rely on the audit alone.** Rejected — that is the state #774 documents. The audit was correct for months; nothing ran it, and nothing said what it was auditing *against*, so its output had no standing to be acted on.

## Consequences

- The audit will report drift on all ten repos every Monday until the settings change lands. That is intended and should not be silenced by relaxing the canonical set.
- Adding `Merge clearance gate` to the hub's required checks will block in-flight Phase-4 PRs that lack current-head clearance until they are cleared.
- A new canonical gate added to `CANONICAL_REQUIRED_CHECKS` becomes required fleet-wide by this decision. Adding one is therefore a fleet-wide protection change and should update this record in the same PR.
- Until `BRANCH_PROTECTION_AUDIT_TOKEN` is provisioned (see § Provisioning above), the audit reaches no verdict at all and the fleet's protection posture is unverified. Every such run fails at its preflight guard and says so on the run page; none of them is a clean result, and none of them can close an open rollup issue.
