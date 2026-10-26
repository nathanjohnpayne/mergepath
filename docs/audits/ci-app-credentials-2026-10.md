# CI app credentials (#2727): specification and owner runbook, 2026-10

[#2727](https://github.com/nathanjohnpayne/mergepath/issues/2727) (parent [#2718](https://github.com/nathanjohnpayne/mergepath/issues/2718)) moves the pipeline's non-standing callers off `CI_ACTOR_TOKEN` and `REVIEWER_ASSIGNMENT_TOKEN` and onto per-job tokens from a non-reviewer CI GitHub App. The governing design is [ADR 0004](../architecture/0004-trusted-privileged-jobs.md) (Accepted); the caller IDs C1 to C26 are the rows of the [caller inventory](pipeline-token-callers-2026-10.md) (#2725). This record specifies the app, states the hosting trade-off with the evidence read on 2026-10-26, splits the migration into slices, and gives the owner the procedure for every step an agent may not perform. Nothing here creates, installs or configures an app, secret, environment or setting; those stay owner-performed.

## Decision: primary or fallback

**Primary: [Octo STS](https://github.com/octo-sts/app).** A trusted job requests `id-token: write`, and Octo STS exchanges the job's GitHub OIDC token for a one-hour, non-renewable installation token under a trust policy committed at `.github/chainguard/<identity>.sts.yaml` on the repository's default branch. No private key is distributed to any repository.

**Fallback: a self-managed GitHub App with a stored key, minted by `actions/create-github-app-token`. Not approved.** It is never an automatic fallback. A failing Octo STS exchange fails closed: the job makes no write. Switching designs needs a recorded owner decision on #2727 that cites #2732 pilot evidence, for example that the exchange cannot be made to work on these repositories, or that the owner rejects both the hosted operator's reach and self-hosting. If the owner approves it, the same caller migration applies, with ADR 0004's custody rules: the key lives only in the `review-automation` environment (custom branch policy, literal `main`, administrator bypass off), only the minting step reads it, every mint passes explicit `repositories` and `permission-*` inputs, and the residual is stated where the key is configured: anyone holding the key can mint for every installation of the app.

**Pilot evidence: pending [#2732](https://github.com/nathanjohnpayne/mergepath/issues/2732).** The table under [Pilot record](#pilot-record) is the place the evidence goes. The primary choice above is the owner's 2026-10-22 design decision, contingent on that pilot. A pilot failure stops cutover; it does not weaken a control or switch to the fallback.

## Hosting: Chainguard's hosted app or self-hosted

Octo STS is open source and runs either as Chainguard's hosted service (`https://octo-sts.dev`, GitHub App `octo-sts`) or as a deployment the owner runs. The trust policy format, the action and the exchange are the same either way.

Live readback, 2026-10-26, unauthenticated `GET https://api.github.com/apps/octo-sts`: app ID `801323`, owner `octo-sts`, bot login `octo-sts[bot]` (user ID `157150467`). These are the app's **registered** permissions, the set a new installation is asked to accept: Actions write, **Administration write**, Checks write, **Contents write**, Deployments write, Discussions write, Environments write, Issues write, Members write, Metadata read, Organization administration write, Organization API insights read, Organization custom roles and custom organization roles write, Organization events read, Organization projects write, Packages write, Pages write, Pull requests write, Repository projects write, Security events write, Statuses write, **Workflows write**. The project README lists Administration as read-only, while the registered set says write. The effective permissions of a particular installation are not in this response; the owner reads them on the install screen and on the installation's settings page (see [Before the pilot](#before-the-pilot)), and they bound what Octo STS can mint for that installation.

| | Hosted (`octo-sts`, app 801323) | Self-hosted |
|---|---|---|
| Who can mint tokens | Chainguard, as operator of the service and holder of the app key, for every permission the installation holds on every installed repository. Trust policies bound each token a workflow receives, not the operator | The owner only. The key stays in a cloud KMS key, non-exportable, never in GitHub |
| Installation reach | The permission set above, on each selected repository. It includes Administration, Contents and Workflows write, so an operator compromise could change settings and push workflow files, subject to branch protection | Only what the owner registers: Metadata read, Contents read, Pull requests write, Issues read, Checks read, Statuses read, Actions read (the union of ADR 0004's policy table) |
| Bot login in `non_reviewer_identities` | `octo-sts[bot]`, shared by every Octo STS user | `<owner's app slug>[bot]`, exclusive to the fleet |
| `app` pin value | `801323`, if the hosted deployment accepts a numeric pin; the pilot confirms it | The owner's app ID or configured name |
| Cost to run | None | A service deployment (the project ships a Terraform module for Cloud Run and KMS), its upkeep and its upgrades |
| Availability | Chainguard's | The owner's |

**Recommendation.** Run the #2732 pilot on the hosted app, installed on **selected repositories** with only `mergepath` selected, because the mechanism (the emitted `sub`, the claims, default-branch policy reads, refusal of unpinned runs) is what the pilot must prove and is the same on both deployments. Decide hosting for the fleet at the pilot review. Accept the hosted app for the fleet only if the owner accepts an outside operator holding Administration, Contents and Workflows write on all eight repositories; otherwise self-host before rollout. The decision and its date go in the pilot record.

## Identities and trust policies

ADR 0004 § Policies per repository fixes six identities. `scripts/ci/ci_app_trust.py` carries the same table and is the executable form of it:

| Identity | Workflow pinned | `event_name` | `permissions` | Callers |
|---|---|---|---|---|
| `review-mutations` | `trusted-review-mutations.yml` (new) | `workflow_run` | `pull_requests: write` | C2, C4, C5 |
| `policy-mutations` | `trusted-policy-mutations.yml` (new) | `workflow_run` | `pull_requests: write` | C6, C7 |
| `auto-clear` | `auto-clear-blocking-labels.yml` | `workflow_run`, `repository_dispatch`, `schedule` | `contents`, `issues`, `checks`, `statuses`, `actions` read; `pull_requests: write` | C8, C11 |
| `thread-resolution` | `thread-resolution-lane.yml` | `repository_dispatch` | `contents: read`, `pull_requests: write` | C17 |
| `fleet-read-sweep` | the hub's `weekly-feedback-sweep.yml` | `schedule`, `workflow_dispatch` | `pull_requests: read` | C20, only if a fleet repository becomes private |
| `fleet-read-drift` | the hub's `weekly-drift-audit.yml` | `schedule`, `workflow_dispatch` | `contents: read` | C22, C23, same condition |

Every policy is generated, never hand-written:

```bash
scripts/ci/check_ci_app_trust --render review-mutations --repository nathanjohnpayne/<repo> --repository-id <repo_id> --owner-id <owner_id> --app <pin>
```

The output is ADR 0004's template: exact `issuer` and `subject` (name-only, or the immutable `repo:<owner>@<owner_id>/<repo>@<repo_id>` form with `--immutable` if the owner opts a repository in), `repository_id`, `repository_owner_id`, `ref`, `workflow_ref` with every dot escaped, the anchored `event_name` alternation, `runner_environment: github-hosted`, the exact `app` pin and the exact permissions. The IDs are always those of the repository whose workflow presents the token, which is not always the repository that stores the policy. For the four fleet-wide identities they are the storing repository's own, from `gh api repos/nathanjohnpayne/<repo> --jq '.id, .owner.id'`. A `fleet-read-*` policy is stored in each target repository, but the hub's run presents its token, so it carries the hub's IDs (`1190939344`, owner `23488723`) in every repository. The gate pins both values (`HUB_REPOSITORY_ID`, `OWNER_ID`): a policy with another repository's or owner's ID fails `--check`, and `--render` refuses IDs that do not match the presenting repository.

## The gate

`scripts/ci/check_ci_app_trust` runs in repo-lint (`lint-fast` shard 1) on the hub and every consumer. Until a later slice extends it, it enforces:

- **Who may request `id-token: write`.** Only a (workflow, job) pair in `ALLOWED_ID_TOKEN_JOBS`; that list is empty, so any grant anywhere fails today. A workflow-level grant always fails, including `permissions: write-all`. An allow-listed job may trigger only on its identity's events, names no environment and no job-level `container` or `services` image, checks out this repository at `${{ github.workflow_sha }}` with `persist-credentials: false`, uses only SHA-pinned non-local actions, and restores no artifact or cache.
- **Trust policies.** Every file in `.github/chainguard/` must be `<identity>.sts.yaml` for a known identity, and its parsed content must equal the rendered template for this repository. Every policy must pin `APP_PIN`, which is `None` until the pilot records it, so no policy can land before the pilot does.

The gate cannot see what Octo STS itself accepts. Those are pilot items.

## Follow-on events and merge safety, per caller

ADR 0004 hands #2727 two confirmations per caller: that its writes still start the workflows they must, and that merge safety does not depend on the write landing before the consumer hop. The event column below is read from the workflow triggers at `ce80530e`; the merge-safety column is the acceptance item for the slice that moves the caller.

| Caller | Write | Workflows the write must start | Token after cutover | Merge-safety item for its slice |
|---|---|---|---|---|
| C2 | add `needs-external-review` | `labeled` starts `agent-review.yml`, `pr-review-policy.yml`, `merge-clearance-gate.yml` and the `auto-clear` nominator | App `review-mutations` | Show the clearance gate refuses an above-threshold PR during the hop, without the label |
| C3 | request a reviewer | None: no workflow triggers on `review_requested` | `GITHUB_TOKEN` | None; assignment is advisory |
| C4 | add or remove `needs-human-review`, comment | `unlabeled` re-arms readiness in `agent-review.yml` (#620); the comment starts the `issue_comment` gates | App `review-mutations` | Show readiness does not arm on a disagreeing PR during the hop |
| C5 | dismiss a review, add `policy-violation` | `pull_request_review` `dismissed` starts `merge-clearance-gate.yml`, `codex-p1-gate.yml`, `coderabbit-severity-gate.yml` | App `review-mutations` | Confirm the clearance gate's own approval checks (#1080) refuse an ineligible approval before dismissal lands |
| C6 | `DELETE` `needs-external-review` | `unlabeled` re-arms the settle and the Label Gate | App `policy-mutations` | None: removal only ever unblocks |
| C7 | `merge-clearance-recheck` dispatch; label removal | The dispatch starts `merge-clearance-gate.yml` and `required-check-publisher.yml` under `GITHUB_TOKEN` (dispatch is exempt from the no-trigger rule); the removal as C6 | `GITHUB_TOKEN` for the dispatch, app `policy-mutations` for the label | None |
| C8, C11 | `DELETE` a blocking label, comment | `unlabeled` starts `agent-review.yml` and `merge-clearance-gate.yml` | App `auto-clear` | Unchanged; the evaluation already re-derives live state |
| C17 | thread replies, `resolveReviewThread` | Replies create `pull_request_review_comment` events, which start `merge-clearance-gate.yml`, `codex-p1-gate.yml` and `coderabbit-severity-gate.yml`; resolution starts nothing | App `thread-resolution` under `thread_resolution_ci_app_identity` | The resolver hardening in slice 2 |
| C18, C19, C21, C24 | issue and label writes | None needed | `GITHUB_TOKEN` (ADR owner decision 4) | Not a PR mutation |
| C20, C22, C23 | cross-repository reads | None | `GITHUB_TOKEN` for public reads; `fleet-read-*` only if a repository goes private | Not a PR mutation |

## Migration slices

#2727 ships as a sequence of PRs. Each is inert or fails closed until the owner provisions what it needs.

1. **This PR.** The specification and runbook, and the `check_ci_app_trust` gate. No workflow requests `id-token: write` and no policy is committed.
2. **C17 resolver hardening.** `scripts/resolve-pr-threads.sh --resolve-actioned` refuses, failing closed, any PR whose live base ref is not the default branch, captures the live head and base SHAs before evaluating evidence, binds each evidence predicate to that pair, restarts on a change, and re-reads the pair before every `resolveReviewThread`, stopping the run on a mismatch. This hardens the current reviewer-PAT path too, so it does not wait for the pilot.
3. **Trusted consumers.** `trusted-review-mutations.yml` (C2, C4, C5) and `trusted-policy-mutations.yml` (C6, C7) on `workflow_run`, with the `workflow_run` field validation, invariant 9's same-repository admission, exact-head binding, and fork and borrowed-name rejection tests. Their jobs join `ALLOWED_ID_TOKEN_JOBS`. They make no write until a policy exists, because the exchange fails without one; the producers keep their current writes until cutover.
4. **Auto-clear split.** The `pull_request_target` path becomes the credential-free nominator, and evaluation runs on `repository_dispatch`, `workflow_run` and `schedule` with the `auto-clear` identity. This slice extends the gate's event rule for a mixed-trigger file, with its own review.
5. **Pilot (#2732).** Records the evidence below, sets `APP_PIN`, commits the hub's policies, and adds the bot login to `non_reviewer_identities` and `thread_resolution_ci_app_identity`.
6. **Cutover (#2730 sequences it).** Each caller switches to its token in the table above. C3, C18, C19, C21 and C24 move to `GITHUB_TOKEN`. A gate then fails any read of `REVIEWER_ASSIGNMENT_TOKEN` or `CI_ACTOR_TOKEN` outside the Dependabot approval job, which is the acceptance check.

## Owner runbook

Every step here is owner-performed. Agents prepare and verify; they do not execute these.

### Before the pilot

1. Decide the pilot hosting (recommended: hosted, for the pilot only). Record it on #2732.
2. Install the app on `nathanjohnpayne/mergepath` only. Hosted: `https://github.com/apps/octo-sts/installations/new`, choose **Only select repositories**, select `mergepath`. Self-hosted: register the app with the permission set in the hosting table, deploy the service, then install it the same way.
3. Verify the installation on its settings page (`https://github.com/settings/installations`, then **Configure** on the app). Confirm that **Repository access** is **Only select repositories** with exactly `mergepath` listed, and record the permissions the page shows. Post both on #2732. A normal owner `gh` token cannot list an installation's repositories: GitHub documents `GET /user/installations/{installation_id}/repositories` for a GitHub App user access token of that app only, so the settings page is the owner-side record.

### Pilot

The pilot PR, prepared by an agent and merged through review, sets `APP_PIN` and adds the hub's policy for one identity. Merging it is the owner's acceptance of the pin. The pilot then records each row of the table below. A row that fails stops cutover.

### Fleet rollout

1. Decide fleet hosting at the pilot review, citing the pilot record.
2. Install on the remaining seven repositories, or extend the selection.
3. Policies for each repository arrive by propagation PRs, generated with `--render` from each repository's readback IDs.

### Fallback, only if approved

1. Record the decision on #2727, citing the pilot rows that failed or the hosting rejection.
2. Register the app with the minimal permission set, generate its key, and store it as `REVIEW_AUTOMATION_PRIVATE_KEY` in each repository's `review-automation` environment (custom branch policy, literal `main`, administrator bypass off), with the app ID as an environment variable. Never as a repository or organization secret.
3. An agent then switches the exchange step to `actions/create-github-app-token`, pinned to a full SHA, with explicit `repositories` and `permission-*` inputs matching the identity table.

## Pilot record

To be filled by #2732. Each row is mandatory.

| Item | Result | Evidence |
|---|---|---|
| Hosting used for the pilot, and the owner's decision for the fleet | pending | |
| `app` pin value accepted by the deployment, and the bot login every exchange acts as | pending | |
| `sub` a `workflow_run`, `repository_dispatch` and `schedule` run presents; presence of `job_workflow_ref` | pending | |
| `sub` a `pull_request_target` run presents, and its refusal by `event_name` | pending | |
| Refusal of a `pull_request` run, a branch `workflow_dispatch`, an unpinned workflow and a job naming an environment | pending | |
| A policy edited on a non-default branch is ignored | pending | |
| Label add and `DELETE` on a PR under `pull_requests: write` alone | pending | |
| The app reads `refUpdateRule` as a non-admin viewer (#2571) | pending | |
| The app's label, review-dismissal and reply writes start the follow-on workflows in the table above | pending | |
| Cross-repository `GITHUB_TOKEN` reads of public fleet repositories (C20, C22, C23) | pending | |
| OIDC on a `workflow_run` started by a Dependabot-actor run (#2776) | pending | |

## References

- [ADR 0004](../architecture/0004-trusted-privileged-jobs.md), its owner decisions and § Handed to implementation
- [Caller inventory](pipeline-token-callers-2026-10.md) (#2725)
- [#2726](https://github.com/nathanjohnpayne/mergepath/issues/2726): `thread_resolution_ci_app_identity` in `scripts/lib/reviewers-helpers.sh` and `.github/review-policy.yml`
- Octo STS: [README and trust-policy format](https://github.com/octo-sts/app) (read at `24d38617` on 2026-10-26), [`octo-sts/action`](https://github.com/octo-sts/action)
- GitHub: [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc), [`GET /apps/{app_slug}`](https://docs.github.com/en/rest/apps/apps#get-an-app)
