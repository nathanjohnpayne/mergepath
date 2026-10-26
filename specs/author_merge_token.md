---
spec_id: author_merge_token
---

# Per-repository fine-grained author token

`AUTHOR_MERGE_TOKEN` is today one shared classic `nathanjohnpayne` PAT, stored as a repository secret in the hub and all seven consumers. [#2728](https://github.com/nathanjohnpayne/mergepath/issues/2728) (parent [#2718](https://github.com/nathanjohnpayne/mergepath/issues/2718)) replaces it with one fine-grained `nathanjohnpayne` PAT per repository, stored only in that repository's `merge-queue-policy` environment. This spec gives the minimum permission set, each permission tied to a caller and to GitHub's documentation, the class check that makes a missing environment copy fail closed, the checks the [#2732](https://github.com/nathanjohnpayne/mergepath/issues/2732) pilot must run, and the owner's cutover runbook.

The governing design is [ADR 0004](../docs/architecture/0004-trusted-privileged-jobs.md) (Accepted). The callers, their API calls and the permission union come from the inventory [`docs/audits/pipeline-token-callers-2026-10.md`](../docs/audits/pipeline-token-callers-2026-10.md) ([#2725](https://github.com/nathanjohnpayne/mergepath/issues/2725)); caller IDs (C9, C10 and so on) are its row IDs.

Nothing in this spec mints, stores, sets, moves or revokes a credential, or changes a setting. Every such step below is owner-performed. The code it adds is inert until a repository's policy opts in.

## Callers

ADR 0004 keeps the author token in `merge-queue-policy` for these callers:

| ID | Caller | What the token does | Writes |
|---|---|---|---|
| C9 | Protective retraction (`approval-merge-continuation.sh --retract-unsafe-only`, `merge-queue-arm-policy.sh`) | Value-distinctness checks, then `GET /user` in the dormant queue classifier | None |
| C10, C12 | Approved-PR continuation (`approval-merge-continuation.sh`, event and scheduled) | `GET /user` must equal `author_identity`; then the readiness helpers' reads | None. It prints a merge-ready result and never merges |
| C14 | Dependabot merge (`dependabot-auto-merge.yml`) | `GET /user` must equal `author_identity`; `gh pr merge --squash --auto --match-head-commit`, falling back to an immediate `--match-head-commit` squash | The merge (`mergedBy` must be the author) |

Out of scope:

- **C15 and C16** (merge-queue authorization and final audit) are dormant: `merge_queue_rollout_mode` is `disabled`, and the queue needs an organization-owned repository, which the fleet is not (inventory open question 13). ADR 0004 recommends retiring their author-token bindings. Until then they only reach `GET /user` before their rollout checks stop them, which this token satisfies. Their marker comments would need Issues: write and Pull requests: write; reviving the queue must revisit this set.
- **`BRANCH_PROTECTION_AUDIT_TOKEN`** (inventory open question 17) is a separate `nathanjohnpayne` fine-grained PAT with Administration: read on every manifest repository, specified by ADR 0002 and unchanged by ADR 0004. It is not one of the per-repository tokens, but the runbook's revocation step checks that it does not hold the shared classic value.

## Permission set

Create each token with these settings:

- **Resource owner:** `nathanjohnpayne`.
- **Repository access:** "Only select repositories", exactly one: the repository whose environment will hold it.
- **Expiration:** a fixed date, recorded in the [inventory](#token-inventory). GitHub allows no expiration for a personal account's fine-grained token, but a fixed date bounds a leaked copy; one year or less is recommended.
- **Account permissions:** none.
- **Repository permissions:** exactly the table below. Every permission not listed is "No access", including Checks (not offered), Workflows (see [pilot check P3](#pilot-checks)), Code scanning alerts, Secrets, Environments and Variables.

| Permission | Access | Needed by | Evidence |
|---|---|---|---|
| Metadata | Read | All | Mandatory for every fine-grained token. `GET /repos/{owner}/{repo}/rules/branches/{branch}`, `GET /repos/{owner}/{repo}/rulesets` and `GET /repos/{owner}/{repo}/rulesets/{id}` (`merge-clearance-gate.sh`, `branch-requirements.sh`) are listed under Metadata: read. |
| Contents | Read and write | C14 (write); C10, C12 (read) | `PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge` is listed under Contents: write. Reads: `GET contents/{path}?ref`, `GET commits/{sha}`, `GET compare`, and `git fetch` through `gh auth git-credential` (resolver, propagation verifier, fingerprint helpers). |
| Pull requests | Read and write | C14 (write); C10, C12 (read) | Write: `enablePullRequestAutoMerge` and `mergePullRequest` act on a pull request, and GitHub's auto-merge article says "People with write permissions to a repository can enable auto-merge". Reads: `GET pulls/{n}`, `reviews`, `files`, `comments`, `commits`, and GraphQL `reviewThreads`. |
| Issues | Read | C10, C12 | `GET issues/{n}/timeline`, `issues/{n}/comments`, `issues/{n}/labels` and comment reactions (`codex-review-check.sh`, `external_review_carryforward.sh`) are listed under Issues: read. |
| Actions | Read | C10, C12 | `GET /repos/{owner}/{repo}/actions/runs` (`required-head-checks.sh --verify`) is listed under Actions: read; GraphQL `checkSuite.workflowRun` in `statusCheckRollup`. |
| Commit statuses | Read | C10, C12 | `GET /repos/{owner}/{repo}/commits/{ref}/statuses` is listed under Commit statuses: read; `StatusContext` nodes in `statusCheckRollup`. |
| Administration | Read | C10, C12 | `GET /repos/{owner}/{repo}/branches/{branch}/protection` is listed under Administration: read. `merge-clearance-gate.sh` reads `enforce_admins` there, and `branch-requirements.sh` reads GraphQL `branchProtectionRule`. Without it, see below. |

Evidence is GitHub's [Permissions required for fine-grained personal access tokens](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens), [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) and [Automatically merging a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request), read on 2026-10-26. That permissions page covers REST only. It says nothing about GraphQL, so every GraphQL use above is a pilot check. It also says the listed permissions "are required to access private resources", and that some endpoints also serve public resources without them. All eight fleet repositories are public today (inventory open question 10), so a pilot that passes on a public repository proves sufficiency, not necessity. The set is sized for a private repository.

How this differs from #2728's expected set:

- **Issues is read only.** No author-token caller left by ADR 0004 writes an issue, a comment or a label. C10 and C12 only report, and C14 only merges. The comment writers, C15 and C16, are out of scope (above).
- **Checks is absent.** The permissions page has no repository permission section for Checks, and the managing-tokens page lists "Using fine-grained personal access token to call the Checks API" among the features fine-grained tokens do not support. This affects C10 and C12, not C14 (C14's check waits run under the reviewer token in the same step). `required-head-checks.sh --verify` calls `GET commits/{sha}/check-runs`, and gate (a) of `codex-review-check.sh` reads `CheckRun` nodes in GraphQL `statusCheckRollup`. If GitHub refuses those reads, `required-head-checks.sh` exits 3 (indeterminate) and continuation reports an infrastructure error, so the failure is a red job, never a false merge-ready. Pilot check P2 measures it.
- **Administration: read is added.** `branch-requirements.sh` trusts the classic surface for an administrator viewer only through `branchProtectionRule`. If that is null and the viewer is not `WRITE`, it records "classic projection completeness unproven", the requirement read is incomplete, and continuation cannot reach merge-ready. The `nathanjohnpayne` viewer is the repository owner (`ADMIN`), and the classic `repo` token sees `branchProtectionRule` today. Administration: read keeps that view. It reads repository settings; it does not grant secret values, setting changes or bypass. Pilot check P4 confirms it is sufficient.
- **`GET /user` needs nothing.** The permissions page lists no permission for it. Any user-held token answers it, which C9, C10, C12 and C14 depend on; an App installation token cannot.

## Class check

A job that names `merge-queue-policy` resolves `secrets.AUTHOR_MERGE_TOKEN` from the environment when it holds the secret, and silently from the repository when it does not. During cutover the shared classic copy is still a repository secret, and it passes every existing check: its login is `nathanjohnpayne` and `credential-class.sh` classes it `user-held`. So ADR 0004 requires the author jobs to require the fine-grained `github_pat_` form.

The requirement is the top-level `author_merge_token_class` key in each repository's `.github/review-policy.yml`:

| Value | Meaning |
|---|---|
| absent, or `any` | Not cut over. The class is not checked, and today's identity checks are unchanged. |
| `fine-grained` | The token must start with `github_pat_`. A classic token, an OAuth or installation token, the brokered placeholder or an empty value fails. |
| anything else | Fails closed as an unknown requirement. |
| the key more than once | Fails closed (`duplicate-key`). Both readers would otherwise take the first match, so an `any` left above a later `fine-grained` would skip the check. |

- `credential_meets_author_token_class` in `scripts/lib/credential-class.sh` is the single decision: exit 0 for a met or absent requirement, 1 for a mismatch, 2 for an unknown value.
- **C10 and C12** read the key from the governing base policy that `approval-merge-continuation.sh` already resolves for `author_identity`, and check the token right after the login check. A mismatch or an unknown value is an infrastructure error (exit 3) before any readiness read. A met requirement logs `approval continuation: author token meets author_merge_token_class 'fine-grained'`.
- **C14** reads the key from the base-SHA policy it already uses for `author_identity`, and fails the step before approving or merging. A met requirement logs a `::notice::` line naming the class.
- **Propagation order.** Both callers reach the library function only when the key requires a class. A repository that has not cut over therefore keeps working when it receives a caller before the updated library, and one that has cut over fails closed if the library is missing or predates the function.
- **C9** (protective retraction) does not check the class. It never writes with the author token, and blocking it would stop a safety retraction.

The key is policy, not an Actions variable. A variable named in an environment also falls back to repository scope, and it would be absent in exactly the case it exists to catch. The policy is reviewed content on `main`, and `.github/review-policy.yml` is a Phase 4 path. Each repository's cutover PR sets the value once that repository's token is provisioned and verified (runbook step 6).

## Pilot checks

The [#2732](https://github.com/nathanjohnpayne/mergepath/issues/2732) pilot runs these on its pilot consumer with only the listed permissions. Record each result, with run links, on #2732. A failure stops the cutover for every repository until this spec is amended. Never widen a token silently.

| ID | Check | Pass | If it fails |
|---|---|---|---|
| P1 | C14's merge paths: `gh pr merge --squash --auto --match-head-commit` (`enablePullRequestAutoMerge`), and the immediate-squash fallback (`mergePullRequest`) on a repository without `--auto` or by forcing the fallback (inventory open question 14) | Auto-merge is enabled and the PR merges with `mergedBy` = `nathanjohnpayne` | Read the response's `X-Accepted-GitHub-Permissions` header, or the error, for the missing permission. Amend this table, then reissue |
| P2 | C10 and C12 readiness: `required-head-checks.sh --verify` and the `statusCheckRollup` read under the fine-grained token, on an approved PR | Both return the same check runs the classic token sees | Owner decision: route the check reads through the job's `GITHUB_TOKEN` (`checks: read`), or move C10 and C12 off the author token (inventory open question 15, ADR 0004 decision 8). Either is a code change; until it lands, C10 and C12 stay on the classic token |
| P3 | C14 on a `github-actions` ecosystem bump that edits `.github/workflows/**` | The merge completes | Add Workflows: write to that repository's token and record why. With Contents: write it lets the token push workflow files to branches. After cutover no authority secret is a repository secret, so a branch workflow reaches no credential |
| P4 | Classic-surface view: `branch-requirements.sh` and the `merge-clearance-gate.sh` enforcement probe under the token | `viewerPermission` is `ADMIN` (the view follows the user, not the token: inventory open question 4), `branchProtectionRule` is non-null, and `enforce_admins` is readable | Without a non-null `branchProtectionRule`, the gate's classic surface is incomplete for an administrator viewer. Owner decision on the gate before cutover |
| P5 | Class check | The C14 and continuation logs show the class line; a deliberately classic value in the environment fails both | Fix before any repository sets `fine-grained` |

P5's negative half is a one-time owner check on the pilot repository: put a classic value in the environment copy, observe both failures, then restore the fine-grained value.

## Cutover runbook

Owner-performed throughout. An agent may open the policy and inventory PRs the steps name, after the owner says the token is in place. It never reads, sets or deletes a secret. Repository names below are `nathanjohnpayne/<repo>`.

### Before the first repository

1. This spec's code is on the repository's default branch: `scripts/lib/credential-class.sh` defines `credential_meets_author_token_class`, and the repository's `dependabot-auto-merge.yml` and `approval-merge-continuation.sh` call it. Propagation carries it to consumers.
2. `merge-queue-policy` is configured as ADR 0004 requires: deployment branches "Selected branches and tags" with the single custom branch `main`, administrator bypass disabled, no required reviewers, no wait timer. Confirm with `gh api repos/nathanjohnpayne/<repo>/environments/merge-queue-policy --jq '{deployment_branch_policy, can_admins_bypass, protection_rules}'` and `gh api repos/nathanjohnpayne/<repo>/environments/merge-queue-policy/deployment-branch-policies --jq '.branch_policies[] | {name, type}'`.
3. The pilot repository goes first, and P1 to P5 pass on it before any other repository starts.

### Per repository

Do these in order, one repository at a time.

1. **Create the token** at GitHub → Settings → Developer settings → Fine-grained tokens, with the [settings and permissions above](#permission-set). Name it `mergepath author <repo>`.
2. **Store it in 1Password** in the `Private` vault, as a new item titled `GitHub PAT nathanjohnpayne author <repo>` with the value in field `token` and the expiry date in a field. Note the item ID: look items up by ID, never by title.
3. **Set the environment secret**, leaving the repository copy in place. Pipe the value in: `gh secret set` reads it from standard input when `--body` is omitted, which keeps it out of the process list that `--body "$(op read …)"` would put it in.

   ```bash
   op read 'op://Private/<item-id>/token' | gh secret set AUTHOR_MERGE_TOKEN --env merge-queue-policy --repo nathanjohnpayne/<repo>
   ```
4. **Read back names only.** `gh api repos/nathanjohnpayne/<repo>/environments/merge-queue-policy/secrets --jq '.secrets[].name'` lists `AUTHOR_MERGE_TOKEN`.
5. **Verify the token before the policy requires it.** On the next Dependabot patch or minor PR, the merge step completes and `gh pr view <n> --repo nathanjohnpayne/<repo> --json mergedBy --jq .mergedBy.login` prints `nathanjohnpayne`. On the next approved PR, the auto-clear continuation pass prints merge-ready (or follows the P2 outcome). A job that names the environment prefers the environment copy, so these runs already use the new token.
6. **Require the class.** Merge a PR in that repository setting `author_merge_token_class: fine-grained` in `.github/review-policy.yml`. From then on, a missing environment copy fails closed instead of using the classic repository copy.
7. **Verify one passing merge path under the requirement.** Repeat step 5, and confirm the run log shows `AUTHOR_MERGE_TOKEN meets author_merge_token_class 'fine-grained'` (C14) or `author token meets author_merge_token_class 'fine-grained'` (continuation). This is the repository's verified replacement.
8. **Record it** in the [token inventory](#token-inventory): the item ID, expiry, the date and the verifying run link.
9. **Remove the repository copy** when [#2730](https://github.com/nathanjohnpayne/mergepath/issues/2730)'s sequence reaches this repository, and never before step 7: `gh secret delete AUTHOR_MERGE_TOKEN --repo nathanjohnpayne/<repo>`. Every author-token caller names `merge-queue-policy`, so nothing in the repository reads the repository copy once the environment holds one. `gh secret list --repo nathanjohnpayne/<repo>` no longer lists it.

### After every repository

Revoke nothing until all eight inventory rows are verified and every repository copy is gone.

1. **Prove no copy remains.** Run `scripts/audit-branch-protection.sh --fleet --require-credential-isolation` with an owner credential that has Secrets: read and Environments: read (it reads names, never values), and list secret names (repository, environment and Dependabot) for every repository `nathanjohnpayne` owns, not only the fleet, looking for `AUTHOR_MERGE_TOKEN`. Every hit outside a `merge-queue-policy` environment holding a verified fine-grained token is either replaced first, through the per-repository steps, or deleted.
2. **Identify what holds the shared classic value.** `DEPLOYMENT.md` set the CI copies from `op://Private/sm5kopwk6t6p3xmu2igesndzhe/token`, the human author PAT that local sessions also use as `OP_PREFLIGHT_AUTHOR_PAT` through `scripts/op-preflight.sh` and `scripts/gh-as-author.sh`. Also confirm that `BRANCH_PROTECTION_AUDIT_TOKEN` and `MERGE_QUEUE_POLICY_TOKEN`, wherever they are set, come from different items. If either shares the classic value, give it its own token, per its specification, before step 3.
3. **Invalidate the classic value.** The CI copies were readable by any same-repository branch workflow (ADR 0004 § Context), so the value they held must stop working.
   - If it is the local author PAT, **regenerate** it rather than delete it: GitHub → Settings → Developer settings → Tokens (classic) → the token → Regenerate. Write the new value to the same 1Password item, then re-run `scripts/op-preflight.sh` in each local session. The local route is [#2129](https://github.com/nathanjohnpayne/mergepath/issues/2129)'s concern and is not retired here.
   - If it was a separate CI-only classic token, **delete** it.
4. **Verify after revocation.** The next C14 merge and continuation pass in each repository still succeed, because none uses the classic value.

### Rollback

- **Before per-repository step 9:** set `author_merge_token_class: any` and delete the environment copy. Jobs fall back to the repository copy, which is today's state.
- **After step 9:** set `any`, and set the environment copy from the classic item until the fine-grained token is fixed or reissued.
- **After the classic value is invalidated** there is no classic fallback. Reissue the fine-grained token through per-repository steps 1 to 7.

### Rotation, expiry and compromise

- **Before expiry,** create the replacement token, store it as a new 1Password item, set it over the environment secret (per-repository step 3), verify as in step 7, update the inventory, then delete the old token. GitHub emails before a token expires. `GET /user` with the token also returns the `github-authentication-token-expiration` response header, which a later check could report on.
- **Expiry without rotation** fails closed. `gh api user` fails, so C14 exits before approving or merging, and continuation reports an infrastructure error.
- **Compromise:** delete the token on GitHub first. It reaches only one repository with the permissions above. Then reissue it through per-repository steps 1 to 7.

## Token inventory

Ownership of every token: `nathanjohnpayne` (the repository owner), who mints, stores, sets, rotates and revokes it. Each row is filled by that repository's cutover; an empty row means not cut over.

| Repository | 1Password item ID | Created | Expires | Verified (step 7 run) |
|---|---|---|---|---|
| `mergepath` | | | | |
| `nathanpaynedotcom` | | | | |
| `friends-and-family-billing` | | | | |
| `overridebroadway` | | | | |
| `swipewatch` | | | | |
| `fiveacross` | | | | |
| `matchline` | | | | |
| `tadlockpsychiatry` | | | | |

## Tests

- `tests/test_author_merge_token.sh` covers `credential_meets_author_token_class` and executes the shipped C14 block from `.github/workflows/dependabot-auto-merge.yml` against sample policies: absent, `any`, `fine-grained` with each token class, quoted, commented and trailing-space values, a repeated key, an unknown value, and a missing or older library. `scripts/ci/check_workflow_parsers` runs it.
- `tests/test_approval_merge_continuation.sh` covers the C10 and C12 wiring: a `fine-grained` policy rejects a classic token before any readiness read, accepts `github_pat_` and logs it, `any` keeps the classic token, an unknown value and a repeated key fail closed, and an older library is harmless under `any` but fails closed under `fine-grained`.
