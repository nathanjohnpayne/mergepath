# Cloud Agent Environments

> Canonical source: `mergepath/docs/agents/cloud-environments.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy.

How to set up a Claude Code cloud session and a Codex cloud task so they can write under the right identities, what they still cannot do, and how a session tells which case it is in. The design and measurements behind it are in [mergepath#1057](https://github.com/nathanjohnpayne/mergepath/issues/1057).

The environment configuration lives in two web UIs (claude.ai and chatgpt.com) and nowhere in the repository. This document is the committed statement of what those settings must be, so they can be reviewed and reproduced. Only the setting **names** belong here, never their values.

## What a cloud session can and cannot do

**Cloud sessions author, and may merge through the same gates as a local session. CI performs the privileged residue. Fleet operations stay local.**

Merging from a cloud session is a convenience, not a security boundary (decided on mergepath#1057). An author token able to open PRs and dispatch the thread-resolution lane can also merge, so the boundary could not be enforced anyway. What keeps a merge honest is the same in both places: reviewer approval or Phase 4 clearance, a clean conversation gate, and never past `human-hold`.

On Claude cloud, every `gh pr` and `gh issue` subcommand is a GraphQL call, which the proxy refuses whatever the credential (measured 2026-10-04: `gh pr list`, `gh pr checks`, `gh issue view`, `gh repo view`). The wrappers' usual write forms (`gh pr create`, `comment`, `review`, `edit`, `merge`, `gh issue comment`) are those subcommands, so they fail there even with both PATs provisioned. `gh api` REST calls pass. Until the wrappers have a REST path for those verbs (mergepath#1057 item A), the Claude cloud write rows below are blocked in practice.

| Capability | Local | Claude cloud | Codex cloud |
| --- | :---: | :---: | :---: |
| Read the repository and its PRs | yes | yes | yes, with agent internet on |
| Commit and push the session's branch | yes | yes | yes |
| Author writes (`gh pr create`, `gh pr comment` / `edit`) as the author | yes | only as `gh api` REST calls through the wrapper: the `gh pr` forms are GraphQL (see above) | yes, with a provisioned author PAT |
| Reviewer writes (`gh pr review`, `gh pr comment`) as `nathanpayne-<agent>` | yes | only as `gh api` REST calls through the wrapper: the `gh pr` forms are GraphQL (see above) | yes, with a provisioned reviewer PAT |
| Trigger `@codex review` / `@coderabbitai` | yes | yes | yes |
| GraphQL-only helpers (`scripts/resolve-pr-threads.sh`) | yes | **no**: the proxy serves no GraphQL, so they exit 6. `--list` alone reads threads through the proxy's REST thread route instead | unmeasured |
| Push a second branch (propagation waves) | yes | not reliable: the proxy has been seen to accept creating another branch and to refuse deleting one, so keep this work local | unmeasured |
| Reach another repository (consumer fleet) | yes | only the repositories attached to the session; the proxy refuses the rest | unmeasured |
| Edit the repository wiki | yes | **no**: the proxy authorizes only attached repositories, and a wiki cannot be attached | unmeasured |
| Merge to a protected default branch | yes: the agent merges as the author once the merge gates pass, never past `human-hold` | allowed, through the same gates; blocked in practice until the wrappers merge over REST (`gh pr merge` and several gate scripts are GraphQL) | allowed, through the same gates; unmeasured |

The **no** and limited rows are properties of the Claude cloud GitHub proxy, not credential gaps. A better token does not change them. Route that work to a local session or to CI. The proxy's behavior has changed before (its GraphQL refusal went from "This GraphQL query is not enabled for this session" to "GitHub GraphQL is not available from Claude Code sessions"), so where the probe below measures a capability, its answer for the session wins over this table. The proxy also refuses paths no row lists, such as the Actions secrets API.

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
- **Author PAT** (`nathanjohnpayne`) needs to create, comment on, edit and merge pull requests, apply labels, and dispatch the thread-resolution lane: on a fine-grained token, Pull requests, Issues and Contents read and write, plus Metadata read. A cloud session may merge through the same gates as a local one, and the Contents permission the dispatch needs carries merge with it anyway. **Reviewer PAT** (`nathanpayne-<agent>`) needs to review and comment.
- **Pick the narrowest token type each identity supports.**
  - **Author:** a fine-grained token limited to the attached repositories. The author owns them, so fine-grained access works. The probe reports it `unverifiable` (not granted), but the wrappers accept it.
  - **Reviewers:** a classic token. GitHub does not support fine-grained tokens for contributing to a repository where the account is only a collaborator, which is how the `nathanpayne-<agent>` reviewers reach these repositories ([fine-grained token limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)). For a public repository use `public_repo`, which the probe verifies and which reaches no private repository. Use `repo` only for a private repository, and know what it exposes: `repo` covers every private repository the account can reach, not only the attached ones, so anyone who can read the environment can read and write all of them until the token expires.
- **Leave `GH_HOST` unset (or `github.com`).** Write identity is established for github.com only, so the identity check refuses any other `GH_HOST`.
- **Set the commit author, not the committer.** The Claude cloud image's global git config commits as `Claude <noreply@anthropic.com>`, but agents author as the author identity. Set `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` as environment variables; they take precedence over git config. Leave the committer alone: commits whose committer is `noreply@anthropic.com` are signed in the cloud session and show as Verified on GitHub, and a different committer makes them Unverified. Never fix the author with a repository-local `git config user.*`: `check_git_identity_hygiene` refuses that.
- **Never rely on the ambient token.** With no token set, `GH_TOKEN` in a Claude cloud session is the placeholder `proxy-injected`. `GET /user` through it reads as your human account, but writes through it land as `claude[bot]`. The wrappers refuse it on its form before any write (`identity-check.sh --expect-write-identity`), so it can never become a write credential. Reading each write's byline back afterwards is tracked separately in nathanjohnpayne/mergepath#1542.

## Claude Code cloud environment

Configure at claude.ai/code, under the environment used for this repository:

- **Environment variables**
  - `OP_PREFLIGHT_AUTHOR_PAT`: author PAT, see above.
  - `OP_PREFLIGHT_REVIEWER_PAT`: reviewer PAT for `nathanpayne-claude`.
  - `MERGEPATH_AGENT=claude`: selects the reviewer identity.
  - `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`: the author identity's name and commit email. Not the `GIT_COMMITTER_*` pair, see above.
- **Network access:** `Trusted` is enough. GitHub goes through its own proxy whatever the access level. 1Password is not needed and is not on the Trusted list.
- **Setup script:** none required where the SessionStart hook runs. `gh`, `git` and `jq` are pre-installed, but the image's `yq` is the Python jq wrapper, not the mikefarah/yq v4 the scripts and suites use. `scripts/cloud-setup.sh` installs a pinned, checksum-verified mikefarah/yq ahead of it (into `/usr/local/bin`, which comes before `/usr/bin` on the image's `PATH`), installs `gh` only when it is missing, and otherwise changes nothing. In a session where the hook does not run, run `bash scripts/cloud-setup.sh` first.
- **SessionStart hook:** `scripts/hooks/cloud-session-start.sh` exits immediately unless `CLAUDE_CODE_REMOTE=true`, so local sessions are untouched. In a cloud session it runs `scripts/cloud-setup.sh` (bounded to 60 seconds), then the probe, and prints the tier, plus a line for anything setup installed or failed to install. Mergepath wires it in `.claude/settings.json`. `.claude/settings.json` is per-repo and not propagated, so a consumer repo adds the same `SessionStart` entry (`bash "$CLAUDE_PROJECT_DIR/scripts/hooks/cloud-session-start.sh"`) to its own settings. A session with several repositories attached does not load repository hooks, so run the probe by hand there.
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
- **GraphQL calls**, including every `gh pr` and `gh issue` subcommand, are refused. **GraphQL-only helpers** exit 6 with a message naming the ceiling (`scripts/lib/graphql-ceiling.sh`, which recognizes each wording the proxy has used). Listing is the exception: `scripts/resolve-pr-threads.sh <PR#> --list` reads thread state through the proxy's REST thread route (`GET repos/<repo>/pulls/<n>/ccr/review_threads`) and the REST review comments, and fails closed if the two disagree. The proxy also offers a REST route to resolve a thread, but a resolve through it would not run as the reviewer PAT, so resolution stays on the lane. Thread resolution is the common case: post the fix and a reply on every thread, then run `scripts/dispatch-thread-resolution-lane.sh <PR#>`. It dispatches the CI lane (`.github/workflows/thread-resolution-lane.yml`), which runs `scripts/resolve-pr-threads.sh --resolve-actioned` from the default branch with the reviewer PAT, then finds the run its own dispatch created and waits for it, exiting non-zero unless that run succeeded. The dispatch goes through the author wrapper, so it uses the provisioned author PAT (Contents: write on a fine-grained token, or `repo` on a classic one), and it is a REST call the proxy allows. The lane is a `repository_dispatch` workflow, which GitHub runs only from the default branch, so a branch cannot substitute its own copy. It sees only GitHub-visible evidence, so the thread reply is required: a verdict recorded only in this session's local feedback ledger is invisible to it, and that thread stays open.
- **Multi-branch pushes and cross-repo work** (propagation waves) belong to a local session. The branch-protection audit is already dispatchable in CI (`.github/workflows/branch-protection-audit.yml`).
- **Wiki edits** belong to a local session: write the page in the session, hand it over, and push it to `<repo>.wiki.git` from a local checkout.

Do not repair a missing credential with `op-preflight.sh --mode review`, which triggers a biometric prompt nobody is present to answer.
