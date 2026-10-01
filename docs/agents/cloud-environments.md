# Cloud Agent Environments

> Canonical source: `mergepath/docs/agents/cloud-environments.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy.

How to set up a Claude Code cloud session and a Codex cloud task so they can write under the right identities, what they still cannot do, and how a session tells which case it is in. The design and measurements behind it are in [mergepath#1057](https://github.com/nathanjohnpayne/mergepath/issues/1057).

The environment configuration lives in two web UIs (claude.ai and chatgpt.com) and nowhere in the repository. This document is the committed statement of what those settings must be, so they can be reviewed and reproduced. Only the setting **names** belong here, never their values.

## What a cloud session can and cannot do

**Cloud sessions author. CI performs the privileged residue. Local merges.**

| Capability | Local | Claude cloud | Codex cloud |
| --- | :---: | :---: | :---: |
| Read the repository and its PRs | yes | yes | yes, with agent internet on |
| Commit and push the session's branch | yes | yes | yes |
| Author writes (`gh pr create`, `gh pr comment` / `edit`) as the author | yes | yes, with a provisioned author PAT | yes, with a provisioned author PAT |
| Reviewer writes (`gh pr review`, `gh pr comment`) as `nathanpayne-<agent>` | yes | yes, with a provisioned reviewer PAT | yes, with a provisioned reviewer PAT |
| Trigger `@codex review` / `@coderabbitai` | yes | yes | yes |
| GraphQL-only helpers (`scripts/resolve-pr-threads.sh`) | yes | only for operations the proxy serves; otherwise exit 6 | unmeasured |
| Push a second branch (propagation waves) | yes | **no**: the proxy accepts pushes only to the session's branch | unmeasured |
| Reach another repository (consumer fleet) | yes | **no**: the proxy scopes the API to the attached repositories | unmeasured |
| Merge to a protected default branch | yes: the agent merges as the author once the merge gates pass, never past `human-hold` | no: hand the merge to a local session | no: hand the merge to a local session |

The **no** rows are properties of the Claude cloud GitHub proxy, not credential gaps. A better token does not change them. Route that work to a local session or to CI.

## Find out which case you are in

Run the capability probe at the start of a cloud session. It measures, without side effects, what this session can do, and caches the answer:

```bash
scripts/agent-capability-probe.sh            # JSON on stdout, summary on stderr
eval "$(scripts/agent-capability-probe.sh --check --print-exports)"   # later calls
```

It reports a tier such as `author-writes,reviewer-writes` or `read-only`, and one `MERGEPATH_CAP_<NAME>` flag per capability. In a Claude cloud session the repository's SessionStart hook runs it for you and puts the summary in the session's context. A Codex task has to run it itself.

A write capability is granted only when the probe can prove it. The token must read as the expected login, be a user-held credential (never the proxy's `proxy-injected` placeholder), have the repository permission the role needs, and, for a classic token, carry the `repo` scope (or `public_repo` when the repository is public). A fine-grained token cannot have its own permissions read, so the probe reports it with basis `unverifiable` and does not grant the capability. The wrappers still accept it: before each write they verify that the token reads as the expected login and is a user-held credential.

## Credentials: provision dedicated PATs

The guarded write wrappers (`scripts/gh-as-author.sh`, `scripts/gh-as-reviewer.sh`) resolve the author and reviewer tokens from `OP_PREFLIGHT_AUTHOR_PAT` and `OP_PREFLIGHT_REVIEWER_PAT` before anything else. In a cloud session there is no 1Password and no gh keyring, so set these two directly as environment variables.

- **Use dedicated tokens, not the local fleet tokens.** Anyone who can use the environment can read its variables, and a GitHub token cannot be hidden from a cloud session: Claude's API-credentials mechanism explicitly never applies to GitHub. So the mitigation is scope and expiry. Create a separate token per identity with a short expiry, limited to the repositories the environment attaches.
- **Author PAT** (`nathanjohnpayne`) needs to create, comment on and edit pull requests. It does not need to merge: cloud sessions hand merges to a local session, so leave the merge permission off a token the environment can read wherever the token type allows it. **Reviewer PAT** (`nathanpayne-<agent>`) needs to review and comment.
- **Pick the narrowest token type each identity supports.**
  - **Author:** a fine-grained token limited to the attached repositories. The author owns them, so fine-grained access works. The probe reports it `unverifiable` (not granted), but the wrappers accept it.
  - **Reviewers:** a classic token. GitHub does not support fine-grained tokens for contributing to a repository where the account is only a collaborator, which is how the `nathanpayne-<agent>` reviewers reach these repositories ([fine-grained token limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)). For a public repository use `public_repo`, which the probe verifies and which reaches no private repository. Use `repo` only for a private repository, and know what it exposes: `repo` covers every private repository the account can reach, not only the attached ones, so anyone who can read the environment can read and write all of them until the token expires.
- **Leave `GH_HOST` unset (or `github.com`).** Write identity is established for github.com only, so the identity check refuses any other `GH_HOST`.
- **Never rely on the ambient token.** With no token set, `GH_TOKEN` in a Claude cloud session is the placeholder `proxy-injected`. `GET /user` through it reads as your human account, but writes through it land as `claude[bot]`. The wrappers refuse it on its form before any write (`identity-check.sh --expect-write-identity`), so it can never become a write credential. Reading each write's byline back afterwards is tracked separately in nathanjohnpayne/mergepath#1542.

## Claude Code cloud environment

Configure at claude.ai/code, under the environment used for this repository:

- **Environment variables**
  - `OP_PREFLIGHT_AUTHOR_PAT`: author PAT, see above.
  - `OP_PREFLIGHT_REVIEWER_PAT`: reviewer PAT for `nathanpayne-claude`.
  - `MERGEPATH_AGENT=claude`: selects the reviewer identity.
- **Network access:** `Trusted` is enough. GitHub goes through its own proxy whatever the access level. 1Password is not needed and is not on the Trusted list.
- **Setup script:** none required. `gh`, `git`, `jq` and `yq` are pre-installed, and `scripts/cloud-setup.sh` neither replaces nor pins them: it installs `gh` only when it is missing.
- **SessionStart hook:** `scripts/hooks/cloud-session-start.sh` exits immediately unless `CLAUDE_CODE_REMOTE=true`, so local sessions are untouched. In a cloud session it runs the probe and prints the tier. Mergepath wires it in `.claude/settings.json`. `.claude/settings.json` is per-repo and not propagated, so a consumer repo adds the same `SessionStart` entry (`bash "$CLAUDE_PROJECT_DIR/scripts/hooks/cloud-session-start.sh"`) to its own settings. A session with several repositories attached does not load repository hooks, so run the probe by hand there.
- **Provenance:** a cloud session adds a `Claude-Session:` trailer to commits and a session-URL line to PR bodies. Keep them: the PR-body contract (`scripts/lib/pr-body-contract.sh`) accepts them, and they point a reviewer at the run that produced the change.
- **GitHub connection:** connecting through the Claude GitHub App gives the proxy an installation identity (writes land as `claude[bot]`). `/web-setup` instead syncs the gh account that is *active* on your machine. That is a hazard here, because the active account is usually the reviewer identity, so author writes would carry the reviewer's name. Either way, the provisioned PATs above are what the wrappers use.

## Codex cloud environment

Configure at chatgpt.com/codex/cloud/settings/environments:

- **Environment variables, not secrets.** Codex removes secrets before the agent phase starts, so a token stored as a secret is gone by the time a wrapper needs it.
  - `OP_PREFLIGHT_AUTHOR_PAT`, `OP_PREFLIGHT_REVIEWER_PAT`: as above, with the reviewer token for `nathanpayne-codex`.
  - `MERGEPATH_AGENT=codex`: required. The surface variable below does not select the reviewer; without this the wrappers, the probe and the hook all resolve `nathanpayne-claude` and refuse the Codex PAT.
  - `MERGEPATH_AGENT_SURFACE=codex-cloud`: Codex sets no documented marker variable, so without this the probe reports the session as `local` with `surface_source: default`.
- **Setup script:** `bash scripts/cloud-setup.sh`. The `codex-universal` image has no `gh`, and every guarded write goes through it. The script installs a pinned, checksum-verified `gh` release, and does nothing when one is already present. It fails, rather than exiting 0, when the install directory is not on `PATH`; `gh` goes to `<MERGEPATH_TOOL_PREFIX>/bin` (default `/usr/local` when writable, else `~/.local`), so either add that `bin` directory to the environment's `PATH` or set the prefix to the parent of a directory already on `PATH` (for `~/.local/bin`, use `~/.local`; a leading `~/` is read as `$HOME/`).
- **Agent internet access:** on, with `github.com` and `api.github.com` allowed, plus `release-assets.githubusercontent.com` while the setup script runs: a `gh` release download from `github.com` redirects there for the file itself. Do **not** limit HTTP methods to `GET`/`HEAD`/`OPTIONS`, or every write returns 403.
- **Hooks:** `.codex/hooks.json` wires the same PreToolUse guards (`gh-pr-guard.sh`, `label-removal-guard.sh`) Claude uses. It has no SessionStart equivalent, so run `scripts/agent-capability-probe.sh` as the first step of a task.

## When a session hits a ceiling

A session that meets one of the proxy ceilings should not engineer around it inside the sandbox. It should stop with the state it has established and hand the step to a session that can do it:

- **Park the step on the PR.** Run `scripts/post-local-agent-handback.sh <PR#> --blocked <capability> --next "<command>"`. It posts a structured comment: the blocked capability, the tier, the head SHA, the feedback accounting, this session's transcript URL, and the next command. It then labels the PR `needs-local-agent`. The label is informational, never a merge gate. It uses REST only, and its author is the session's reviewer identity, so it works without GraphQL or an author token. If the post itself fails, the rendered comment is printed so it can be relayed another way.
- **GraphQL-only helpers** exit 6 with a message naming the ceiling (`scripts/lib/graphql-ceiling.sh`). Thread resolution is the common case: post the fix and a reply on every thread, then run `scripts/dispatch-thread-resolution-lane.sh <PR#>`. It dispatches the CI lane (`.github/workflows/thread-resolution-lane.yml`), which runs `scripts/resolve-pr-threads.sh --resolve-actioned` from the default branch with the reviewer PAT, then finds the run its own dispatch created and waits for it, exiting non-zero unless that run succeeded. The dispatch goes through the author wrapper, so it uses the provisioned author PAT (Contents: write on a fine-grained token, or `repo` on a classic one), and it is a REST call the proxy allows. The lane is a `repository_dispatch` workflow, which GitHub runs only from the default branch, so a branch cannot substitute its own copy. It sees only GitHub-visible evidence, so the thread reply is required: a verdict recorded only in this session's local feedback ledger is invisible to it, and that thread stays open.
- **Multi-branch pushes and cross-repo work** (propagation waves) belong to a local session. The branch-protection audit is already dispatchable in CI (`.github/workflows/branch-protection-audit.yml`).

Do not repair a missing credential with `op-preflight.sh --mode review`, which triggers a biometric prompt nobody is present to answer.
