# pull_request_target enforcement (#2733), 2026-11

GitHub starts blocking `pull_request_target` runs in affected public repositories on 2026-11-02. Three propagated MergePath workflows trigger on that event and run in all eight public fleet repositories, so without a remedy every repository loses Dependabot auto-merge, blocking-label clearing and merge continuation on that date. This record states what GitHub changes, which workflows it hits, why the remedy is an owner-applied event policy rather than a workflow edit, and the exact procedure and evidence for [#2733](https://github.com/nathanjohnpayne/mergepath/issues/2733). GitHub's documentation was read on 2026-10-22.

## What GitHub changes

Sources: [Securely using `pull_request_target`](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target) (cited below as *Securely*), [About Actions policies](https://docs.github.com/en/actions/concepts/about-actions-policies) (*About*), [Governing execution of GitHub Actions workflows](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution) (*Governing*) and [REST API endpoints for GitHub Actions policies](https://docs.github.com/en/rest/actions/policies) (*REST*).

- **The default policy.** "For public repositories that do not already have an applicable Actions event policy, GitHub adds a default policy that blocks workflows triggered by `pull_request_target`." It "does not apply to private or internal repositories" and "does not replace an applicable event policy that you have already configured" (*Securely*, § How the default policy works).
- **The date.** The default policy "currently runs in evaluate mode", where runs continue and policy insights show what would be blocked. "On November 2, 2026, GitHub will enforce the default policy for affected repositories that were using the default `pull_request_target` policy before general availability" (*Securely*, § How the default policy works).
- **What a blocked run looks like.** "When enforced, disallowed workflow runs will fail with an error", for example `Event 'workflow_dispatch' is not allowed to trigger Actions workflows.` (*About*, § About workflow execution protections).
- **The remedies GitHub offers.** Move a workflow that does not need `pull_request_target` to a safer event such as `pull_request`; otherwise, "If the workflow must continue to use `pull_request_target`, create or update an applicable Actions event policy that explicitly allows `pull_request_target`" (*Securely*, § Reviewing the impact before enforcement). A workflow file cannot opt itself out.
- **Event rules are an allowlist.** Workflow execution protections "define an allowlist that controls who can trigger GitHub Actions workflows and which events are permitted to run them"; event rules "control which events are permitted" (*About*). A policy can be scoped "to specific workflow paths" (*Governing*, § Preparing to add protections), and protections "layer with other protections in the same repository, organization, or enterprise" (*Governing*). So a policy scoped to one workflow path must list every event that workflow triggers on, and any other active event policy that targets the same path must allow them too.
- **Policy shape.** A repository policy takes `name`, `enforcement` (`disabled`, `active` or `evaluate`), an optional `conditions.workflow_path` with `include` and `exclude` arrays of "workflow file paths or glob patterns", and `rules`; the event rule is `restrict_action_events` with `parameters.allowed_events`, whose supported values include `pull_request_target`, `workflow_run`, `repository_dispatch` and `schedule`. `evaluate` "is only available with GitHub Enterprise", so these user-owned repositories need `active` policies. Every endpoint needs the "Administration" repository permission (write), which is why the agents' review PATs get 404 (*REST*, § Create a repository Actions policy).

Two related protections in *Securely* do not affect these workflows. The `actions/checkout` guard that requires `allow-unsafe-pr-checkout: true` "only covers fork pull request refs" (§ Opting out of built-in protections); none of the three checks out a pull request ref. `pull_request_target` runs have read-only access to the default branch's cache (§ Hardening a `pull_request_target` workflow); none of the three uses a cache.

## Affected workflows

All three trigger on `pull_request_target` and are `canonical`, `consumers: all` in `.mergepath-sync.yml`, so each runs in every public fleet repository. No other workflow in the hub or in any consumer triggers on that event (on 2026-10-22 a code search found the word elsewhere only in `agent-review.yml`, `pr-review-policy.yml` and `merge-clearance-gate.yml`, and a parse of each repository's copies showed none of them triggers on it).

| Workflow | Triggers (all must be allowed) | Why `pull_request` cannot replace it | Checked-out code |
|---|---|---|---|
| `dependabot-auto-merge.yml` | `pull_request_target` | It approves and merges with `REVIEWER_ASSIGNMENT_TOKEN` and `AUTHOR_MERGE_TOKEN`. A `pull_request` run would execute the PR merge commit's copy of the workflow, which is candidate code, with those secrets. | `github.event.pull_request.base.sha` |
| `auto-clear-blocking-labels.yml` | `pull_request_target`, `workflow_run`, `repository_dispatch`, `schedule` | It removes labels and continues approved merges with the CI actor, author and queue tokens. Same objection. | default branch |
| `merge-queue-authorization.yml` (dormant) | `pull_request_target` | It records queue authorization with `AUTHOR_MERGE_TOKEN` from the `merge-queue-policy` environment, which is restricted to literal `main`. | `github.event.pull_request.base.sha` |

Because each workflow keeps `pull_request_target`, the remedy is one explicit event policy per workflow path in each public repository. Moving any of them to `pull_request` would widen the trust boundary, and the base-branch exposure of these triggers is being redesigned separately in [#2731](https://github.com/nathanjohnpayne/mergepath/issues/2731).

## Tooling

`scripts/workflow/pull-request-target-policy.py` holds the registry of these three paths and their pinned trigger lists. It never writes a setting.

- `lint` fails when the local `pull_request_target` workflows differ from the registry (a registered file deleted or an unregistered one added), when a registered workflow's triggers differ from its pinned events (including dropping `pull_request_target`), or when one of them checks out a ref other than the base SHA or default branch, sets `allow-unsafe-pr-checkout`, checks out another repository, calls any reusable workflow (local or remote, since a called workflow inherits the caller's secrets and the lint does not follow it) or downloads an artifact. Action names are compared case-insensitively, because GitHub resolves an action's owner and repository that way, and a remote action reference that is not canonical `owner/repo[/path]@ref` fails: the runner drops empty path components, so `actions//checkout@<sha>` and `actions/checkout/@<sha>` still run checkout (#2823). In shell steps it also fails on any `git` command, `gh pr checkout`, `gh repo clone`, `gh run download` or `gh release download`, `curl` or `wget`, a tarball or zipball endpoint, a `refs/pull/` reference, or the fork's `head.repo` coordinates. None of the three workflows needs any of these, so the check is a tripwire on the whole class. It is not a proof that candidate code never runs: an arbitrary program can retrieve code in ways no text check decides, and the trust boundary itself is the base-side checkout. `scripts/ci/check_pull_request_target_policy` runs it in `repo-lint` on the hub and every consumer. Adding a trigger to one of these workflows therefore fails CI until the registry changes, and changing the registry means re-running the procedure below on every public repository before the new workflow propagates; otherwise the policy blocks the new event.
- `payloads` prints the three policy bodies. They match the owner proposal on the issue.
- `plan --repo OWNER/NAME --out DIR` reads the repository-level policies, writes the payload files to `DIR` and prints one create (`POST`) or update (`PUT`, matched by policy name) command per workflow, each through `scripts/gh-as-author.sh` so the token is verified as `nathanjohnpayne` before the write.
- `verify --repo OWNER/NAME [--ref main]` reads every policy that applies to the repository (`has_parents=true`, inherited ones through their own link) and the repository's own copy of each registered workflow. For each workflow it reports `OK` (an active policy targeting the exact path allows `pull_request_target` and no applicable active policy omits one of its events), `UNCOVERED` (nothing explicitly allows it, so the default policy blocks it from 2026-11-02), `BLOCKED` (an applicable active policy omits one of its events), `UNVERIFIED` (a glob the tool does not model, or an actor or other rule it does not evaluate), `DRIFT` (the repository's copy no longer triggers on `pull_request_target`, so the registry and policy are stale) or `ABSENT`. It resolves the ref first, because the contents API answers a missing ref with the same 404 as a missing file, and exits 0 only when every present workflow is `OK`.

## Owner procedure

Settings are the owner's to apply. Run from a mergepath checkout on `main`, once per repository in [Repositories](#repositories), after `eval "$(scripts/op-preflight.sh --agent claude --mode review)"` has cached the author token:

```bash
GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" scripts/workflow/pull-request-target-policy.py verify --repo nathanjohnpayne/REPO
```

Expect three `UNCOVERED` lines before the policies exist. Then:

```bash
GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" scripts/workflow/pull-request-target-policy.py plan --repo nathanjohnpayne/REPO --out "$TMPDIR/prt-policy"
```

Run the three printed `scripts/gh-as-author.sh -- gh api …` commands, then run `verify` again and record its output: three `OK` lines and exit 0. Finally open Settings → Actions → Policies → Policy insights for the repository, as *Governing* (§ Evaluating policies) describes, and record that no run of the three workflows would be blocked. The API does not expose insights, so this step stays manual.

## Repositories

All eight were public, non-archived and on `main` on 2026-10-22, each with byte-identical copies of the three workflows and no Actions policies (owner readback on the issue). Fill in each column as the procedure runs.

| Repository | `verify` OK before 2026-11-02 | Policy insights clear | First `pull_request_target` run after 2026-11-02 |
|---|---|---|---|
| `mergepath` | | | |
| `nathanpaynedotcom` | | | |
| `friends-and-family-billing` | | | |
| `overridebroadway` | | | |
| `swipewatch` | | | |
| `fiveacross` | | | |
| `matchline` | | | |
| `tadlockpsychiatry` | | | |

A run counts as post-enforcement evidence only if it was triggered by `pull_request_target`; a scheduled auto-clear run or a run whose jobs all skipped does not exercise the event. `merge-queue-authorization.yml` is dormant, and arming the queue to produce a run stays an owner decision.

## Open questions

- *Securely* does not say whether a policy scoped to one workflow path also lifts the default policy for other workflows in the repository. No other workflow in the fleet triggers on `pull_request_target`, so this does not change the remedy; policy insights after the policies exist would show it.
- The default policy is not returned by the policies list (the owner's readback returned `total_count: 0`), so `verify` cannot see it. It treats the absence of an explicit allow as `UNCOVERED`, which is the documented outcome after enforcement.
