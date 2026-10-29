# Runbook: the `dependabot-reviewer` environment

Owner-performed. Agents create no environments, secrets, tokens or settings; they run the read-only checks below and report.

This runbook sets up the credential that approves Dependabot pull requests, per [#2729](https://github.com/nathanjohnpayne/mergepath/issues/2729) and rows C13 and C14 of [ADR 0004](../architecture/0004-trusted-privileged-jobs.md). It implements the owner's [option 1 decision](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330037781) on #2718, as [corrected](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330518903).

## What the workflow now expects

`.github/workflows/dependabot-auto-merge.yml` runs two jobs on `pull_request_target`:

| Job | Environment | Secret | Uses it for |
|---|---|---|---|
| `approve` | `dependabot-reviewer` | `DEPENDABOT_REVIEWER_TOKEN` | Two calls only: `GET /user` (the identity must be in `available_reviewers` or `dependabot_reviewer_identities` and must not be the PR author) and the `APPROVE` review bound to the head's `commit_id` |
| `merge` | `merge-queue-policy` | `AUTHOR_MERGE_TOKEN` | Unchanged: the identity check and the merge calls ([#2728](https://github.com/nathanjohnpayne/mergepath/issues/2728) owns this token) |

Every other call in both jobs runs under `GITHUB_TOKEN`. Both jobs run only when the PR's base is the default branch, which makes their `pull_request.base.sha` checkout a default-branch commit. Each job also re-reads the live base before it writes, so a PR retargeted after the event is neither approved nor merged.

The `approve` job reads the approval back before reporting it, and the `merge` job re-reads it on the exact head before the CI wait and before each merge path. A moved head ends the run without merging; the run for the new head takes over.

Two behaviour changes from the single-job workflow:

- **Approval before the author-token check.** The approval is now posted before the merge job checks `AUTHOR_MERGE_TOKEN`. A missing or wrong author token leaves the PR approved but unmerged, with the error in the `merge` job. The audit trail stays correct; fix the token and rerun.
- **Polling reads on `GITHUB_TOKEN`.** The merge job's CI wait polls under `GITHUB_TOKEN`, whose budget is per repository, where the reviewer PAT's polls used to run. A large Dependabot batch can exhaust it, and the wait then fails closed (`required-head-checks failed closed`). Watch the first batch after rollout, and rerun the failed runs if it happens.

Until a repository's `dependabot-reviewer` environment holds `DEPENDABOT_REVIEWER_TOKEN`, its `approve` job fails with `DEPENDABOT_REVIEWER_TOKEN is unavailable from the dependabot-reviewer environment` and nothing is approved or merged. The workflow never falls back to `REVIEWER_ASSIGNMENT_TOKEN`: the new secret name is what makes a missing copy fail closed instead of silently reading the shared repository secret.

## Residual risk (accepted)

The token is a **classic** PAT on a reviewer account. GitHub does not confine a classic PAT to one job, one repository or Dependabot approvals. A stolen copy reaches every repository the reviewer account can access, within the token's scopes. The dedicated name, the single job and the environment reduce **exposure** (fewer places the token is loaded) and allow rotating or revoking it on its own. They do not shrink its **blast radius**. The owner accepted this residual with option 1. Since [#2874](https://github.com/nathanjohnpayne/mergepath/issues/2874) the account is `nathanpayne-deps`, which narrows what a stolen copy can **approve**: its review counts only on Dependabot PRs. It is still a write collaborator, so the copy can push branches and post comments on the fleet repositories; branch protection and the Dependabot commit-provenance check (a pushed commit takes a PR out of the Dependabot lane) are what bound that.

Classic is required because reviewer accounts are collaborators on user-owned repositories. A fine-grained PAT cannot contribute to a repository where its user is an outside or repository collaborator (it can still read public ones), and only a classic PAT has write access, which submitting a review needs, to public repositories its user does not own.

Record this paragraph in the 1Password item's notes and in the PAT's GitHub note, so the residual is stated where the token is configured.

## The token

- **Account:** `nathanpayne-deps`, a dedicated Dependabot-only approver ([#2874](https://github.com/nathanjohnpayne/mergepath/issues/2874)). It is a write collaborator on each fleet repository and is listed under `dependabot_reviewer_identities`, never under `available_reviewers`, in each repository's `.github/review-policy.yml` ([REVIEW_POLICY.md § Dependabot-only approver identities](https://github.com/nathanjohnpayne/mergepath/blob/main/REVIEW_POLICY.md#dependabot-only-approver-identities-2874)). Its approval counts on the Dependabot lane only, so a stolen copy of this token cannot clear an agent or human PR, and its approvals are distinguishable from agent reviews. Add the key to a repository's policy before its environment receives this token, or the `approve` job fails closed. Do not use `nathanpayne-robot` (a non-reviewer identity, so the gate fails any PR it approves) or `nathanjohnpayne` (the merge identity).
- **Separate from the reviewer PAT that local sessions read** (1Password item `pvbq24vl2h6gl7yjclxy2hbote`). Issue a new token and store it as a new 1Password item, so it can be rotated or revoked alone. Record the new item's ID, not its title, in [Token record](#token-record).
- **Scopes: `public_repo` only.** All eight fleet repositories were `PUBLIC` in a GraphQL `visibility` read on 2026-10-22 ([inventory](../audits/pipeline-token-callers-2026-10.md), "Private consumers"). `public_repo` covers submitting a pull request review on a public repository; `GET /user` returns the login with any classic scope. No `workflow`, `read:org` or `user` scope is needed. If any fleet repository becomes private, this token needs `repo` instead. Re-issue it, and update this section and the [Token record](#token-record) before that repository's environment receives it.
- **Expiration: none, by owner decision (2026-10-29).** The token was first issued with a 30-day expiry and regenerated without one, so Dependabot approvals never lapse unattended. Nothing therefore forces a rotation: revoke and regenerate it on any suspicion of exposure, when the `nathanpayne-deps` account's access changes, and when this runbook's scope changes. Regenerating keeps the 1Password item; update its value, then re-run the per-repository secret step below. If an expiry is ever set again, a lapsed token fails closed: the `approve` job fails and Dependabot PRs wait.
- **Note on the PAT:** `mergepath dependabot-reviewer: approval job only` plus the residual-risk paragraph above.

## Order: issue before anything is revoked

1. Issue the token and store it in 1Password.
2. In each repository, create the environment and add the secret (next section). Do the hub first. The hub's Dependabot approvals fail closed from the moment this change merges until its environment holds the secret. A consumer is affected only once the workflow propagates to it, so set up each consumer before its propagation PR merges.
3. Verify each repository with the readback below.
4. Prove the run path on the [#2732](https://github.com/nathanjohnpayne/mergepath/issues/2732) pilot consumer ([Event-specific availability](#event-specific-availability)).
5. Only after that, and only under [#2730](https://github.com/nathanjohnpayne/mergepath/issues/2730)'s cutover sequence, retire repository copies of `REVIEWER_ASSIGNMENT_TOKEN`. Other callers still read it until they move to the CI app ([#2727](https://github.com/nathanjohnpayne/mergepath/issues/2727)), so this runbook revokes nothing.

## Per repository

Repositories: `mergepath` (hub), `nathanpaynedotcom`, `friends-and-family-billing`, `overridebroadway`, `swipewatch`, `fiveacross`, `matchline`, `tadlockpsychiatry`, all under `nathanjohnpayne`, each with default branch `main`.

1. **Create the environment** under Settings → Environments → New environment, named exactly `dependabot-reviewer`. If it already exists (GitHub creates an environment with no rules the first time a job names it, so a run before setup leaves one behind), apply the same settings to it:
   - Deployment branches and tags: **Selected branches and tags**, with exactly one rule: branch `main`. No wildcard, no tag rule.
   - **Allow administrators to bypass configured protection rules:** unchecked.
   - No required reviewers, no wait timer.

   The same branch settings can be applied from a shell. Every command here runs as the owner: `GH_TOKEN` names the author account explicitly instead of relying on the keyring's active account.

   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)" && GH_TOKEN="$(gh auth token --user nathanjohnpayne)" gh api -X PUT repos/nathanjohnpayne/<repo>/environments/dependabot-reviewer --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
   ```

   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)" && GH_TOKEN="$(gh auth token --user nathanjohnpayne)" gh api -X POST repos/nathanjohnpayne/<repo>/environments/dependabot-reviewer/deployment-branch-policies -f name=main -f type=branch
   ```

   The `POST` adds `main` and leaves any other branch or tag rule in place. If the environment already has rules, delete every rule other than `main` under Settings → Environments → `dependabot-reviewer` before the readback; the audit reports any remaining rule as drift.

   GitHub's REST reference does not document the administrator-bypass field, so clear that checkbox in the UI. The audit below reads it back either way.

2. **Add the secret** as an environment secret of `dependabot-reviewer`, never as a repository or organization secret:

   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)" && GH_TOKEN="$(gh auth token --user nathanjohnpayne)" gh secret set DEPENDABOT_REVIEWER_TOKEN --env dependabot-reviewer --repo nathanjohnpayne/<repo>
   ```

   With no `--body`, `gh` reads the value from the prompt or stdin. The environment holds nothing else; in particular, never put `AUTHOR_MERGE_TOKEN` or another credential in it, because no job may name two credential environments (ADR 0004).

3. **Read it back.** Run with the owner's token, because reviewer tokens get 404 on environment and secret metadata. The audit requests names and settings only, never values:

   ```bash
   eval "$(/opt/homebrew/bin/brew shellenv)" && GH_TOKEN="$(gh auth token --user nathanjohnpayne)" python3 scripts/audit-credential-isolation.py --repo nathanjohnpayne/<repo> --branch main --environment dependabot-reviewer --expect-secrets DEPENDABOT_REVIEWER_TOKEN
   ```

   `PASS` (exit 0) means:
   - administrator bypass is off;
   - the only deployment rule is branch `main`;
   - the environment holds exactly `DEPENDABOT_REVIEWER_TOKEN`;
   - no required reviewers and no wait timer, either of which would stall the `approve` job;
   - no repository or organization secret shadows it.

   Until #2730 retires the shared repository secrets, the readback also reports `REVIEWER_ASSIGNMENT_TOKEN` and the other repository-scoped authority secrets as drift (exit 3). That drift is expected during cutover and is not about this environment. Any other drift line is a setup error to fix before relying on the environment.

## Event-specific availability

GitHub's [Dependabot on Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions) reference withholds secrets from a Dependabot-initiated `pull_request_target` run only when Dependabot created the PR's base ref. The base-is-default guard rules that case out. That page does not mention environment secrets, so ADR 0004 requires proving that they resolve on such a run before any repository copy goes.

On the pilot consumer, with its environment set up, let a Dependabot patch or minor PR against `main` run the workflow (or rerun the latest run). Record:
- the run URL;
- that the `approve` job logged `Approval <id> by <login> is recorded on <sha>`;
- that the PR's reviews show that approval on that commit.

A failure that says the secret is unavailable while the readback passes means environment secrets do not resolve on Dependabot-initiated runs. If that happens, stop. The workflow then needs ADR 0004's downstream-consumer variant (a default-branch `workflow_run` or `repository_dispatch` job nominated by the credential-free `pull_request_target` run), not a repository secret.

## Token record

Fill in when the token is issued:

| Field | Value |
|---|---|
| Account | `nathanpayne-deps` |
| 1Password item ID | `5zkizdhgekgkhpayhvcfkckn5a` (title `GitHub PAT (dependabot-reviewer-deps)`) |
| Scopes | `public_repo` |
| Issued | 2026-10-29 (regenerated the same day without an expiry) |
| Expires | Never (owner decision; see [The token](#the-token)) |
| Environments holding it | All eight, readback 2026-10-29: environment-only secret, `main`-only rule, administrator bypass off, no reviewers or wait timer, no repository shadow. Remaining drift is only the expected #2730 repository-scoped secrets. |
