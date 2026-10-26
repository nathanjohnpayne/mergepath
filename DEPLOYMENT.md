# Deployment

## New Machine Setup

Run these steps on any new or temporary machine. Tell your AI agent:

> "Set up this machine for development. Run the new machine setup from DEPLOYMENT.md."

### 1. Install system tools

```bash
# 1Password CLI
brew install --cask 1password-cli

# Firebase CLI
npm install -g firebase-tools

# Google Cloud SDK
brew install google-cloud-sdk

# GitHub CLI
brew install gh
```

### 2. Authenticate

```bash
# 1Password — enables biometric unlock for op CLI
# (Follow the prompts to sign in and enable Touch ID)
op signin

# GitHub CLI
gh auth login

# Google Cloud — use 1Password-backed ADC (no interactive login needed
# if op is authenticated and the GCP ADC item exists in 1Password)
```

### 3. Install deploy scripts

```bash
# Clone the template repo if not already present
mkdir -p ~/GitHub
git clone https://github.com/nathanjohnpayne/mergepath.git ~/GitHub/mergepath

# Install canonical helper scripts
mkdir -p ~/.local/bin
cp ~/GitHub/mergepath/scripts/gcloud/gcloud ~/.local/bin/
cp ~/GitHub/mergepath/scripts/firebase/op-firebase-deploy ~/.local/bin/
cp ~/GitHub/mergepath/scripts/firebase/op-firebase-setup ~/.local/bin/
chmod +x ~/.local/bin/gcloud ~/.local/bin/op-firebase-deploy ~/.local/bin/op-firebase-setup

# Ensure PATH includes ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### 4. Clone and bootstrap all repos

The full bootstrap loop runs across each repo the bootstrap wizard has provisioned. This list is maintained by the wizard's cross-repo loop step and is **not** the same population as `.mergepath-sync.yml`'s `consumers:` — a repo appears here once it is bootstrapped, but ongoing propagation requires a separate enrollment as a sync consumer (see mergepath#741; the two lists can differ). Archived repos (e.g. `device-platform-reporting`) are removed from this list, since the loop would otherwise clone and bootstrap a read-only repo. Being listed here does **not** mean a repo receives mergepath's post-bootstrap fixes. Bootstrapped repos:

<!-- bootstrap-loop-list-start -->
- friends-and-family-billing
- swipewatch
- nathanpaynedotcom
- overridebroadway
- fiveacross
- matchline
- tadlockpsychiatry
<!-- bootstrap-loop-list-end -->

Run the bootstrap script across all of them:

```bash
# Resolve the repo list FIRST (while pwd is anywhere), THEN cd. The
# awk lookup must point at mergepath's DEPLOYMENT.md explicitly —
# `cd ~/GitHub` doesn't put us inside mergepath, so a bare
# `DEPLOYMENT.md` arg would silently expand to nothing and the loop
# would no-op. See #252 (Codex P1).
repos=$(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
        ~/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/GitHub
for repo in $repos; do
  git clone "https://github.com/nathanjohnpayne/$repo.git" 2>/dev/null || (cd "$repo" && git pull)
  cd "$repo"
  ./scripts/bootstrap.sh    # restores generated config from 1Password templates
  cd ..
done
```

The bootstrap script for each repo:
- Resolves `op://` references in `.env.tpl` → writes `.env.local` (via `op inject`)
- Runs `npm install`
- Runs `npm run build` (if applicable)

For new runtime application secrets, prefer the current 1Password Environments model described in [Runtime 1Password secrets and AI agents](#runtime-1password-secrets-and-ai-agents). Keep `.env.tpl`/`op inject` for repos that still need a generated, gitignored file on disk.

### 5. Verify

```bash
# Quick check that each repo's local config was restored.
# Iterates over the consumer list defined above (§ 4). Repos that don't
# carry .env files no-op via the fallback echo.
# Explicit path to mergepath/DEPLOYMENT.md — pwd may not be the
# mergepath repo (see #252 Codex P1).
for repo in $(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
              ~/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //'); do
  echo "=== $repo ==="
  ls ~/GitHub/$repo/.env* 2>/dev/null || echo "  (no env files expected)"
done
```

---

## Returning to Your Main Machine

When you return from a temporary machine, tell your agent:

> "Sync any changes from this session back. Run the return-to-main workflow from DEPLOYMENT.md."

### 1. On the temporary machine (before leaving)

```bash
# Resolve repo list before cd-ing away from mergepath (see #252 Codex P1).
repos=$(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
        ~/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/GitHub
for repo in $repos; do
  cd "$repo"
  # Do not edit generated env files as the source of truth. If secret
  # values changed, update the referenced 1Password item fields directly.
  # If the shape changed, commit the matching .env.tpl update.
  # Ensure all code changes are committed and pushed
  git status
  cd ..
done
```

### 2. On the main machine (when you return)

```bash
# Resolve repo list before cd-ing away from mergepath (see #252 Codex P1).
repos=$(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
        ~/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/GitHub
for repo in $repos; do
  cd "$repo"
  git pull                          # get code changes from the temp machine
  ./scripts/bootstrap.sh --force    # re-resolve .env.tpl from 1Password (latest values)
  cd ..
done
```

The `--force` flag overwrites existing generated env files with freshly resolved values from 1Password. This ensures you pick up any secret values that were updated directly in 1Password.

### Conflict resolution

If two machines need different template structure, resolve it like normal source code: commit the `.env.tpl` change on one branch and merge/rebase. Secret values themselves should be edited directly in 1Password, not synced from generated local files.

---

## Prerequisites

- [Firebase CLI](https://firebase.google.com/docs/cli) (`firebase-tools`) installed globally
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) installed
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) installed and signed in
- `gcloud`, `op-firebase-deploy`, and `op-firebase-setup` on PATH (see Script Installation below)
- Access to the project SA key in `op://Firebase/{project-id} — Firebase Deployer SA Key` for the legacy resolver described in [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical); this does not authorize production deployment, which remains blocked pending isolated build and verified-artifact tooling
- Permission to create resources in the target Firebase/GCP project and impersonate the deployer service account

## Deploy credential precedence (canonical)

This section records legacy credential-resolution behavior; it does not authorize production deployment. The current `scripts/deploy.sh` builds candidate code and invokes deployment in the same environment, while neither it nor `--skip-build` verifies an immutable artifact's digest and repository/full-revision attestation before acquiring credentials. Production deployment is blocked until separately reviewed tooling provides a credential-free build and trusted post-build artifact verification and deployment. That tooling must deploy the verified artifact without rebuilding or executing the candidate checkout.

For the legacy `scripts/deploy.sh` and underlying `op-firebase-deploy`, the source-credential resolution order is:

1. **Genuine human-supplied override** — `GOOGLE_APPLICATION_CREDENTIALS` set by the human OUTSIDE preflight (no `OP_PREFLIGHT_FIREBASE_SA_TMPFILE` or `OP_PREFLIGHT_ADC_TMPFILE` marker matching the same path). This is a legacy resolver path for one-off debugging or alternate-account use; it is not production deployment authorization and must never be present during candidate builds.
2. **Project Firebase-vault SA key** — `op://Firebase/{project-id} — Firebase Deployer SA Key`, when present. This remains the legacy wrapper's configured source and has historically been used in interactive and CI flows. In a repo with a `.firebaserc` default project, `scripts/op-preflight.sh --mode deploy` caches this key first and exports `OP_PREFLIGHT_FIREBASE_SA_TMPFILE` / `OP_PREFLIGHT_FIREBASE_PROJECT`.
3. **Preflight-injected shared ADC** — legacy `scripts/op-preflight.sh --mode deploy` materializes the shared 1Password ADC into a tempfile and exports its path as `OP_PREFLIGHT_ADC_TMPFILE` when no project key is found. A deploy-mode cache hit can also export both review PATs from the shared session file, and evaluation exposes exports to the caller's whole shell; this mode is not approved for deployment. The legacy runtime still supports `--mode all`, including exporting PATs when deploy credentials are unavailable; do not use `--mode all` for builds or deployment. No current preflight mode is approved for deployment; production remains blocked until separately reviewed tooling verifies an immutable artifact and scopes only deploy credentials to the consuming subprocess.
4. **Shared 1Password ADC read directly** — `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential`, read by the script when neither preflight nor an SA key are available. Same RAPT-expiry surface.
5. **Local ADC file** — `~/.config/gcloud/application_default_credentials.json` from a prior `gcloud auth application-default login`. Last resort.

`op-firebase-deploy` logs the selected source on stderr: `[op-firebase-deploy] source credential: ...`. Deploy auth debugging is no longer opaque — read the line to know which step won.

This precedence documents the legacy `op-firebase-deploy` runtime ONLY and does not authorize production deploys. The legacy preflight's credential preference is narrower: project Firebase-vault SA key, then shared ADC. General `gcloud` commands go through the local `gcloud` wrapper at `scripts/gcloud/gcloud`, which uses a narrower 3-step chain — `GOOGLE_APPLICATION_CREDENTIALS` if set, else the shared 1Password ADC (`op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential`), else the local ADC file. The full legacy deploy-wrapper precedence above additionally includes the genuine human-supplied override before its project SA key, preflight-injected shared ADC, direct shared ADC, and local ADC fallbacks. The `gcloud` wrapper does NOT consult the per-project Firebase-vault SA key; that step is specific to `op-firebase-deploy`. Quota attribution for `gcloud` commands is resolved separately from explicit flags / `.firebaserc` / active config rather than from the deploy script's project pin.

### Trade-off

The following bullets record the historical rationale for the legacy resolver, not current production-deployment approval. That precedence shifted the former day-to-day human deploy path from "impersonation-first via shared ADC" to "stored per-project SA key first."

- **Historical rationale.** The per-project SA key was chosen for bounded project scope, 1Password storage, rotation, and reduced shared-ADC reauth friction; the choice does not establish build/deploy isolation or authorize production deployment.
- **Historical trade-off.** The legacy resolver stores the SA key in 1Password rather than relying only on ephemeral impersonated credentials; this remains an auth implementation detail, not production-deployment approval.
- **Rotation.** Legacy resolution picks up a replacement SA key from the 1Password item, but routine rotation is incomplete until a separately reviewed non-deploying validator proves the replacement usable; see [Rotating a Firebase deploy SA key](#rotating-a-firebase-deploy-sa-key). Suspected-compromise containment is a separate owner incident decision.

## Script Installation

The canonical helper scripts live in this template repo. Install them once per machine:

The commands below document legacy wrapper syntax only; they are not approved production deployment procedures while the required isolated build and verified-artifact tooling is absent.

```bash
# From the mergepath directory:
mkdir -p ~/.local/bin
cp scripts/gcloud/gcloud ~/.local/bin/gcloud
cp scripts/firebase/op-firebase-deploy ~/.local/bin/
cp scripts/firebase/op-firebase-setup ~/.local/bin/
chmod +x ~/.local/bin/gcloud ~/.local/bin/op-firebase-deploy ~/.local/bin/op-firebase-setup
```

Ensure `~/.local/bin` is on your `PATH` (add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` if needed), then run `hash -r` or open a new shell.

These scripts are the canonical source. If you update the installed copies on your machine, sync the same changes back to this repo.

## New Project Setup

Do this once when creating a project from scratch. Skip if the Firebase project already exists.

### 1. Create the Firebase project

```bash
firebase projects:create {project-id} --display-name "{Display Name}"
```

Or create it in [Firebase Console](https://console.firebase.google.com/) → Add project.

### 2. Enable Firebase services

In [Firebase Console](https://console.firebase.google.com/project/{project-id}), enable whichever services the project needs:

- **Hosting** — always required
- **Firestore** — if the app uses a database (start in production mode)
- **Authentication** — if the app has user sign-in
- **Cloud Functions** — requires Blaze (pay-as-you-go) billing plan
- **Storage** — if the app stores files

### 3. Initialize the repository

From the repository root:

```bash
firebase init
```

When prompted:
- Select the services to configure (Hosting, Firestore, Functions, Storage — match what you enabled above)
- **Use existing project** → select `{project-id}`
- **Public directory**: `dist` (or `out` for Next.js static export, `.` for no-build static sites)
- **Configure as single-page app**: Yes (if the app uses client-side routing)
- **Set up automatic builds**: No
- **Overwrite existing files**: No (if any already exist)

This creates `firebase.json` and `.firebaserc`. Commit both.

### 4. Set up the deployer service account

```bash
op-firebase-setup {project-id} --provision-sa-key
```

See [First-Time Setup](#first-time-setup) for details. This creates the `firebase-deployer` service account, grants the necessary deploy roles, configures impersonation as a fallback path, and (with `--provision-sa-key`) mints the deployer SA key and uploads it to `op://Firebase/{project-id} — Firebase Deployer SA Key`. The flag is opt-in; without it, the script does impersonation-only setup and leaves SA-key provisioning as a documented manual step.

### 5. Provision the Firebase-vault SA key (preferred default)

If you ran step 4 with `--provision-sa-key`, the SA key is already in 1Password and you can skip to step 6. Otherwise, follow [§ Secrets Management → Provisioning the Firebase-vault SA key](#provisioning-the-firebase-vault-sa-key) to provision the legacy resolver's source credential. The key-first precedence was adopted in #154 to avoid recurring `firebase login --reauth` friction (#137) caused by RAPT/refresh-token expiry on the shared 1Password ADC; it does not authorize production deployment.

Impersonation remains as a fallback path; it kicks in when the project SA key isn't provisioned yet.

If `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` does not exist yet, seed it once by running `gcloud auth application-default login`, then copy `~/.config/gcloud/application_default_credentials.json` into the 1Password item `Private/GCP ADC`, field `credential`. The shared ADC is rank-4 fallback in the `op-firebase-deploy` resolver.

---

## Machine User Setup (New Project)

When creating a new repository from this template, complete these steps to enable the AI agent cross-review system. All steps are manual (human-only) unless noted.

### 1. Add machine users as collaborators

Go to the new repo → Settings → Collaborators → Invite each:

- `nathanpayne-claude` — Write access
- `nathanpayne-codex` — Write access
- `nathanpayne-cursor` — Write access

### 2. Accept collaborator invitations

Log into each machine user account and accept the invitation:

- https://github.com/notifications (as `nathanpayne-claude`)
- https://github.com/notifications (as `nathanpayne-codex`)
- https://github.com/notifications (as `nathanpayne-cursor`)

Alternatively, use `gh` CLI or the invite URL directly: `https://github.com/{owner}/{repo}/invitations`

**Note:** Fine-grained PATs cannot accept invitations via API. Use the browser or a classic PAT with `repo` scope.

### 3. Store routine PATs and protect queue credentials

Go to the new repo → Settings → Secrets and variables → Actions → New repository secret. Add only the routine CI credentials:

| Secret name | Value | PAT type |
|---|---|---|
| `REVIEWER_ASSIGNMENT_TOKEN` | PAT for a **reviewer identity** (e.g., `nathanpayne-claude`) — NOT `nathanjohnpayne` | Classic with `repo` scope (collaborator account) |
| `CI_ACTOR_TOKEN` | PAT for the **CI service account** (`nathanpayne-robot`) — holds no reviewer standing | Classic with `repo` scope (service account) |

Before enabling Dependabot auto-merge or #1058, create the target Actions environment `merge-queue-policy`. Disable administrator bypass, configure no required reviewers and no wait timer, select custom deployment branches, and allow exactly one branch named `main`. Store exactly these three pairwise-distinct values as environment secrets, never as repository or organization secrets:

| Secret name | Value | PAT type |
|---|---|---|
| `AUTHOR_MERGE_TOKEN` | PAT for the **author identity** (`nathanjohnpayne`) used by trusted `pull_request_target`, `workflow_run`, scheduled, and protected `repository_dispatch` paths | Fine-grained, this repository only: `Contents` and `Pull requests` read and write; `Issues`, `Actions`, `Commit statuses` and `Administration` read; plus automatic `Metadata: read`. One token per repository, from its own 1Password item; see [`specs/author_merge_token.md`](specs/author_merge_token.md). Until a repository cuts over, the shared classic `repo`-scope author PAT |
| `MERGE_QUEUE_POLICY_TOKEN` | Distinct PAT for the **author identity** (`nathanjohnpayne`) used only by #1058 target-topology read operations (REST `GET` plus fixed GraphQL) | Fine-grained, selected target repository only; organization `Administration: write`; target repository `Administration: write`, `Actions: read`, `Secrets: read`, `Environments: read`, `Contents: read`, `Issues: read`, `Pull requests: read`, plus automatic `Metadata: read` |
| `MERGE_QUEUE_SOURCE_TOKEN` | Distinct PAT for the **author identity** (`nathanjohnpayne`) used only by #1058 reads against the public policy-source repository | Fine-grained, selected policy-source repository only; `Actions: read`, plus automatic `Metadata: read` |

Candidate-controlled workflows must reference none of these three secret names. The trusted jobs that consume them must declare `environment: merge-queue-policy`; an environment secret is not available merely because a repository workflow names it.

The `dependabot-auto-merge.yml` workflow uses `REVIEWER_ASSIGNMENT_TOKEN` to post the reviewer-identity `--approve`. It MUST be a reviewer-identity PAT (`nathanpayne-claude` / `-cursor` / `-codex`), not `nathanjohnpayne` — GitHub rejects self-approval, and the workflow's preflight guards hard-fail if the token resolves to the author identity OR to any login not in `.github/review-policy.yml` `available_reviewers`. The `gh pr merge` itself runs under `AUTHOR_MERGE_TOKEN` (see below) so the merge is recorded under `author_identity`. See nathanjohnpayne/mergepath#179 and #426 for the audit-trail rationale.

`CI_ACTOR_TOKEN` carries the CI-actor half of what `REVIEWER_ASSIGNMENT_TOKEN` used to do alone: reviewer assignment, gate-label writes, dispatches, and review reads in `agent-review.yml`, `auto-clear-blocking-labels.yml`, and `pr-review-policy.yml`. Those workflows read it as `${{ secrets.CI_ACTOR_TOKEN || secrets.REVIEWER_ASSIGNMENT_TOKEN }}`, so it is **optional**: leave it unset and the workflows fall back to the reviewer PAT exactly as before. Setting it moves that repo's routine CI activity onto the service account, which separates the audit trail from agent judgment and — because rate limits are per-account — stops scheduled CI competing with interactive agent sessions for one 5,000 req/hr bucket. `auto-clear-blocking-labels.yml` alone runs on a `*/5` cron, so it is the largest single draw. The service account needs write access on the repo. It must **never** hold reviewer standing: `dependabot-auto-merge.yml` deliberately stays on `REVIEWER_ASSIGNMENT_TOKEN` because it posts an approving review, and a service-account `APPROVED` would trip the `non_reviewer_identities` block in `scripts/merge-clearance-gate.sh`. See nathanjohnpayne/mergepath#1097 and #1071.

Or use the CLI (faster):

```bash
# Substitute the 1Password item ID for whichever reviewer identity
# you choose to use as the CI approver (claude / cursor / codex).
# The full lookup table is in REVIEW_POLICY.md § PAT lookup table.
gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo} --body "$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')"   # nathanpayne-claude
gh secret set CI_ACTOR_TOKEN --repo {owner}/{repo} --body "$(op read 'op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token')"   # nathanpayne-robot (CI service account; optional)

# Run these only after the protected environment above exists and its exact
# main-only policy has been read back.
gh secret set AUTHOR_MERGE_TOKEN --env merge-queue-policy --repo {owner}/{repo} --body "$(op read 'op://Private/<author-token-item-id>/token')"   # this repository's fine-grained nathanjohnpayne PAT (specs/author_merge_token.md)
gh secret set MERGE_QUEUE_POLICY_TOKEN --env merge-queue-policy --repo {owner}/{repo} --body "$(op read 'op://Private/<merge-queue-policy-token-item-id>/token')"   # pairwise-distinct target policy PAT
gh secret set MERGE_QUEUE_SOURCE_TOKEN --env merge-queue-policy --repo {owner}/{repo} --body "$(op read 'op://Private/<merge-queue-source-token-item-id>/token')"   # pairwise-distinct source-only PAT
```

`AUTHOR_MERGE_TOKEN` is **required** wherever Dependabot auto-merge or #1058's trusted observer and final-auditor lanes are enabled: as of nathanjohnpayne/mergepath#426 the Dependabot workflow uses it for the `gh pr merge` step (recording `mergedBy` as `author_identity`) and hard-fails if it is empty or resolves to anything other than `author_identity`. For #1058 the trusted observer writes only the author-attributed exact-head enable marker and exact post-enqueue entry attestation, while the protected target `repository_dispatch` auditor writes only the nonce-bound final-audit marker after live policy checks. The organization required workflow's admission, merge-group precheck, and merge-group postcheck jobs use read-only `github.token`; its only elevation is job-scoped `contents: write` in the intervening source-pinned handshake, solely to send one same-repository dispatch. `AUTHOR_MERGE_TOKEN` never licenses Agent Review or any #1058 workflow to arm, enqueue, dequeue, directly merge, disable non-Dependabot auto-merge, or alter queue/protection settings.

`MERGE_QUEUE_POLICY_TOKEN` is a separate **author-owned fine-grained PAT** required before #1058 activation, by every live `enqueued` observer attestation, and by every protected final administrative audit. Restrict its repository selection to the target repository only. Grant organization `Administration: write`, target-repository `Administration: write`, target `Actions: read`, `Secrets: read`, `Environments: read`, `Contents: read`, `Issues: read`, `Pull requests: read`, and automatic `Metadata: read`. The administration write scopes are required because GitHub's exact `GET /orgs/{org}/rulesets/{workflow_ruleset_id}` and `GET /repos/{owner}/{repo}/rulesets/{repository_ruleset_id}` endpoints withhold `bypass_actors` without the corresponding ruleset write access. The additional read scopes are required for exact environment, custom-branch-policy, and complete repository/inherited-organization/environment secret-inventory reads. Every #1058 operation using this token is read-only through REST `GET` requests or fixed GraphQL queries; no #1058 command may call a ruleset, environment, secret, repository, or GraphQL mutation with it, and neither administration scope may be silently added to `AUTHOR_MERGE_TOKEN`.

`MERGE_QUEUE_SOURCE_TOKEN` is a second **author-owned fine-grained PAT** required before #1058 activation, by every live `enqueued` observer attestation, and by every protected final administrative audit. Restrict its repository selection to the separately protected public policy-source repository only, with `Actions: read` and automatic `Metadata: read`. It verifies the exact source repository and both exact workflow identities and `disabled_manually` states without adding source access to `MERGE_QUEUE_POLICY_TOKEN`. The source must be organization-owned and public for every target visibility because the write-authority handshake fetches its exact SHA without credentials. Before rollout, compare all three credential values for pairwise distinction, probe both fine-grained tokens with `GET /user`, and require each to resolve to the governing author. Then read the exact environment plus all three secret inventories and require the three names to appear only in the environment, exactly once each. Any mismatch stops rollout.

**`REVIEWER_ASSIGNMENT_TOKEN` is the only reviewer-identity PAT stored as a repo CI secret.** It exists specifically because the Dependabot auto-merge + Agent Review Pipeline workflows run inside GitHub Actions where there's no interactive `op read`. Pick ONE of the reviewer identities (claude / cursor / codex) and use its PAT for this slot — the workflow validates the resolved identity against `available_reviewers` and rejects anything else.

For Phase 2 internal self-peer review (the back-and-forth that happens during a review session), the OTHER two reviewer-identity PATs are NOT stored as repo CI secrets. Phase 2 runs in the agent's own session: the agent switches its Git identity to its reviewer account with a PAT read directly from 1Password (`op read 'op://Private/<item-id>/token'`) and posts the review with that PAT. See REVIEW_POLICY.md § Phase 2 and each repo's `CLAUDE.md` / `AGENTS.md` for the identity-switch procedure.

**Do NOT add `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `CLAUDE_PAT` / `CODEX_PAT` / `CURSOR_PAT` as repo secrets.** An earlier iteration of `agent-review.yml` had an `invoke-reviewer` job that ran the Claude Code CLI headlessly as a CI-side reviewer; this was the wrong flow (parallel to the authoring session, stale-API-key failure surface, duplicate work) and was removed. Phase 2 now lives entirely inside the authoring agent's session.

### 4. Configure branch protection

Go to the new repo → Settings → Branches → Add branch protection rule for `main`:

1. **Require pull request reviews before merging:** Yes
2. **Required number of approving reviews:** 1
3. **Dismiss stale pull request approvals when new commits are pushed:** Yes
4. **Require status checks to pass before merging:** Yes
   - Add `Self-Review Required`
   - Add `Label Gate`
5. **Do not allow bypassing the above settings:** Disabled (so Nathan can force-merge in emergencies)

Or use the CLI:

```bash
gh api --method PUT "repos/{owner}/{repo}/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      {"context": "Self-Review Required"},
      {"context": "Label Gate"}
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null
}
EOF
```

**Note:** Branch protection requires the repo to be public, or requires GitHub Pro/Team for private repos.

#### Optional #1058 native merge-queue rollout

Every repository is dark by default: absent policy keys mean `disabled`, and the bootstrap configuration above is not queue-ready. No #1058 workflow configures protection, changes the native queue, or arms a PR. Activate only through the staged procedure in [`specs/merge_group_required_checks.md`](specs/merge_group_required_checks.md):

1. Merge the reviewed implementation through the existing ordinary one-shot manual author path while rollout is `disabled`, repository native auto-merge is off, the queue is empty, and no non-Dependabot PR has a live arm. The target must contain zero ordinary `merge_group` triggers. No agent performs this merge.
2. Before transferring the target or beginning any source-repository work, live-verify that the destination organization has current GitHub Enterprise entitlement sufficient to create organization-level rulesets in `evaluate`. If that entitlement cannot be positively verified, stop the rollout without transferring the target or creating the source repository. After a positive verification, transfer the target and record its post-transfer numeric repository id.
3. Create and separately protect an organization-owned **public** policy repository. Public visibility is mandatory for every target visibility because the write-authority handshake fetches the exact source SHA without credentials. Materialize its authorization and repo-lint required workflows, exact-byte audit both plus the handshake executable against their reviewed canonical sources, and record the source repository id, protected ref, full SHA, and exact paths. Set its Actions access to **Accessible from repositories in the organization**. Individually disable both materialized workflows and read back each state as `disabled_manually`, so source-repository pull requests cannot execute target-only jobs. Keep repository Actions available for organization ruleset use; disabling Actions for the repository is not an allowed substitute.
4. Create two rulesets in `evaluate`. The repository-level ruleset targets only literal `refs/heads/main`, has no bypass actors, and contains exactly one singleton `ALLGREEN` `merge_queue` rule. The organization-level ruleset targets the recorded target repository id and literal `refs/heads/main`, has no bypass actors, and contains exactly one `workflows` rule with the two source-repository-id, exact-path, protected-ref, full-SHA entries. Replace the generic bootstrap branch protection before activation: require exactly `Label Gate`, `Self-Review Required`, `CodeRabbit unresolved blocking findings`, `Codex P1 unresolved threads`, `Merge clearance gate`, and `lint`; pin every check to the GitHub Actions app; enable strict status-check freshness and administrator enforcement; dismiss stale approvals; allow no user, team, or app pull-request-review bypass; and require conversation resolution. Exact-byte verify the target `main` final-auditor workflow and recorder, including job-level actor/repository/action/ref/base/workflow guards before environment access. Create `merge-queue-policy` with administrator bypass disabled, no required reviewers or wait timer, custom deployment branches enabled, and exactly one branch named `main`. Provision the three pairwise-distinct environment-only secrets with the selections and permissions documented above; remove or reject any same-named repository or organization secret. Verify both read tokens resolve to the governing author. Under `MERGE_QUEUE_POLICY_TOKEN`, use only read-only REST `GET` requests and fixed GraphQL queries to read the exact environment and custom branch policy, complete repository/inherited-organization/environment secret inventories, the complete classic branch-protection object, `GET /repos/{owner}/{repo}/rulesets/{repository_ruleset_id}`, and `GET /orgs/{org}/rulesets/{workflow_ruleset_id}`. Require exact branch protection and environment policy, exactly the three names in the environment only, and a present non-null array-valued `bypass_actors` in both rulesets. Under `MERGE_QUEUE_SOURCE_TOKEN`, probe the exact public source repository and both exact source-workflow endpoints and require the recorded identities and `disabled_manually` states. Missing, shadowing, duplicate, equal-valued, or under-scoped credentials, identity mismatch, a private source, an unreadable endpoint, or any absent, null, or non-array bypass value stops rollout. Verify both evaluated matches and effects before promotion.
5. Reopen and synchronize the old canary PR before freezing its exact head, reserve a distinct transition PR number, and merge the exact canary policy through the ordinary manual path with a safely future `merge_queue_enabled_at`. Any later canary-head change requires another preactivation policy update.
6. Before activation, make the organization workflow ruleset `ACTIVE` first. Repeat its exact detail read under `MERGE_QUEUE_POLICY_TOKEN`, require `bypass_actors` to be an empty array, and prove its effective `workflows` rule on `refs/heads/main`. Only after that succeeds make the repository queue ruleset `ACTIVE`, repeat its exact detail read, require its `bypass_actors` to be an empty array, and prove the two rulesets jointly appear in the target's effective rules with their configured ids and sources. Repeat the exact public source, target final-auditor, environment, and complete three-scope secret-inventory readbacks. Adding required workflows does not run them on already-open PRs, so reopen or synchronize both the canary and the predeclared transition after activation and verify fresh pull-request-leg runs on each exact head. Draft admission is neutral, but both PRs must be non-draft before enrollment; neither may use a SHA-like head branch or belong to a stack. Only after those proofs and at or after `merge_queue_enabled_at` may the owner enable repository native auto-merge. Re-audit an empty singleton queue with no live arms. A future-dated policy does not authorize early enrollment.
7. At or after activation, hold another controlled required check pending so the canary cannot merge immediately. Let only the human owner create a deferred native arm, prove REST `auto_merge` and GraphQL `autoMergeRequest` are non-null and the trusted `auto_merge_enabled` observer wrote the exact-head marker, then enqueue the exact head. The trusted `enqueued` observer must revalidate the live queue action, full administrative topology, protected environment, complete secret inventories, and public source workflows before writing the exact entry attestation; the read-only external precheck bounded-polls for that attestation while rechecking the entry, group ref, and blockers. Prove queue entry clears both arm fields to `null`. A retained arm, missing attestation, exhausted poll, or topology drift stops rollout. Prove the exact-SHA source-pinned handshake fetched the public source without credentials, sent exactly one nonce-bound same-repository `repository_dispatch`, and did not retry ambiguity. Require the resulting target auditor run's `actor.login` and `triggering_actor.login` to be exactly `github-actions[bot]`; require its exact `main`/base/workflow guards to pass before environment secrets, its three credentials to be pairwise distinct and environment-only, its private topology/action/queue rereads and unique author marker to clear, and the external handshake to bind that marker to the exact successful time-bound run. The read-only postcheck must then replay every public predicate and complete the final binding fence. From dispatch through native merge, freeze every mutable ruleset, branch-protection, environment/secret, target/source-workflow, rollout, PR/review/comment/thread/accounting, check/status, queue/action, default-base, and group input; any mutation ejects or aborts the entry and requires a fresh owner action and merge group. After authorization succeeds while the controlled check remains pending, add `human-hold` and prove native ejection without a merge. The human owner removes the hold and proves the old authorization cannot re-enroll the PR without a fresh owner action. Inspect owner attribution, pull-request admission, both observer events, all three author markers/attestations, precheck/handshake/postcheck identities and evidence, base movement, conflict/ejection, joint effective-rule stability, environment/secret-placement stability, and fresh-action behavior. Any missing fresh workflow run, failed ejection, unexpected merge, or automatic re-enrollment stops rollout. No agent arms, enqueues, merges, or removes `human-hold` from the implementation, policy, canary, or transition PR.
8. Use the predeclared transition PR only for an exact selector-clearing state change. It may enter `enabled` while retaining the original activation instant only after the exact canary head is proven merged, or it may enter `disabled` with an empty activation instant without that prerequisite. Only the human owner arms, enqueues, or merges it. Enabled mode accepts only ordinary PRs created at or after activation.
9. For rollback, keep both rulesets `ACTIVE` while the validated `disabled` transition is admitted. After default-branch policy is disabled, disable native auto-merge, drain the queue, and prove no live arms remain. Remove the repository queue ruleset only after those readbacks, and keep the organization workflow ruleset active until the queue is disabled and drained and the repository queue rule is gone; only then remove the organization workflow rule or source-policy settings.
10. Treat target workflow maintenance as a new rollout. While canary/enabled, PR admission rejects every `.github/workflows/**` delta before queue admission through the immutable exact-base/exact-head Git tree comparison; an unavailable head fails closed, and the stable paginated destination/rename inventory is defense in depth only. This prevents a target workflow from consuming `merge_group` secrets before the trusted group gate can reject it. First merge the `disabled` transition under both active rulesets, disable and drain the queue, prove no live arms, remove the repository queue rule, and only then remove the organization workflow rule before merging the fully reviewed workflow change manually. Then repeat the zero-target-`merge_group` proof, audit, both `evaluate` rulesets, future-dated policy, organization-workflow activation first, repository-queue activation second, fresh canary and transition runs, and owner-driven live canary before reactivation.

Every rollout step above is manual and changes external repository or organization state outside this implementation PR. No workflow or helper in #1058 creates, promotes, removes, or otherwise performs the rollout of either ruleset.

Issue #1099 cleanup has no non-Dependabot disable mutation because GitHub provides no conditional disable or compare-and-swap primitive. An exact queue-proven arm remains intact; every other armed state, including `rc 4`, `rc 3`, `rc 5`, a missing helper or credential, a stale trusted base, a blocker, unreadable topology, or a newer simulated arm, remains untouched and returns nonzero for explicit human/admin disposition. An unarmed state continues. The bootstrap bypass note below is not a #1058 rollout or rollback option: activated queue topology permits no bypass actors.

**Known issue:** The `Self-Review Required` and `Label Gate` status checks are configured as required but may never report if the CI workflows that post them (`pr-review-policy.yml`) fail silently due to misconfigured repository secrets. This blocks all merges. Workarounds:
- Fix the CI secrets so status checks report, **or**
- Use the GitHub web UI "Merge without waiting for requirements" bypass checkbox

The `--admin` flag on `gh pr merge` can bypass merge requirements, including required status checks; the scoped authorization procedure does not make failing checks pass. The scoped break-glass path requires `BREAK_GLASS_ADMIN=<canonical-PR-URL>@<full-head>`, an explicit version-1 `MERGEPATH_OWNER_ADMIN_AUTHORIZATION` JSON record, and a matching `--match-head-commit`. The record quotes the owner instruction and names the exact PR/head, UTC authorization time, and explicit `allow_needs_human_review` / `allow_codex_inflight` booleans. Use `scripts/gh-as-author.sh` to record and verify that authorization before the merge; the blanket `BREAK_GLASS_ADMIN=1` form is refused. Neither `human-hold` nor `policy-violation` permits this exception. See `specs/owner_admin_override.md` for the record schema.

### 5. Create required labels

The workflows expect these labels to exist. Create them if they don't:

```bash
gh label create "needs-external-review" --color "D93F0B" --description "Blocks merge until external reviewer approves" --repo {owner}/{repo}
gh label create "needs-human-review" --color "B60205" --description "Agent disagreement — requires human review" --repo {owner}/{repo}
gh label create "policy-violation" --color "000000" --description "Review policy violation detected" --repo {owner}/{repo}
gh label create "audit" --color "FBCA04" --description "Weekly PR audit report" --repo {owner}/{repo}
```

### 6. Verify setup

Run these checks after completing the steps above:

```bash
REPO="{owner}/{repo}"

# Check collaborators
echo "=== Collaborators ==="
gh api "repos/$REPO/collaborators" --jq '.[].login'

# Check secrets exist
echo "=== Secrets ==="
gh secret list --repo "$REPO"

# Check branch protection
echo "=== Branch Protection ==="
DEFAULT=$(gh api "repos/$REPO" --jq '.default_branch')
gh api "repos/$REPO/branches/$DEFAULT/protection/required_status_checks" --jq '.checks[].context'

# Check labels
echo "=== Labels ==="
gh label list --repo "$REPO" --search "needs-external-review"
gh label list --repo "$REPO" --search "needs-human-review"
gh label list --repo "$REPO" --search "policy-violation"
```

### Token type: classic PATs required

Machine user reviewer identities (nathanpayne-claude, etc.) are **collaborators**, not repo owners. GitHub fine-grained PATs on personal accounts only cover repos owned by the token account — they cannot access collaborator repos. The "All repositories" scope in fine-grained PATs means all repos the account *owns* (zero for collaborators), not repos they collaborate on.

**Use classic PATs with `repo` scope for all reviewer identities.** This is stored in 1Password with the field name `token` (not `credential` or `password`).

**Canonical PAT lookup table:** see [REVIEW_POLICY.md § PAT lookup table](REVIEW_POLICY.md#pat-lookup-table). The single source of truth for agent-to-item-ID mappings lives there, alongside the cached `$OP_PREFLIGHT_*_PAT` env-var conventions. Routine work should use the cached env vars (no biometric per call); the inline `op read` form is a setup-only fallback documented in the same section.

All 1Password items in that table are classic PATs with the `ghp_` prefix, stored with field name `token` in the `Private` vault.

Use the item ID (not the item title) to avoid shell issues with parentheses in 1Password item names like `GitHub PAT (pr-review-claude)`.

### Reviewer PAT quick check

The canonical convention is in `REVIEW_POLICY.md` § Reviewer PAT Quick Start. Short form:

- **Read paths** (`gh api user`, GETs, `gh pr view`) honor `GH_TOKEN`.
- **Core guarded writes** (`gh pr create`, `gh pr merge`, `gh pr edit`, `gh pr comment`, `gh pr review`, `gh issue comment`) use `scripts/gh-as-author.sh` or `scripts/gh-as-reviewer.sh`, which verify the effective token before the write.

```bash
# Read-path identity check (PRIMARY — uses cached PAT, no biometric).
GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq '.login'
# expected: nathanpayne-<agent>

# Reviewer write path: wrapper verifies the reviewer token.
GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> \
  scripts/gh-as-reviewer.sh -- gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

# Author write path: wrapper verifies the author token.
scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch
```

> **⚠️ Fallback / setup-only:** the inline `GH_TOKEN="$(op read 'op://Private/<item-id>/token')"` form triggers a biometric prompt on **every** invocation. Use only when `op-preflight.sh` is unavailable. Routine agent work should always use the cached `$OP_PREFLIGHT_REVIEWER_PAT` env var after a one-time `eval "$(scripts/op-preflight.sh --agent <agent> --mode review)"`.

- Use the item ID from the table above for your agent identity. Do not use the 1Password item title.
- Verify token identity with `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login` or by letting the wrappers call `identity-check.sh --expect-write-identity` before the write.
- On local interactive machines, the `op read` command itself may trigger the 1Password biometric prompt even if `op whoami` says you are not signed in.
- `Review Can not approve your own pull request` means the PR author is wrong, the reviewer token resolved to the author identity, or the no-self-approve scoping rule applies (Phase 4 / above-threshold PRs only — see REVIEW_POLICY.md § No-self-approve scoping). For under-threshold PRs the reviewer identity is allowed and expected to `--approve`.

### Token rotation (as needed)

The current PATs are set to never expire. If you ever need to rotate a reviewer identity PAT (`nathanpayne-claude`, `nathanpayne-codex`, `nathanpayne-cursor`):

1. Generate a new **classic** PAT with `repo` scope for the machine user account
2. Update the `token` field on the corresponding 1Password item
3. Revoke the old token in GitHub
4. Verify agent access still works: `GH_TOKEN="$(op read 'op://Private/<item-id>/token')" gh api user`

Note: reviewer identity PATs are NOT stored as repo CI secrets. They are read from 1Password per-session by the authoring agent for the in-session identity switch, so rotation does not require updating any repo secrets.

The `REVIEWER_ASSIGNMENT_TOKEN` repo secret (a **reviewer-identity** PAT used by the Dependabot auto-merge approval + Agent Review Pipeline workflows; see the repository-secret table above) follows a similar process but also needs a `gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo}` call on every repo after rotating the 1Password item. `CI_ACTOR_TOKEN` is likewise repository-scoped. The three pairwise-distinct queue credentials rotate only through `gh secret set ... --env merge-queue-policy --repo {owner}/{repo}` after the protected environment has been revalidated; never create repository- or organization-scoped copies. After any rotation, repeat the value-distinction checks, both read-token identity probes, exact ruleset and public source-workflow probes, target final-auditor identity, exact environment/custom-branch readback, and complete repository/inherited-organization/environment secret-inventory proof before allowing another arm. The organization required workflow's admission, precheck, and postcheck jobs are read-only; only its exact-SHA source-pinned handshake receives job-scoped `contents: write`, solely for one same-repository dispatch. No #1058 use grants Agent Review queue, direct-merge, or non-Dependabot disable authority. Because the CI token rotates on its own schedule for one purpose, rotating it cannot break a reviewer byline, and rotating a reviewer PAT cannot break CI — the coupling that caused the 2026-08-21 fleet outage (#1071).

---

## Environments

| Environment | Firebase Project | URL |
|-------------|-----------------|-----|
| Production | `{project-id}` | https://{project-id}.web.app |

There is no staging environment by default. All deploys go directly to production unless the repo adds preview channels or a separate project.

## Build Process

```bash
npm run build
```

Build output goes to `dist/`. Never edit `dist/` directly.

## Deployment Steps

The existing `scripts/deploy.sh` wrapper is legacy tooling, not an approved production deploy entry point: it builds candidate code in the same environment that later receives deploy credentials, and its branch/freshness/clean-tree guards do not establish artifact isolation or attestation. Do not run `scripts/deploy.sh`, `npm run deploy`, or direct Firebase deploy commands for production until separately reviewed tooling builds without deploy credentials or PATs, verifies an immutable artifact's digest and repository/full-revision attestation before credential acquisition, and deploys that artifact without rebuilding or executing candidate code. Follow [Build and deploy isolation](docs/agents/shared-operating-rules.md#build-and-deploy-isolation).

The commands below document legacy wrapper syntax only; they are not approved production deployment procedures while the required isolated build and verified-artifact tooling is absent.

```bash
# Full deploy (build + deploy + cache purge)
scripts/deploy.sh

# Scope the deploy to a single Firebase target
scripts/deploy.sh -- --only hosting
scripts/deploy.sh -- --only firestore:rules

# Legacy behavior only; --skip-build does not verify an artifact and is not a production-deploy workaround.
scripts/deploy.sh --skip-build

# Skip the Cloudflare purge (no CF env vars set, or purge separately)
scripts/deploy.sh --skip-cf-purge

# Break-glass: bypass the main-only / must-be-current-with-origin guards
scripts/deploy.sh --force
```

The guards (see [mergepath#77](https://github.com/nathanjohnpayne/mergepath/issues/77) for the incident that motivated them; the dirty-tree guard was added in [mergepath#286](https://github.com/nathanjohnpayne/mergepath/issues/286) after a closed-review backlog sweep):

1. **Current branch must be `main`.** Deploys should ship the reviewed, merged state of the project, not a worktree's in-progress branch.
2. **Local `main` must not be behind `origin/main`.** After `git fetch`, `git rev-list --count HEAD..origin/main` must be 0. Otherwise the deploy refuses.
3. **Working tree must be clean.** `git status --porcelain` must return empty — no modified, staged, or untracked paths. A dirty tree means the deploy would ship whatever the in-progress edits compile to, which diverges from the merged-on-main state reviewers signed off on (same failure class as #77).

Guards 1 and 2 are bypassed with `--force`. Guard 3 is bypassed by the dedicated env var `DEPLOY_ALLOW_DIRTY=1` — kept separate from `--force` so the override is deliberate, audit-greppable, and `--force` doesn't accidentally subsume the dirty-tree check:

```bash
# Break-glass: deploy with uncommitted changes (NEVER for routine deploys)
DEPLOY_ALLOW_DIRTY=1 scripts/deploy.sh
```

When the override is used, the script logs the dirty paths to stderr under a `⚠️  DEPLOY_ALLOW_DIRTY=1` banner so the deviation is visible in the deploy transcript. Never use `--force` or `DEPLOY_ALLOW_DIRTY=1` during routine deploys.

In the legacy wrapper, Cloudflare cache purge runs when `CF_API_TOKEN` and `CF_ZONE_ID` are set in the environment. Historically, `CF_API_TOKEN` was sourced by `scripts/op-preflight.sh --mode deploy` from the shared "All Domains — Cache Purge API token" 1Password item; this mode is not an approved deployment setup because cache hits can also export review PATs. Do not load it before or during a candidate build; `--mode all` is not a deployment setup. `CF_ZONE_ID` is per-repo, and without both variables the purge step no-ops with a clear log line.

The legacy deploy-preflight implementation prefers the project Firebase-vault SA key identified by `.firebaserc`, then shared GCP ADC. This is not the full `op-firebase-deploy` credential precedence: the wrapper first honors a genuine human-supplied `GOOGLE_APPLICATION_CREDENTIALS` override, then the project SA key, preflight-injected shared ADC, direct shared ADC, and local ADC. These are runtime facts only. Do not run deploy preflight in a session or process that builds candidate code; current preflight also exports review PATs on cache hits and exports into the caller's whole shell.

Because deploy preflight exports the selected credential through `GOOGLE_APPLICATION_CREDENTIALS`, ordinary `gcloud` commands in that same shell may also see the project SA key. For broad, non-deploy `gcloud` work, use review preflight only or unset `GOOGLE_APPLICATION_CREDENTIALS` and let the `scripts/gcloud/gcloud` wrapper resolve its normal ADC chain.

Do not run `op-firebase-deploy` or `firebase deploy` for production. They lack the required credential-free build and trusted artifact verification/deploy boundary; the branch/freshness guards and cache purge do not provide that boundary. The commands below describe legacy wrapper behavior only; they are not approved deployment or validation procedures.

Under the hood, `scripts/deploy.sh` delegates to `op-firebase-deploy` with any arguments after `--`:

```bash
op-firebase-deploy              # full deploy
op-firebase-deploy --only hosting
op-firebase-deploy --only firestore:rules
op-firebase-deploy --only functions
```

`op-firebase-deploy`:
1. Auto-detects the Firebase project from `.firebaserc`.
2. Reads source credentials per [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical) above. Logs the selected source on stderr (`[op-firebase-deploy] source credential: ...`) so deploy auth debugging is no longer opaque.
3. If the source credential is a `service_account` key matching the target `firebase-deployer@{project-id}.iam.gserviceaccount.com`, uses it directly (no impersonation wrapper needed — faster, no `serviceAccountTokenCreator` required).
4. Otherwise, unwraps nested impersonated credentials if needed, stamps the target project into `quota_project_id`, and writes a temporary `impersonated_service_account` credential file.
5. Runs `firebase deploy --non-interactive` with an isolated Firebase CLI configstore, so stale `firebase login` user tokens cannot override the selected Application Default Credential.
6. Cleans up the temp credentials and Firebase CLI configstore on exit.

No browser prompt is needed for routine use once a valid credential exists in the resolution chain and the 1Password CLI is unlocked.

This legacy 1Password-first source-credential resolver remains configured for template-derived repos. Do not replace the repository's approved auth model with routine browser-login steps, `firebase login`, or long-lived deploy keys unless a human explicitly asks for that change; this resolver does not authorize production deployment.

The local `gcloud` wrapper uses the same source-credential precedence so ordinary `gcloud` commands work without a routine interactive `gcloud auth login`. It resolves quota attribution in this order: explicit `--billing-project`, explicit `--project`, the nearest repo `.firebaserc` project, then the active `gcloud` config.

## First-Time Setup

Run once per maintainer/project to create the deployer service account, grant deploy roles, and grant your user permission to impersonate it:

```bash
op-firebase-setup {project-id}
```

If the principal receiving impersonation rights should differ from the principal in the source credential, set:

```bash
FIREBASE_IMPERSONATION_MEMBER=email@example.com op-firebase-setup {project-id}
```

### What op-firebase-setup does

1. Enables `iamcredentials.googleapis.com` on the target project
2. Creates `firebase-deployer@{project-id}.iam.gserviceaccount.com` if it does not already exist
3. Grants the deployer service account these project roles:
   - `roles/firebase.admin`
   - `roles/cloudfunctions.admin`
   - `roles/secretmanager.viewer`
   - `roles/iam.serviceAccountUser`
   - `roles/artifactregistry.writer`
   - `roles/run.admin`
4. Grants your user `roles/iam.serviceAccountTokenCreator` on the deployer service account
5. Creates or updates a dedicated `gcloud` configuration named `{project-id}` with project, impersonation, and `billing/quota_project` defaults

`op-firebase-setup` can still print Google Cloud's generic ADC quota warning if the source credential was originally stamped for another project. That warning is expected here: the legacy wrapper and `op-firebase-deploy` override quota attribution to the target project for their runtime commands; this does not authorize production deployment.

Optional after setup:

```bash
gcloud config configurations activate {project-id}
```

That makes `gcloud` default to the project-specific impersonated configuration for manual GCP work.

## Rollback Procedure

**Production rollback is blocked.** Do not use the Firebase CLI or Console to roll back the live Hosting release. This repository has no approved path to verify and deploy a prior immutable artifact with scoped post-build credentials; the production deployment block applies to rollback too.

Do not treat a release ID, console history, or a direct `firebase hosting:channel:deploy live --release-id ...` command as artifact verification or authorization. Rollback can be documented and enabled only after separately reviewed tooling verifies the prior artifact's digest and repository/revision attestation, then deploys it without rebuilding candidate code.

## Post-Deployment Verification

1. Open the live URL in an incognito window
2. Verify core app functionality
3. Check browser DevTools → Console for errors

## CI/CD Integration

Production CI/headless deployment is not currently supported: do not materialize Firebase deploy credentials or PATs in a runner/session that builds repository code, and do not invoke the legacy wrapper as a substitute. Production deployment remains blocked until separately reviewed credential-free build and trusted post-build artifact verification/deploy tooling is available. The project Firebase-vault SA key remains in the 1Password **Firebase** vault under `{project-id} — Firebase Deployer SA Key`; its existing resolution and deployment behavior is documented above as legacy behavior, not an approved deployment procedure.

## Secrets Management

- No API keys or secrets should be committed to the repository.
- **Legacy deploy-auth resolution uses the project Firebase-vault SA key as its default credential** (#154 — codified after recurring `firebase login --reauth` friction from #137 traced to RAPT/refresh-token expiry on the shared 1Password ADC). This describes existing auth behavior only and does not authorize production deployment; follow the isolation gate above. The SA key remains in the 1Password Firebase vault, and impersonated credentials remain available to the legacy resolver when the key isn't provisioned.
- Runtime application secrets should use the two-lane 1Password model below. Prefer 1Password Environments for project/stage variable sets, use secret references and `op inject` when a repo genuinely needs generated files, and reserve service-account tokens for explicitly scoped headless workflows.
- Never commit resolved secret output, service-account JSON, or ADC credentials.

### Runtime 1Password secrets and AI agents

Reconciled against 1Password Environments / MCP Server for Codex docs as of 2026-05-21. This section is descriptive; adoption decisions for the new access model live in the 1Password audit ADR workstream (#347/#355/#356/#357).

Reference docs: [1Password Environments](https://www.1password.dev/environments), [MCP Server for Codex](https://www.1password.dev/environments/mcp-codex-server), [local `.env` validation hook](https://www.1password.dev/environments/agent-hook-validate), and [`op run` secret loading](https://www.1password.dev/cli/secrets-environment-variables).

> **Beta / platform caveat (#469):** 1Password Environments, the MCP Server for Codex, and the local `.env` validation hook are early-access (beta) 1Password features at the time of writing (2026-05-21) and carry platform constraints — the MCP Server for Codex is a Codex-specific adapter, and the validation hook depends on the 1Password desktop app + CLI integration on the developer's machine. Treat the model below as descriptive and forward-looking: gate adoption on the 1Password audit ADR workstream (#347/#355/#356/#357) and re-check the upstream docs, since beta surfaces change without notice. The portable-core primitives (`op://` references, `op run`, `op inject`, scoped service accounts) are GA and are the safe baseline.

Mergepath uses a portable core with per-client adapters:

- **Portable core:** 1Password Environments, `op://` secret references, `op run --environment <environment_id> -- <command>`, `op inject` for generated config files, and scoped service-account tokens for non-interactive runners. These primitives are useful to any shell-capable agent or CI system.
- **Attended Codex:** the 1Password Environments MCP Server for Codex is the documented adapter for Codex. It lets Codex create and manage Environments, list variable names, and run applications with runtime injection while 1Password keeps raw secret values out of the model context and off disk.
- **Other attended agents:** Claude Code, Cursor, GitHub Copilot, and Windsurf can use the 1Password local `.env` validation hook when a repo relies on mounted 1Password Environment files.
- **CI/headless:** use a scoped 1Password service account or pre-materialized CI secret only after a ticket explicitly approves the scope. Do not hand `OP_SERVICE_ACCOUNT_TOKEN` to local attended agents as a convenience fallback.
- **Existing shell scripts:** keep `op read`, `op run`, and `op inject` shell-outs for repo automation. There is no current requirement to migrate these scripts to a language SDK.

Compatibility matrix:

| Capability | Codex | Claude Code | Cursor | GitHub Copilot | Windsurf | CI/headless |
|---|---|---|---|---|---|---|
| 1Password Environments MCP Server | Officially documented for Codex | Not documented here | Not documented here | Not documented here | Not documented here | No |
| 1Password local `.env` validation hook | Not listed in the hook support matrix | Supported | Supported | Supported | Supported | No |
| `op run --environment` / secret references | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works if shell-capable | Works with scoped service account |
| Service-account token | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Headless only; explicit opt-in | Preferred non-interactive path |
| Mergepath `op-preflight.sh` review mode | Configured | Configured | Configured | Not configured | Not configured | Configured for `claude` / `cursor` / `codex` when `OP_SERVICE_ACCOUNT_TOKEN` is set |

Operational guardrails:

- Never ask a human to paste raw secrets into an agent chat or issue.
- Never print resolved secret values in logs, PR bodies, or review comments.
- Use 1Password Environments for sets of runtime variables that need to move across developers, stages, or agents.
- Use `.env.tpl` plus `op inject` only when the application or tool truly requires a materialized config file.
- Secure Note `notesPlain` whole-file bootstrap has been retired. Use `.env.tpl` plus `op inject` when a generated file is required.

#### Headless `op-preflight` proof workflow

`scripts/op-preflight.sh` has an explicit CI/headless lane for review credentials. When `OP_SERVICE_ACCOUNT_TOKEN` is present, review mode uses the 1Password CLI service-account path instead of biometric desktop approval, writes only `OP_PREFLIGHT_REVIEWER_PAT`, marks the cache with `OP_PREFLIGHT_TOKEN_MODE=1`, and skips SSH warming plus GitHub keyring repair. This mode is not an implicit fallback for local attended agents.

The manual workflow `.github/workflows/onepassword-headless-proof.yml` proves the lane without exposing raw values in logs. Before dispatching it, configure:

- `OP_SERVICE_ACCOUNT_TOKEN` as an encrypted GitHub Actions secret. Scope the service account to the approved reviewer PAT items and the dedicated canary item only.
- `OP_PREFLIGHT_REVIEWER_PAT_REF` as a GitHub Actions variable containing the `op://` reference for the reviewer PAT field in the service-account-accessible proof vault. Do not point token mode at a built-in `Private`/`Personal` vault; 1Password service accounts cannot access those vaults.
- `OP_PREFLIGHT_CANARY_REF` as a GitHub Actions variable containing a non-sensitive `op://` reference to the proof canary field.
- `OP_PREFLIGHT_CANARY_SHA256` as an encrypted GitHub Actions secret containing the SHA-256 digest of the canary value.

When using `scripts/onepassword-headless-proof-setup.sh`, also pass `OP_PREFLIGHT_NEGATIVE_SCOPE_REF` or `--negative-scope-ref` pointing to an `op://` sentinel in a shared vault outside the service account's approved scope. Do not use `Private`/`Personal` for this sentinel; the point is to detect accidental access to another service-account-capable vault. The setup helper first confirms the local 1Password account can read the sentinel, then confirms the service account cannot.

The workflow installs the 1Password CLI, reads the canary, compares only its digest, verifies the reviewer PAT resolves to `nathanpayne-codex`, then runs:

```bash
eval "$(scripts/op-preflight.sh --agent codex --mode review)"
export OP_PREFLIGHT_QUIET=1
eval "$(scripts/op-preflight.sh --agent codex --check --print-exports)"
```

The workflow is `workflow_dispatch` only. Run it after provisioning or rotating the service-account token; do not enable it as an automatic PR or push workflow unless the proof secrets are intentionally available to that event class.

### Provisioning the Firebase-vault SA key

Run once per Firebase project. The preferred path is the `--provision-sa-key` flag on the setup script — it mints the key, uploads it, and wipes the local tempfile in a single attended invocation:

```bash
op-firebase-setup {project-id} --provision-sa-key

# The legacy resolver logs the selected source as
# "[op-firebase-deploy] source credential: project Firebase-vault SA key (...)".
```

The flag is opt-in (preserves the prior impersonation-only setup behavior for callers who want it), refuses to overwrite an existing 1Password item with the canonical title (rotate via the [§ Rotating a Firebase deploy SA key](#rotating-a-firebase-deploy-sa-key) procedure instead), and short-circuits early with a clear error if the 1Password CLI is not on PATH.

If you cannot use the flag (older `op-firebase-setup` on PATH, debugging the steps individually, or operating against a setup that already ran without provisioning), the manual procedure below is functionally identical to what the flag runs internally:

```bash
PROJECT_ID="{project-id}"
SA_EMAIL="firebase-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_PATH="$(mktemp -t firebase-sa-key.json)"

# 1. Generate a JSON key for the deployer SA. Requires the
#    iam.serviceAccountKeyAdmin role (or roles/owner) on the project.
gcloud iam service-accounts keys create "$KEY_PATH" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

# 2. Upload to the 1Password Firebase vault as a document with the
#    canonical title "{project-id} — Firebase Deployer SA Key" (this
#    is the exact title materialize_firebase_vault_sa_key reads in
#    op-firebase-deploy).
op document create "$KEY_PATH" \
  --vault Firebase \
  --title "${PROJECT_ID} — Firebase Deployer SA Key"

# 3. Wipe the local copy. The key now lives only in 1Password +
#    on-disk tempfiles created/destroyed during single deploy runs.
rm -f "$KEY_PATH"

# 4. The legacy resolver logs the selected source as
#    "[op-firebase-deploy] source credential: project Firebase-vault
#    SA key (...)"; this credential-source fact does not authorize deployment.
```

### Rotating a Firebase deploy SA key

The SA key remains the legacy resolver's configured source per [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical); this does not authorize production deployment. Review its age on a 90-day cadence and after any of these triggers; routine replacement remains incomplete until the non-deploying validator below is available:

- **Calendar review** — review key age every 90 days and track the last completed rotation in the 1Password item's notes field.
- **Compromise indicator** — key leaked in logs/screenshots, exposed by a misconfigured CI runner, or invalidated by org policy. Treat this as an urgent owner-led incident decision; this routine-rotation guide neither authorizes revocation nor requires a production deployment to validate or contain the incident.
- **Personnel change affecting key custody** — a maintainer with 1Password vault access leaves, or vault membership changes.

**Routine replacement rotation cannot be completed with this runbook today.** Do not replace the canonical 1Password key, declare routine rotation complete, or revoke the prior working key until separately reviewed, non-deploying validation proves the replacement credential usable. Do not use a production or low-risk deploy for routine validation; item metadata, key IDs, and resolver logs do not establish usability. Suspected-compromise containment is a separate owner incident decision: this guide neither authorizes revocation nor requires a production deployment to validate or contain the incident.


## Auth Maintenance

**Interactive machines (biometric available):** If day-to-day auth stops working, first make sure the 1Password CLI is signed in and either the project SA key in `op://Firebase/{project-id} — Firebase Deployer SA Key` or the shared ADC at `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` is readable.

**Headless environments:** Production deployment is blocked until separately reviewed credential-free build and trusted post-build artifact verification/deploy tooling is available. Do not place the project SA key, shared ADC, or PATs in a runner/session that builds repository code. The legacy key/ADC resolver behavior above does not provide the required isolation.

If the shared source credential itself needs rotation, refresh it once with `gcloud auth application-default login`, overwrite the `Private/GCP ADC` item with the new `application_default_credentials.json`, and, if desired, align its own quota project with:

```bash
gcloud auth application-default set-quota-project {project-id}
```

If deploy impersonation breaks because IAM bindings or project configuration drifted:

```bash
op-firebase-setup {project-id}
```

### Firebase CLI "Authentication Error: credentials are no longer valid" (daily reauth)

As a legacy runtime detail, current `op-firebase-deploy` isolates Firebase CLI's configstore for the deploy subprocess, so stale `firebase login` user tokens should no longer override the selected 1Password-backed Application Default Credential. This auth behavior does not make the current tooling approved for production deployment.

If an older helper is still installed, deploys can fail mid-deploy with:

```text
Authentication Error: Your credentials are no longer valid. Please run firebase login --reauth
```

The 1Password source-credential chain may still be healthy when this fires. The failure is inside Firebase CLI, which checks cached user-login state at `~/.config/configstore/firebase-tools.json` before using ADC. That cache's access token expires roughly daily and is not refreshed by the 1Password flow.

**Legacy auth fix:** install the current `op-firebase-deploy` helper to resolve this credential error; a successful source-credential lookup does not clear the production-deployment block above.

### 1Password ADC item refresh token expired (#137 failure mode B)

A closely-related but distinct failure can fire immediately after the reauth above. If `scripts/op-preflight.sh` materializes a 1Password ADC item whose underlying `refresh_token` has been revoked or expired by Google, `op-firebase-deploy` will refuse the credential with:

```
Error: GOOGLE_APPLICATION_CREDENTIALS points to an unusable credential file: /var/folders/.../op-preflight-adc-*
```

Starting with the #137 fix, `op-preflight.sh` validates the materialized ADC against the OAuth2 `/token` endpoint before exporting `GOOGLE_APPLICATION_CREDENTIALS`. In Firebase repos, legacy deploy preflight tries the project Firebase-vault SA key before this shared ADC path, so a provisioned project key avoids the RAPT-prone credential in that runtime path. When the shared ADC is still needed and is stale, preflight prints an actionable warning and skips the export — legacy downstream callers (`op-firebase-deploy`, `gcloud` wrappers) then fall back to the next available credential. These resolver facts do not authorize production deployment.

**Fix permanently** by refreshing the 1Password item:

```bash
gcloud auth application-default login
# then copy the freshly-written JSON into the 1Password item:
op document edit 'GCP ADC' --vault=Private \
  ~/.config/gcloud/application_default_credentials.json
# (or `op item edit` if stored as an item field)
```

After that, the next preflight run will materialize a usable credential and the `GOOGLE_APPLICATION_CREDENTIALS` export resumes normally.

For the legacy Firebase resolver, the configured source order prefers the project Firebase-vault SA key and retains shared ADC as a fallback. This describes auth resolution only and does not authorize a production deployment.

## Changelog

**2026-05-15: Deploy credential precedence updated.** Project Firebase-vault SA keys are now the default for `op-firebase-deploy`. See #154 / #211 for implementation history; live consumer verification closed out with #211 (2026-05-23).

**2026-05-22: Deploy preflight caches the project SA key first.** In Firebase repos, `op-preflight.sh --mode deploy|all` now materializes the project Firebase-vault SA key before trying the shared GCP ADC. This removes the routine stale-ADC/RAPT probe from attended deploy sessions when the durable project key exists.

**2026-05-15: `op-firebase-setup --provision-sa-key` flag added.** The setup script now optionally mints the deployer SA key and uploads it to `op://Firebase/{project-id} — Firebase Deployer SA Key` as part of the same attended invocation, folding the previously-manual DEPLOYMENT.md procedure into the script. Opt-in to preserve the prior impersonation-only behavior contract. See #154 close-out.
