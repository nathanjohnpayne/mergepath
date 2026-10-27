# 0004: Trusted privileged jobs for credentialed CI operations

## Status

**Accepted**, by the repository owner (nathanjohnpayne) for [#2731](https://github.com/nathanjohnpayne/mergepath/issues/2731) (parent [#2718](https://github.com/nathanjohnpayne/mergepath/issues/2718)). The owner [accepted the design direction](https://github.com/nathanjohnpayne/mergepath/pull/2781#issuecomment-6354717389) on 2026-10-23 at `49dbbe8a`, including the recommendations in [Owner decisions requested](#owner-decisions-requested) except number 7: immutable OIDC subjects stay optional pending the #2732 pilot. The owner then [authorized the merge](https://github.com/nathanjohnpayne/mergepath/pull/2781#issuecomment-6426216266) of the final reviewed head `1a1f3bb2`, which includes the review fixes made since `49dbbe8a`; it was adopted on merge of [#2781](https://github.com/nathanjohnpayne/mergepath/pull/2781) on 2026-10-26. The acceptance covers the architecture only: it authorizes no credential changes or fleet rollout, every pilot requirement stays mandatory, and a pilot failure stops cutover rather than weakening a control or silently switching to the stored-key fallback, and the remaining [#1547](https://github.com/nathanjohnpayne/mergepath/issues/1547) exposure stays explicitly open. Nothing here is implemented, and no credential, secret, environment or setting changes with this record. The implementation belongs to [#2727](https://github.com/nathanjohnpayne/mergepath/issues/2727) (CI app), [#2728](https://github.com/nathanjohnpayne/mergepath/issues/2728) (author token) and [#2729](https://github.com/nathanjohnpayne/mergepath/issues/2729) (Dependabot reviewer environment), is proved by the [#2732](https://github.com/nathanjohnpayne/mergepath/issues/2732) pilot and rolled out by [#2730](https://github.com/nathanjohnpayne/mergepath/issues/2730). Creating, moving or deleting credentials and changing settings stay owner-performed.

This record does not pre-empt the owner's parked decision on [#1547](https://github.com/nathanjohnpayne/mergepath/issues/1547) (defer the cutover, park [#2278](https://github.com/nathanjohnpayne/mergepath/pull/2278) and sequence it with [#2129](https://github.com/nathanjohnpayne/mergepath/issues/2129)). [Relationship to #1547 and #2278](#relationship-to-1547-and-2278) states where it depends on that design and where it differs.

## Date

2026-10-22

## Context

The primary input is the caller inventory [`docs/audits/pipeline-token-callers-2026-10.md`](../audits/pipeline-token-callers-2026-10.md) ([#2725](https://github.com/nathanjohnpayne/mergepath/issues/2725)), which lists 26 credentialed callers, C1 to C26, of `AUTHOR_MERGE_TOKEN`, `REVIEWER_ASSIGNMENT_TOKEN` and `CI_ACTOR_TOKEN`. Its findings, verified on 2026-10-22, set the problem:

- **Every authority token is a repository secret.** All three tokens are repository secrets in the hub and in all seven consumers. `merge-queue-policy` holds no secrets, has no deployment branch policy and allows administrator bypass, although the code assumes `AUTHOR_MERGE_TOKEN` is an environment secret there ([#2774](https://github.com/nathanjohnpayne/mergepath/issues/2774)).
- **Exposure belongs to the secret, not to the caller.** Any same-repository branch can add its own workflow and read every repository secret. Changing a caller's trigger removes one path; only an environment that admits nothing but the default branch makes a secret unreadable from a branch.
- **`pull_request_target` and a non-default base.** The inventory states that `pull_request_target` runs the PR base branch's definition. That was GitHub's behaviour before 2025-12-08. Since then, per GitHub's [changelog of 2025-11-07](https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/) and the current [events reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows):
  - the workflow file and checkout commit always come from the default branch, and `GITHUB_REF` is the default branch;
  - environment rules evaluate `pull_request_target` against the default branch, and `pull_request`-family events against `refs/pull/N/merge`.

  The definition route is therefore closed. What remains is content a job reads from the base branch itself: C13 and C14 check out `pull_request.base.sha` with no guard that the base is the default branch (inventory open question 16). This record designs to the current behaviour; correcting the inventory is a separate follow-up.
- **`workflow_dispatch` runs the dispatcher-chosen ref.** C18 to C26 carry in-file default-branch guards that bind only an unmodified copy.
- **C4 runs candidate code under the PAT.** `detect-disagreement` checks out the merge ref, `require`s `scripts/disagreement-detector.cjs` from it and installs `js-yaml` at run time. [#2775](https://github.com/nathanjohnpayne/mergepath/issues/2775) fixes this in parallel; this record assumes its fixed shape (default-branch helpers, no run-time package resolution).
- **Dependabot-actor runs are unclear.** What C1, C4, C6 and C7 receive and do on Dependabot-actor runs is open in [#2776](https://github.com/nathanjohnpayne/mergepath/issues/2776).

The #2718 split decides *which* credential each caller gets: a non-reviewer CI GitHub App (Octo STS primary, stored-key app as an owner-approved fallback only), a dedicated Dependabot reviewer PAT (the [option 1 decision](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330037781)), and per-repository fine-grained `nathanjohnpayne` author PATs. The [independent assessment](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330473158) and the [corrections](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330518903) add that moving secrets is not enough: credentials must never share an execution context with candidate code. This record decides *where* each credential may be used.

## Decision

Nine invariants. Every credentialed caller in the fleet satisfies all of them after cutover.

In them, an **authority credential** is an environment secret or a CI app token (from Octo STS, or from the stored-key fallback). The job's implicit `GITHUB_TOKEN`, limited by that job's `permissions:`, is not an authority credential. Under the stored-key fallback, the app private key and the installation token minted from it are **one credential lineage**, which counts once. Only the minting step reads the key, and the token is then passed to its consuming steps through `env:` in the same job, never through job outputs. No job holds a second lineage.

1. **No authority credential is a repository or organization secret.** Each lives only in an environment whose deployment branch policy admits exactly the default branch, or is minted at run time by Octo STS and never stored.
2. **Candidate-triggered workflows are authority-free.** A workflow triggered by `pull_request`, `pull_request_review` or `pull_request_review_comment` references no secret and declares no `id-token: write`. Its native required verdicts stay where they are, and its credentialed mutations move. Its existing `GITHUB_TOKEN` writes (the `github-actions[bot]`-owned fail-closed label, comment and propagation marker in `pr-review-policy.yml`, and the workflow-level grants in `agent-review.yml`) are not authority credentials under this record. For a same-repository PR they give no more than the pusher already has, and C6's label-owner fence depends on that ownership. Making those workflows fully read-only stays #1547's Security Cloud acceptance item, unchanged here.
3. **Credentialed jobs run only trusted definitions.** The trigger is one of:
   - `workflow_run`, `repository_dispatch` or `schedule` (default-branch definitions);
   - `pull_request_target` (a default-branch definition since 2025-12-08), with an in-file guard that the PR's base is the default branch wherever the job reads base-branch content;
   - `workflow_dispatch`, limited to the default branch by the credential's own admission rule, never by an in-file guard alone.
4. **Credentialed jobs execute nothing candidate-controlled.** See [Execution rules](#execution-rules-for-credentialed-jobs).
5. **Every mutation binds to the exact current head.** Event payloads, run associations, dispatch payloads and producer outputs are untrusted nominations: a PR number and, where the event carries one, a head SHA. The job re-derives the live PR and refuses unless its base ref is the default branch and its head equals the nominated head. It captures the live head and base SHAs and repeats that pair check and the existing writer fences immediately before each write.
6. **One authority credential per job, plus the implicit `GITHUB_TOKEN`.** A job may use at most one authority credential, alongside its own `GITHUB_TOKEN`. A job that needs two authority credentials becomes two jobs, passing only a PR number and head SHA between them, each re-verified. A job can name only one environment, so this also keeps the author and reviewer PATs in separate environments.

   **One bounded exception: the dormant #1058 queue-boundary classifier.** In C9, C10 and C12, `scripts/workflow/approval-merge-continuation.sh` calls `scripts/workflow/merge-queue-arm-policy.sh`. That script requires the author token, `MERGE_QUEUE_POLICY_TOKEN` and `MERGE_QUEUE_SOURCE_TOKEN` together, and proves them pairwise value-distinct and each the governing author, before it classifies an armed PR. All three are R-107's exact-three `merge-queue-policy` credentials, so that job binds those three from that one environment and nothing else. While the queue tokens stay unprovisioned, the classifier returns its unknown-boundary result (exit 3), and continuation refuses to mutate any arm. That is today's behaviour, not a new one. No other job may bind more than one authority credential.
7. **The CI app's token is used only for event-producing writes and the reads that need its viewer.** Other reads and writes that need no follow-on workflow use the job's `GITHUB_TOKEN`.
8. **`id-token: write` is granted per job, on an allowlist.** Only the trusted jobs that exchange for an Octo STS token request it. Each Octo STS trust policy pins the exact subject and the calling workflow file, so a token request from any other run is refused.
9. **Trusted PR consumers admit only same-repository PRs (C2 to C7).** GitHub documents that a workflow started by `workflow_run` "is able to access secrets and write tokens, even if the previous workflow was not" ([events reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)). Without this rule, a fork PR's read-only producer run could nominate a privileged mutation. Before any token exchange or mutation, each consumer job therefore:
   - requires `github.event.workflow_run.head_repository.id` to equal `github.event.workflow_run.repository.id` and the running repository's `github.repository_id`, as a job-level `if:` so a fork-nominated job never starts;
   - re-requires, after reading the live PR, that its `head.repo.id` equals its `base.repo.id`.

   A null or absent head repository fails the check, and a failed check exits without exchanging a token or writing. Fork PRs therefore keep today's behaviour of no credentialed mutation. Mutating fork PRs would need a new owner decision and its own design.

## Trusted triggers and their admission

Environment deployment rules match the run's `GITHUB_REF`, and Octo STS matches the OIDC `sub` and claims. Both therefore depend on the event, not on what the job checks out:

| Event | Definition runs from | `GITHUB_REF` | Admitted by a `main`-only environment | Default OIDC `sub` (job without an environment) | Use in this design |
|---|---|---|---|---|---|
| `pull_request`, `pull_request_review` | candidate merge ref | `refs/pull/N/merge` | No | `repo:<owner>/<repo>:pull_request` for `pull_request` (documented); never a `refs/heads/main` subject | Read-only producers only |
| `pull_request_target` | default branch (since 2025-12-08) | default branch | Yes, whatever the PR's base | Not documented by GitHub, and possibly the same `…:ref:refs/heads/main` subject as a trusted run | Existing three workflows only; environment PATs, no OIDC exchange |
| `workflow_run` | default branch | default branch | Yes | `repo:<owner>/<repo>:ref:refs/heads/main` | Trusted PR consumers |
| `repository_dispatch` | default branch | default branch | Yes | as above | Nominated evaluations |
| `schedule` | default branch | default branch | Yes | as above | Sweeps and reports |
| `workflow_dispatch` | dispatched ref | dispatched ref | Only when dispatched on `main` | `repo:<owner>/<repo>:ref:refs/heads/<dispatched>` | Manual runs; a branch dispatch reaches no credential |

The fleet repositories were created before 2026-07-15, so they emit the name-only `sub` shown unless the owner opts them into GitHub's [immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc), which produce `repo:nathanjohnpayne@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main`. When a job names an environment, the `sub` becomes `repo:<owner>/<repo>:environment:<name>` and loses the ref. So no job that exchanges for an Octo STS token names an environment: it holds no stored secret, and its `sub` must keep the ref.

The `main`-only rule rejecting `pull_request` refs is the intended effect. No environment ever admits `refs/pull/*/merge`.

## Execution rules for credentialed jobs

These rules apply to the whole of any job that names an environment holding a secret or that declares `id-token: write`. Every step of such a job can reach the credential: environment secrets resolve in any step, and the runner gives every step of an `id-token: write` job the OIDC request URL and token. So an earlier step that ran untrusted code could use the credential later in the job or tamper with the workspace.

- **Checkout** is the default branch at `github.workflow_sha`, the commit the running definition came from, with `persist-credentials: false`. The one exception is a `pull_request_target` job that already checks out `pull_request.base.sha` (C13, C14). It may keep doing so behind its base-is-default guard, because the base SHA is then a default-branch commit. That guard is an exact, case-sensitive shell comparison in the job's first step, before the checkout: Actions `==` ignores case, so a job-level `if:` alone admits a branch named `Main` (#2823). Never `refs/pull/*`, the PR head SHA (on `workflow_run` that includes `github.event.workflow_run.head_sha`, which is the candidate's head, not a default-branch commit), the base SHA of a non-default base, or a dispatcher-chosen ref.
- **No candidate code.** Nothing from the PR's tree is executed, `require`d, `source`d or imported. PR bodies, titles, file lists, diffs and review text are data, parsed only by trusted parsers (`scripts/lib/pr-body-contract.mjs` in a bounded subprocess, as today).
- **No run-time-resolved dependencies.** No `npm install` or `pip install` without a committed lockfile and integrity check (`npm ci`, `pip --require-hashes`), anywhere in the job. Prefer the YAML readers the other jobs already use.
- **No local actions.** No `uses: ./…`. Third-party actions stay pinned to full commit SHAs, as today.
- **No artifacts or caches.** No `actions/download-artifact` and no cache restore (including `setup-*` caches). A `workflow_run` consumer re-derives everything from the API. A workflow anywhere can name itself `Agent Review Pipeline`, and `workflow_run` matches by name, so the triggering run's artifacts, head branch and conclusion prove nothing.
- **Credentials stay in step scope.** Pass a token through `env:` to the steps that use it, never through `$GITHUB_ENV`, `$GITHUB_OUTPUT` or job outputs. Keep the existing fail-closed checks on empty or wrong-identity tokens.
- **Exact current head.** Every consumer takes only a PR number, and a head SHA where the event carries one, as a nomination. It reads the live PR, requires it open with base `main` and its head equal to the nominated head, captures the live head and base SHAs, and repeats that pair check immediately before each write. Approvals keep `commit_id`, merges keep `--match-head-commit`, and label removals keep the existing live head, base and label-owner fences. A mismatch is a no-op, not a failure: the newer head's own run evaluates it.

## Credential sources and environment layout

| Credential | Source | Environment | Branch policy | Admin bypass | Readers |
|---|---|---|---|---|---|
| CI app token (primary) | Octo STS exchange of the job's OIDC token, one hour, per job | None (no stored secret; see above) | Enforced by the trust policy's exact `sub` and claims | Not applicable | Trusted consumers, auto-clear label jobs, thread resolution |
| CI app private key (fallback only, if the owner approves it in #2727) | Stored key, minted with `actions/create-github-app-token` and explicit `repositories` and `permission-*` | `review-automation`, the [#2278](https://github.com/nathanjohnpayne/mergepath/pull/2278) name, holding only `REVIEW_AUTOMATION_PRIVATE_KEY` (app ID as a variable) | Custom, branch `main` only | Disabled | Token-minting steps only |
| `AUTHOR_MERGE_TOKEN`, fine-grained per repository (#2728) | Owner-set from 1Password | `merge-queue-policy`, where R-107 and `scripts/lib/merge-queue-protection.sh` expect it. Their exact-three contract (`AUTHOR_MERGE_TOKEN`, `MERGE_QUEUE_POLICY_TOKEN`, `MERGE_QUEUE_SOURCE_TOKEN`) is not met while the queue tokens stay unprovisioned. The validator runs only on the dormant queue paths, so provisioning the queue tokens belongs to queue activation, not to this record | Custom, branch `main` only | Disabled | Continuation jobs (C9, C10, C12), the Dependabot merge job (C14), and C15 and C16 if kept |
| `DEPENDABOT_REVIEWER_TOKEN`, a new dedicated classic reviewer PAT (#2729) | Owner-set from 1Password | `dependabot-reviewer`, holding nothing else | Custom, branch `main` only | Disabled | The Dependabot approval job (C13) only |

Notes on the layout:

- **Use "Selected branches and tags" with the literal name `main`**, not "Protected branches only", which admits any protected branch. Add no tag rules, required reviewers or wait timers (they would stall automation, and the merge-queue contract forbids reviewers and wait timers). [GitHub's environment reference](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) documents both options and the administrator-bypass control.
- **An environment is not a workflow allowlist.** Any workflow on `main` can name it. The trust root is therefore the reviewed content of `main`, whose `.github/**` paths are already Phase 4 (`external_review_paths`).
- **New secret name for the Dependabot PAT.** A job that names an environment resolves `secrets.X` from the environment when it holds `X` and silently from the repository otherwise. A new name means a missing environment copy fails closed (the job already exits on an empty token) instead of falling back to the shared `REVIEWER_ASSIGNMENT_TOKEN` repository secret during cutover.
- **The author token keeps its name** because the merge-queue topology validator requires it. To close the same silent fallback, #2728 should make the author jobs require the fine-grained `github_pat_` prefix: `scripts/lib/credential-class.sh` classes both `ghp_` and `github_pat_` as `user-held`, so the shared classic token would otherwise pass. Until every repository copy is removed, that check is what makes a fallback fail closed.
- **Separate environments for each credential**, as #2731 requires: the app key (fallback only), the author token and the Dependabot reviewer PAT never share an environment, and no job names two.

`BRANCH_PROTECTION_AUDIT_TOKEN` and `OP_SERVICE_ACCOUNT_TOKEN` are outside #2718's scope and unchanged here. The per-secret exposure rule applies to them too; #2278 already assigns them `branch-protection-audit` and `onepassword-proof`.

## Octo STS trust policies

GitHub issues an OIDC token to any job that requests `id-token: write`, including PR-triggered runs, so each trust policy must pin the trusted caller exactly. Octo STS reads policies from `.github/chainguard/<identity>.sts.yaml` in the scoped repository; patterns are regular expressions matched against the whole value ([Octo STS](https://github.com/octo-sts/app)). Its README does not say which branch policies are read from. The #2732 pilot must show that a policy edited on a non-default branch is ignored before the design relies on it.

Every policy follows this template. Only the repository, IDs, workflow file, events and permissions vary:

```yaml
issuer: https://token.actions.githubusercontent.com
# Exact: the form this repository emits (name-only today; the immutable
# repo:nathanjohnpayne@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main form
# if the owner opts in). Never subject_pattern.
subject: repo:nathanjohnpayne/<repo>:ref:refs/heads/main
claim_pattern:
  repository_id: "<repo_id>"
  repository_owner_id: "<owner_id>"
  ref: refs/heads/main
  workflow_ref: nathanjohnpayne/<repo>/\.github/workflows/<file>\.yml@refs/heads/main
  event_name: (workflow_run|repository_dispatch|schedule)
  runner_environment: github-hosted
# Exact pin to the one app this design uses: its numeric ID (or its configured
# name on a self-hosted deployment). Never app_pattern.
app: "<app_id>"
permissions:
  # the minimum for that workflow's credentialed jobs; see the table below
```

- **`subject` is exact.** A `pull_request` run (`…:pull_request`), a branch push or branch dispatch (`…:ref:refs/heads/<branch>`) and any job that names an environment (`…:environment:<name>`) all fail it. No policy uses `subject_pattern` or a wildcard over refs or repositories.
- **`workflow_ref` pins the calling workflow file**, so another workflow on `main` cannot use the policy.
- **`job_workflow_ref` is left out of the template.** GitHub documents it only for jobs in a [reusable workflow](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-with-reusable-workflows), and every caller here is an ordinary job, so requiring it could fail every exchange. The pilot records whether it is present. A policy adds it only if a caller moves into a reusable workflow, where it must pin the called file.
- **`event_name` is load-bearing.** A `pull_request_target` run's `GITHUB_REF` is the default branch, and GitHub does not document its OIDC subject, so it may present the same `…:ref:refs/heads/main` subject as a trusted run. The `event_name` pattern is what keeps such a run, and a `main` `workflow_dispatch` where none is intended, out of each policy. The pilot records the subject a `pull_request_target` run actually presents.
- **`app` pins one GitHub App.** An unpinned exchange in a multi-App Octo STS pool is load-balanced across that pool's installations, and a pin fails closed instead of re-routing ([Octo STS app pinning](https://github.com/octo-sts/app/blob/main/README.md#app-pinning-trust-policy-app--app_pattern)). Without the pin, successive tokens could act as different bot logins. That would break the single-login contract of `thread_resolution_ci_app_identity` (`scripts/lib/reviewers-helpers.sh`), and every possible login would also need to be in `non_reviewer_identities`. Every policy therefore sets `app` to the same exact value, never `app_pattern`.
- **`repository_id` and `repository_owner_id`** stop a recycled name from matching while the name-only subject format is in use.
- **OIDC claims cannot name a job.** The granularity of a policy is therefore the workflow file, and its `permissions` are the union for that file's credentialed jobs. Jobs in the same file that need no token do not get `id-token: write`, which the [lint below](#who-may-request-id-token-write) enforces.

### Policies per repository

Each repository in the fleet carries the first four policies (eight repositories, 32 files), because all four workflows are propagated fleet-wide. They are generated from one template with that repository's name and IDs. The last two exist only if the condition in their rows holds. For those two, the policy file lives in the target repository, but `subject`, `repository_id`, `repository_owner_id` and `workflow_ref` all carry the hub's values, because the hub runs the workflow that presents the token. Each pins one workflow file, because `workflow_ref` names one.

| Identity | Workflow pinned | `event_name` | `permissions` | Callers |
|---|---|---|---|---|
| `review-mutations` | `trusted-review-mutations.yml` (new; `workflow_run` of `Agent Review Pipeline`) | `workflow_run` | `pull_requests: write` | C2, C4, C5 (C3 uses `GITHUB_TOKEN` unless #2727 finds a follow-on dependency) |
| `policy-mutations` | `trusted-policy-mutations.yml` (new; `workflow_run` of `PR Review Policy`) | `workflow_run` | `pull_requests: write` | C6, C7 |
| `auto-clear` | `auto-clear-blocking-labels.yml` | `workflow_run`, `repository_dispatch`, `schedule` | `contents: read`, `pull_requests: write`, `issues: read`, `checks: read`, `statuses: read`, `actions: read` | C8, C11 |
| `thread-resolution` | `thread-resolution-lane.yml` | `repository_dispatch` | `contents: read`, `pull_requests: write` | C17 |
| `fleet-read-sweep` (only if a fleet repository becomes private, inventory open question 10) | the hub's `weekly-feedback-sweep.yml`, from a policy in each *target* repository whose `subject` is the hub's | `schedule`, `workflow_dispatch` | `pull_requests: read` | C20 |
| `fleet-read-drift` (same condition) | the hub's `weekly-drift-audit.yml`, likewise | `schedule`, `workflow_dispatch` | `contents: read` | C22, C23 |

Permissions come from the inventory's minimum-permission rows, narrowed by invariant 7:

- **PR writes need `pull_requests: write`.** For an installation token, GitHub authorises comment writes on a pull request through `pull-requests`, even on the `issues/{n}/comments` endpoint. `issues: write` alone was measured to fail there (#1163, recorded at `codex-p1-gate.yml` and `required-check-publisher.yml`). The policies therefore grant `pull_requests: write` for every label and comment write on a PR, and no `issues: write`, because no app caller writes to a real issue. The pilot measures label add and `DELETE` under that scope.
- **No `contents: write` in any policy.** The two `repository_dispatch` writes use `GITHUB_TOKEN`, as `required-check-publisher.yml` already does for `auto-clear-evaluate`. GitHub exempts `repository_dispatch` from the rule that `GITHUB_TOKEN` events start no runs. The job's `GITHUB_TOKEN` needs `contents: write` for that, so these two jobs declare it at job level:
  - C7's step in `trusted-policy-mutations.yml`;
  - C8's credential-free nominator in `auto-clear-blocking-labels.yml`.

  Both are default-branch definitions that run no candidate code.
- **Administration is not granted.** The CI actor does not have it today.
- **Auto-clear reads stay under the app token.** `refUpdateRule` is viewer-scoped ([#2571](https://github.com/nathanjohnpayne/mergepath/issues/2571)), so moving those reads to `GITHUB_TOKEN` would change the gate's view. The pilot must show the app reads as a non-admin viewer (inventory open question 3).

The policy files are credential grants. They sit under `.github/**`, so changing one is already a Phase 4 change. The drift audit extended by #2774 should check each against its template.

### Who may request `id-token: write`

- **Allowed:** only the jobs that exchange in the policies table: the two trusted mutation consumers, the auto-clear label jobs on `workflow_run`, `repository_dispatch` and `schedule`, and the thread-resolution job. The hub's sweep and drift-audit jobs join them only if a `fleet-read-*` policy is ever created.
- **Never:**
  - a job in a workflow triggered by a candidate event;
  - a `pull_request_target` job;
  - a job that names an environment;
  - a job that checks out anything but the default branch;
  - any workflow-level `permissions:` block.
- **Enforcement:** a repository lint, in the same family as #2775's regression check, fails when `id-token: write` appears outside this (workflow, job) allowlist. The trust policies refuse such tokens anyway; the lint keeps that refusal from being the only control.

The pilot (#2732) must also record the bot login the pinned app's tokens act as, add it to `non_reviewer_identities` and `thread_resolution_ci_app_identity` ([#2726](https://github.com/nathanjohnpayne/mergepath/issues/2726)), and confirm that its writes start the follow-on workflows each caller needs.

## Caller mapping

Every credentialed row of the inventory, C1 to C26. "App" means the CI app token from the named Octo STS identity (or the fallback minted the same way). Verdicts that are required checks stay in their current authority-free jobs.

| ID | Target trigger and definition | Credential and environment | `id-token` | Exact-head binding | Notes |
|---|---|---|---|---|---|
| C1 `load-config` | Unchanged candidate job (`pull_request`, `pull_request_review`) | `GITHUB_TOKEN` (`contents: read`) for the non-default-base policy reads; no PAT | No | Event base SHA, as today | Same-repository reads need no PAT. Also removes C1 from #2776's empty-token question |
| C2 `triage` label add | Classification stays native; the label add moves to `trusted-review-mutations.yml` (`workflow_run`, default branch) | App `review-mutations` (the job's one authority credential) for the label; the implicit `GITHUB_TOKEN` for reads | Yes (consumer job) | Same-repository admission (invariant 9); `workflow_run.head_sha` equal to the live head, rechecked before the write | The consumer re-runs the classifier from default-branch helpers against the governing base policy and never uses the candidate run's outputs |
| C3 `assign` | Same consumer | `GITHUB_TOKEN` (`pull-requests: write`) | No | As C2, including same-repository admission | The app token only if #2727 shows the request must start a workflow |
| C4 `detect-disagreement` | Detection as fixed by #2775; the label and comment writes move to the consumer | App `review-mutations` | Yes | Same-repository admission; the review's `commit_id` and `workflow_run.head_sha` equal to the live head | Decides from live reviews and the base policy's `available_reviewers` (#975). A deliberate behaviour change: today the job removes `needs-human-review` when agreement returns (`agent-review.yml:1112`). Under R-169 the consumer never removes an existing hold; only a human does |
| C5 `block-self-approval` | Classification in the consumer; dismissal and `policy-violation` label there | App `review-mutations` | Yes | As C4 (including same-repository admission), plus a re-read of the review before dismissal | Dismissal rights depend on protection settings (inventory open question 5). #2727 confirms no merge path depends on the dismissal landing first; the clearance gate's own approval checks (#1080) are the merge control |
| C6 fail-closed label `DELETE` | Verdict stays native; the `DELETE` moves to `trusted-policy-mutations.yml` (`workflow_run`) | App `policy-mutations` | Yes | Same-repository admission; live head and base equal the run's pair; label-owner fence repeated | Keeps the `unlabeled` event that re-arms the settle and Label Gate |
| C7 propagation lane | Same consumer | App `policy-mutations` (the job's one authority credential) for the label removal; the implicit `GITHUB_TOKEN`, with job-level `contents: write`, for the `merge-clearance-recheck` dispatch | Yes | Same-repository admission; live pair fence before each write, as today | The dispatch payload still grants nothing; the gate re-verifies |
| C8 auto-clear gate and `DELETE` | The `pull_request_target` job becomes a credential-free nominator that dispatches `auto-clear-evaluate` with a job-level `contents: write` `GITHUB_TOKEN`. Evaluation runs on `repository_dispatch` and `workflow_run` | App `auto-clear`, no environment | Yes (evaluation job only) | Dispatch payload is a PR number only; captured head and base must equal live values before the `DELETE`, as today | Keeps every existing auto-clear trigger (see [#2733](#compatibility-with-2733)) |
| C9 protective retraction | Moves out of the label job into a continuation job; the `pull_request_target` call site goes with the nominator | `AUTHOR_MERGE_TOKEN` in `merge-queue-policy`, plus the two queue tokens under invariant 6's queue-classifier exception | No | Live PR re-read | Dormant arm path (open question 13) |
| C10 approved-PR continuation | Continuation job, `workflow_run`, default branch | `AUTHOR_MERGE_TOKEN` in `merge-queue-policy`, with the `github_pat_` class check; the two queue tokens only for arm classification, under invariant 6's exception | No | As today (`workflow_run` association or head-SHA match, live snapshot) | Whether it can move to the app with a policy-derived identity pin is #2728's open question 15 |
| C11 scheduled sweep, label part | `schedule`, default branch | App `auto-clear`, no environment | Yes | Live re-derivation and pre-`DELETE` fence, as today | |
| C12 scheduled continuation | Scheduled continuation job | As C10 | No | As C10 | |
| C13 Dependabot approval | `pull_request_target`, job `approve`, `if:` base is the default branch; keeps its `pull_request.base.sha` checkout and base-SHA policy reads, which the guard makes a default-branch commit | `DEPENDABOT_REVIEWER_TOKEN` in `dependabot-reviewer` | No | Provenance re-verified on the live head; `commit_id` approval; read-back of the exact-head approval | The `if:` guard is the base-branch control and fixes open question 16. The environment's `main` rule admits every `pull_request_target` run, so it cannot be that control; it keeps the token away from candidate events and branches. The definition is the default branch's, so the guard binds |
| C14 Dependabot merge | Same workflow, job `merge`, `needs: approve`, same base guard and base-SHA checkout | `AUTHOR_MERGE_TOKEN` in `merge-queue-policy`, with the `github_pat_` class check | No | Re-reads head, labels and approval; `--match-head-commit`; `human-hold` re-read before each merge path | Keeps every safeguard the assessment lists |
| C15 queue authorization (dormant) | Recommend retiring its author-token binding (open question 13). If kept: unchanged trigger | `merge-queue-policy` | No | As today | Its in-file `main` guard binds, because the definition always comes from the default branch |
| C16 queue final audit (dormant) | Recommend retiring, as C15. If kept: unchanged (`repository_dispatch`) | `merge-queue-policy` | No | As today | |
| C17 thread resolution | Unchanged (`repository_dispatch`, default branch) | App `thread-resolution` under the #2726 mode | Yes | `client_payload.pr` digits only. The resolver refuses, failing closed, any PR whose live base ref is not the default branch: the lane's `if:` checks only the dispatch ref, not the PR's base. It captures the live head and base SHAs *before* it evaluates any actioned evidence. Each evidence predicate (reply disposition, ledger row, fix or rebuttal evidence) must then prove that its evidence applies to that captured pair, not merely that the evidence exists; a later head is not automatically invalid. If the pair changes, evaluation restarts against a fresh capture. The pair is also re-read immediately before each `resolveReviewThread`, and a mismatch stops all remaining resolutions for that run, as invariant 5 requires. Today's `scripts/resolve-pr-threads.sh` does none of this, so #2727 adds it before C17 moves to the app | The local reviewer-PAT path is unchanged |
| C18 daily rollup | Unchanged triggers | `GITHUB_TOKEN` with its existing `contents: read` and `issues: write`, plus `pull-requests: read` (open question 9) | No | Not a PR mutation | Loses the agent byline; owner decision below |
| C19 PR audit | Unchanged | `GITHUB_TOKEN` (`issues: write`, `pull-requests: read`) | No | Not a PR mutation | Byline as C18 |
| C20 sweep enumerate (hub) | Unchanged | `GITHUB_TOKEN` for public cross-repository reads, if the pilot shows GraphQL `reviewThreads` reads of other public repositories work with it; otherwise `fleet-read-sweep` | Only with `fleet-read-sweep` | Not a PR mutation | All eight fleet repositories are public (open question 10) |
| C21 sweep render (hub) | Unchanged | `GITHUB_TOKEN` (`issues: write`) | No | Not a PR mutation | `render.sh` already says `GITHUB_TOKEN` suffices |
| C22 drift audit | Unchanged | Anonymous or `GITHUB_TOKEN` public clones and fetches; `fleet-read-drift` only if a consumer goes private | Only with `fleet-read-drift` | Not a PR mutation | |
| C23 propagation-lane audit | Unchanged | `GITHUB_TOKEN` reads, or `fleet-read-drift` as C22 | Only with `fleet-read-drift` | Not a PR mutation | Its self-imposed reviewer-standing gate calls `gh api user` (`scripts/audit-propagation-lane.sh`), which neither `GITHUB_TOKEN` nor an app token can answer. The gate must be removed for the CI run or replaced; owner decision below |
| C24 drift tracking issue | Unchanged | `GITHUB_TOKEN` (`issues: write`) | No | Not a PR mutation | |
| C25, C26 fiveacross stray sweep | Delete the stray workflow, `scripts/sweep-unresolved-feedback/` and `scripts/bootstrap/` from fiveacross before any token moves (open question 11) | None | No | Not applicable | C26 writes cross-repository to mergepath today |

The consumers must handle what `workflow_run` does not give them. `workflow_run.pull_requests` can be empty, notably for fork PRs, so a consumer resolves the PR from the run's head SHA, or from a PR number carried in the producer's `run-name` as an untrusted nomination (the [#2278](https://github.com/nathanjohnpayne/mergepath/pull/2278) approach), and then applies the exact-head rule. A non-empty `pull_requests` is a snapshot from when the run was created: a PR in it may have closed since, and another PR may have opened at the same head. So the consumer counts only PRs that are open at that head now, from the commit's current PR associations and each nominated PR re-read live, requires exactly one, and when the snapshot named any PR, requires the one it found to be among them (#2823). A workflow on a non-default branch can also borrow the producer's `name`. That only nominates an evaluation the consumer re-derives. Before it does anything else, the consumer validates these `github.event.workflow_run` fields (the same object as the [workflow-runs REST resource](https://docs.github.com/en/rest/actions/workflow-runs)):

| Field | Required value | Why |
|---|---|---|
| `workflow_id` | The numeric ID of the expected producer file in this repository, read from `GET /repos/{owner}/{repo}/actions/workflows/agent-review.yml` (or `pr-review-policy.yml`) with the job's `GITHUB_TOKEN`. The consumer job therefore declares `actions: read` in its job-level `permissions:`, because scopes it does not list are `none` | The ID is stable and identifies the file, not its display name |
| `path` | After removing one trailing `@<ref>` suffix, exactly `.github/workflows/agent-review.yml` (or `pr-review-policy.yml`) | A cross-check only. GitHub's REST example reports `.github/workflows/build.yml@main`; this repository's live runs (read 2026-10-23) report the bare path. A prefix or substring match is never used |
| `event` | `pull_request` or `pull_request_review` for `trusted-review-mutations.yml`; `pull_request` for `trusted-policy-mutations.yml` | The producers' own triggers; anything else is not a candidate PR run |
| `head_repository.id`, `repository.id` | Equal to each other and to `github.repository_id` | Invariant 9 |
| `head_sha` | The nominated head; the live PR's head must equal it | Invariant 5 |

`head_branch`, `conclusion`, `display_title` and artifacts are never authorization inputs. A consumer may use `conclusion` to skip work, but never to admit it.

Dependabot-actor PR runs need the same care. Whether a `workflow_run` started by a Dependabot-actor run gets an OIDC token is for the pilot to record with #2776. The rule is fail closed: no token means no write. The Dependabot lane's own credentials stay in C13 and C14, on `pull_request_target`. GitHub withholds secrets from a Dependabot-initiated `pull_request_target` run only "if the base ref of the pull request was created by Dependabot" ([Dependabot on Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions)), and C13 and C14's base-is-default guard rules that case out. The live record agrees: nathanpaynedotcom [run 39737679498](https://github.com/nathanjohnpayne/nathanpaynedotcom/actions/runs/39737679498) (actor `dependabot[bot]`, `pull_request_target`, 2026-10-22) completed the approve-and-merge step, which hard-fails on an empty token. That page does not mention environment secrets, so #2729 must prove they resolve on such a run before the repository copies go.

If they do not, the C13 and C14 jobs move to a default-branch `workflow_run` or `repository_dispatch` consumer nominated by the credential-free `pull_request_target` run. That consumer gets the same base guard, provenance re-verification and exact-head binding, and the invariants are unchanged.

## Compatibility with #2733

[#2733](https://github.com/nathanjohnpayne/mergepath/issues/2733) keeps the three `pull_request_target` workflows running past GitHub's 2026-11-02 enforcement. Its owner proposal is one active event policy per repository and workflow path, with these allowed events:

- `dependabot-auto-merge.yml`: `pull_request_target`;
- `auto-clear-blocking-labels.yml`: `pull_request_target`, `workflow_run`, `repository_dispatch`, `schedule`;
- `merge-queue-authorization.yml`: `pull_request_target`.

This design keeps that configuration valid:

- **No new `pull_request_target` workflow.** The trusted consumers use `workflow_run`, which the enforcement does not affect. This is the main reason the design does not adopt #2278's `pull_request_target` consumer.
- **Paths and event sets are unchanged.** `dependabot-auto-merge.yml` splits into two jobs in the same file. `auto-clear-blocking-labels.yml` keeps all four events; its `pull_request_target` job loses its credentials but keeps running.
- **Retiring C15** may delete `merge-queue-authorization.yml`, which leaves its event policy inert. The owner may then delete that policy; nothing breaks if it stays.
- **Renames add the new path first.** Each #2733 policy names one literal `workflow_path`, so repointing a policy before the rename merges would leave the still-live old path unallowed. If implementation renames any of the three files, the owner adds the new path to that policy's `include` alongside the old one, the rename merges, and only then is the old path removed.

Event policies are repository settings that admit a run by path and event whatever branch defines it. They are not a credential control and do not replace the `main`-only environments.

## Relationship to #1547 and #2278

**Where this design depends on #1547 and #2278:**

- **Threat model.** #1547's model (a same-repository branch pusher running code with standing authority) is the one this design closes; see [Validation](#validation-against-the-1547-threat-model).
- **Shared principles.** It adopts the parked design's principles unchanged:
  - candidate workflows are secret-free; #2278 also makes them read-only, while this record makes them authority-free and leaves their existing `GITHUB_TOKEN` writes to #1547 (invariant 2);
  - privileged mutations run in trusted default-branch consumers that validate an immutable PR, head and base binding and repeat the live writer fences;
  - a non-reviewer app performs event-producing mutations and never approves or merges;
  - Dependabot approval and merge are separate protected jobs;
  - every environment is custom `main`-only with administrator bypass off;
  - `merge-queue-policy` keeps its exact-three contract;
  - only inventoried repository shadows are removed;
  - all live actions are owner-performed.
- **Native lineages are untouched.** It changes nothing in #1547's adopted decisions on native required-check lineages: the [same-repository relay](https://github.com/nathanjohnpayne/mergepath/issues/1547#issuecomment-6193479998) and [option B native recovery](https://github.com/nathanjohnpayne/mergepath/issues/1547#issuecomment-6208903032). Only credentialed mutations move.
- **Cutover sequence.** It assumes the [isolation-first cutover](https://github.com/nathanjohnpayne/mergepath/issues/1547#issuecomment-6245625188) remains the model whenever a cutover happens: while any repository copy of an old secret exists, candidate YAML can read it. #2730 decides the actual sequence. The new Dependabot secret name and the `github_pat_` class check make a missing environment copy fail closed, which narrows but does not remove the case for a planned outage.

**Where it differs from #2278:**

| Topic | #2278 (parked) | This design | Why |
|---|---|---|---|
| App credential | Stored `REVIEW_AUTOMATION_PRIVATE_KEY` in `review-automation` | Octo STS exchange, no stored key; the stored key in `review-automation` only as #2727's owner-approved fallback | #2727's owner decision; a shared key can mint for every installation |
| Reviewer environment | `reviewer-maintenance` holds `REVIEWER_ASSIGNMENT_TOKEN` for maintenance and Dependabot approval | `dependabot-reviewer` holds only `DEPENDABOT_REVIEWER_TOKEN`, for C13; maintenance moves to the app | #2718's option 1 decision and its correction |
| Trusted PR consumer | `trusted-pr-policy.yml` on `pull_request_target` | `workflow_run` consumers | Octo STS subjects stay in GitHub's documented branch form, and no fourth `pull_request_target` workflow needs a #2733 event policy |
| Auto-clear | Splits the queue and protective phase from the app's label writer | The same split, and the `pull_request_target` path becomes a credential-free nominator | No credential on any `pull_request_target` path except Dependabot's and, if it is kept, C15's |
| Byline-only reports | Keep reviewer-attributed maintenance | `GITHUB_TOKEN` (C18, C19, C21, C24), pending the owner's byline decision | No PAT for a byline |
| Hub audit and proof destinations | `branch-protection-audit`, `onepassword-proof` | Out of #2718's scope, unchanged | Not pre-empted |

**What stays the owner's call.** None of this decides whether #2278 is refreshed toward this shape, superseded by #2727 to #2729, or revived as it stands. That remains the owner's call at the #1547 revisit. If #2278 is revived unchanged, its stored-key path matches this design's fallback, but its `pull_request_target` consumer needs a fourth #2733 event policy, and its `reviewer-maintenance` environment conflicts with the option 1 decision.

## Validation against the #1547 threat model

| Route to a credential (#1547, inventory) | Control in this design |
|---|---|
| Candidate workflow definition reads a secret (C1 to C7) | Invariant 2: candidate workflows reference no secret and request no OIDC token; their mutations move to `workflow_run` consumers |
| A branch adds a new workflow that reads repository secrets | Invariant 1: no authority secret at repository scope; environments reject non-`main` refs; Octo STS rejects any non-`main` `sub` and any unpinned workflow |
| Trusted definition executes candidate helpers or packages (C4) | Execution rules; #2775's fixed shape; the regression lint |
| `pull_request_target` on a non-default base (C8, C9, C13 to C15) | GitHub has run the default branch's definition since 2025-12-08, which closes the definition route. C13 and C14's base-SHA checkout is bound by the base-is-default guard; C8 and C9 hold no credential on that path |
| `workflow_dispatch` of a branch copy deletes the in-file guard (C18 to C26) | Those callers hold no authority credential; any credential they ever need is gated by environment or `sub`, not by the in-file guard |
| OIDC token requested by any run | Exact `sub`, `workflow_ref`, `event_name`, `ref` and repository IDs in every policy; the `id-token` allowlist lint |
| Policy edited on a branch | A pilot requirement: Octo STS must be shown to read only the default branch. Policy files are Phase 4 paths |
| Stale nomination, or a head pushed between check and write | Invariant 5's exact-head binding and the repeated writer fences |
| A fork PR's read-only producer nominates a privileged `workflow_run` consumer | Invariant 9's same-repository admission, as a job-level `if:` and again on the live PR, before any exchange or write |
| Silent fallback to a surviving repository shadow during cutover | New Dependabot secret name; author `github_pat_` class check; shadow removal before the cutover is declared |

## Residual risks

- **The Dependabot PAT's reach.** It is a classic token. A stolen copy reaches every repository its account can access within its scopes. The dedicated name and environment reduce exposure, not blast radius (the corrections, point 1). #2729 writes this down where the token is configured.
- **`main` is the trust root.** Anyone who can land a change on `main` controls every credential. That is the existing review and Phase 4 boundary on `.github/**`, unchanged here.
- **Hosted Octo STS.** Its operator sets the installation's permissions and can mint tokens for its installations. Each trust policy bounds the per-token permissions; it does not bound the operator. Self-hosting is #2727's recorded trade-off.
- **Per-file granularity.** A policy's permissions are the union for its workflow file, because OIDC claims do not identify the job.
- **Consumer latency.** The C2 to C7 mutations land one `workflow_run` hop later than today. Merge safety must keep resting on the native required verdicts and the clearance gate's own checks, which #2727 confirms per caller.
- **Not atomic.** GitHub reads and writes are not atomic. The fences narrow the race; they do not close it.
- **The local route stays open.** First-party agents' local route to these identities (#2129) is unchanged; #1547's deferral rationale still applies to it.

## Owner decisions requested

Accepting this record accepts the invariants, the environment layout and the Octo STS template. These choices are also put to the owner, each with a recommendation:

1. **Trusted consumer trigger:** `workflow_run`, not #2278's `pull_request_target`. Recommended.
2. **Auto-clear's `pull_request_target` path** becomes a credential-free nominator. Recommended.
3. **Names:** the environment `dependabot-reviewer` and the secret `DEPENDABOT_REVIEWER_TOKEN`; `AUTHOR_MERGE_TOKEN` stays in `merge-queue-policy`. Recommended.
4. **Byline-only writers** (C18, C19, C21, C24) move to `GITHUB_TOKEN` and lose the agent byline (open question 9). Recommended unless the byline is a requirement.
5. **C15 and C16:** retire their author-token bindings rather than migrate them (open question 13). Recommended.
6. **fiveacross stray:** delete it before any token moves (open question 11). Recommended.
7. **Immutable OIDC subjects:** optional hardening. The policies pin repository and owner IDs either way.
8. **C23's reviewer-standing gate:** drop it for the CI run of this read-only audit, keeping it for local runs, rather than give the audit a reviewer PAT. Keep C10 and C12 on the author token for now. Recommended.

## Handed to implementation

- **#2727:**
  - the two consumer workflows and the auto-clear split;
  - the policy files and their template;
  - the `id-token` allowlist lint;
  - the bot login (into `non_reviewer_identities` and `thread_resolution_ci_app_identity`);
  - per-caller confirmation of follow-on events and of merge safety under consumer latency;
  - the `workflow_run` field validation and same-repository admission (invariant 9), with fork and borrowed-name rejection tests.
- **#2728:**
  - the permission set, including the GraphQL merge permissions (open question 14);
  - the `github_pat_` class check;
  - whether C10 and C12 can leave the author token.
- **#2729:**
  - the `dependabot-reviewer` environment and the approval and merge job split;
  - minimum classic scopes;
  - that `dependabot-reviewer` and `merge-queue-policy` environment secrets resolve on a Dependabot-initiated `pull_request_target` run against `main`, or else the downstream-consumer variant above.
- **#2732 (pilot):**
  - the `app` pin value and the bot login of the pinned app, the same on every exchange;
  - the emitted `sub` and the presence of `job_workflow_ref`, including the subject a `pull_request_target` run presents;
  - label add and `DELETE` on a PR under `pull_requests: write` alone;
  - default-branch policy reads, and refusal of PR runs, unpinned workflows and branch-edited policies;
  - non-admin viewer semantics;
  - cross-repository `GITHUB_TOKEN` reads;
  - OIDC on Dependabot-actor `workflow_run`.
- **#2730:** cutover sequence, shadow removal and revocation.
- **#2774:** the drift audit covers repository-scoped authority secrets, unprotected environments and policy files that drift from the template.

## References

- Inventory: [`docs/audits/pipeline-token-callers-2026-10.md`](../audits/pipeline-token-callers-2026-10.md) (#2725)
- #2718: [split design](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330025020), [Dependabot option 1 decision](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330037781), [independent assessment](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330473158), [corrections](https://github.com/nathanjohnpayne/mergepath/issues/2718#issuecomment-6330518903)
- #1547: [deferral and park decision](https://github.com/nathanjohnpayne/mergepath/issues/1547#issuecomment-6251588075); #2278's `specs/trusted_workflow_credentials.md` at its parked head `431afbe0a0466d87bb02fb7c858c94b3a08ef73b`
- R-107: `docs/ontology/rules.md`
- GitHub: [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc), [deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [securely using `pull_request_target`](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target), [events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- Octo STS: [app and trust-policy format](https://github.com/octo-sts/app)
