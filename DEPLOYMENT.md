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
git clone https://github.com/nathanjohnpayne/mergepath.git ~/Documents/GitHub/mergepath

# Install canonical helper scripts
mkdir -p ~/.local/bin
cp ~/Documents/GitHub/mergepath/scripts/gcloud/gcloud ~/.local/bin/
cp ~/Documents/GitHub/mergepath/scripts/firebase/op-firebase-deploy ~/.local/bin/
cp ~/Documents/GitHub/mergepath/scripts/firebase/op-firebase-setup ~/.local/bin/
chmod +x ~/.local/bin/gcloud ~/.local/bin/op-firebase-deploy ~/.local/bin/op-firebase-setup

# Ensure PATH includes ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### 4. Clone and bootstrap all repos

```bash
cd ~/Documents/GitHub

for repo in friends-and-family-billing device-platform-reporting device-source-of-truth swipewatch nathanpaynedotcom overridebroadway; do
  git clone "https://github.com/nathanjohnpayne/$repo.git" 2>/dev/null || (cd "$repo" && git pull)
  cd "$repo"
  ./scripts/bootstrap.sh    # restores .env.local from 1Password via op inject
  cd ..
done
```

The bootstrap script for each repo:
- Resolves `op://` references in `.env.tpl` → writes `.env.local` (via `op inject`)
- Runs `npm install`
- Runs `npm run build` (if applicable)

### 5. Verify

```bash
# Quick check that each repo's local config was restored
for repo in friends-and-family-billing device-platform-reporting device-source-of-truth overridebroadway; do
  echo "=== $repo ==="
  ls ~/Documents/GitHub/$repo/.env* 2>/dev/null || echo "  (no env files expected)"
done
```

---

## Returning to Your Main Machine

When you return from a temporary machine, tell your agent:

> "Sync any changes from this session back. Run the return-to-main workflow from DEPLOYMENT.md."

### 1. On the temporary machine (before leaving)

```bash
cd ~/Documents/GitHub
for repo in friends-and-family-billing device-platform-reporting device-source-of-truth swipewatch nathanpaynedotcom overridebroadway; do
  cd "$repo"
  # Push any local config changes to 1Password
  ./scripts/bootstrap.sh --sync
  # Ensure all code changes are committed and pushed
  git status
  cd ..
done
```

### 2. On the main machine (when you return)

```bash
cd ~/Documents/GitHub
for repo in friends-and-family-billing device-platform-reporting device-source-of-truth swipewatch nathanpaynedotcom overridebroadway; do
  cd "$repo"
  git pull                          # get code changes from the temp machine
  ./scripts/bootstrap.sh --force    # re-resolve .env.tpl from 1Password (latest values)
  cd ..
done
```

The `--force` flag overwrites existing `.env.local` files with freshly resolved
values from 1Password. This ensures you pick up any secrets that were updated
on the temporary machine via `--sync`.

### Conflict resolution

If both machines modified the same 1Password item:
- 1Password keeps the latest write (last-writer-wins)
- The `.env.tpl` templates are in git, so structural changes merge normally
- For true conflicts, compare with `op item get <id>` and resolve manually

---

## Prerequisites

- [Firebase CLI](https://firebase.google.com/docs/cli) (`firebase-tools`) installed globally
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) installed
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) installed and signed in
- `gcloud`, `op-firebase-deploy`, and `op-firebase-setup` on PATH (see Script Installation below)
- Access to the project SA key in `op://Firebase/{project-id} — Firebase Deployer SA Key` (the **preferred default** for both interactive and CI/headless deploys per #154 — the most stable credential, no daily-reauth churn from #137), with the shared 1Password ADC `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` as a fallback, plus support for an explicit `GOOGLE_APPLICATION_CREDENTIALS` file as the highest-priority override
- Permission to create resources in the target Firebase/GCP project and impersonate the deployer service account

## Script Installation

The canonical helper scripts live in this template repo. Install them once per machine:

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
op-firebase-setup {project-id}
```

See [First-Time Setup](#first-time-setup) for details. This creates the `firebase-deployer` service account, grants the necessary deploy roles, and configures impersonation as a fallback path.

### 5. Provision the Firebase-vault SA key (preferred default)

After `op-firebase-setup` runs, follow [§ Secrets Management → Provisioning the Firebase-vault SA key](#provisioning-the-firebase-vault-sa-key) to materialize the SA key into the 1Password Firebase vault. This is the **preferred default** credential for routine deploys (interactive + CI) per #154 — it avoids the recurring `firebase login --reauth` friction (#137) caused by RAPT/refresh-token expiry on the shared 1Password ADC.

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

### 3. Store PATs as repository secrets

Go to the new repo → Settings → Secrets and variables → Actions → New repository secret. Add:

| Secret name | Value | PAT type |
|---|---|---|
| `REVIEWER_ASSIGNMENT_TOKEN` | PAT for a **reviewer identity** (e.g., `nathanpayne-claude`) — NOT `nathanjohnpayne` | Classic with `repo` scope (collaborator account) |

The `dependabot-auto-merge.yml` workflow uses this secret to approve and merge Dependabot bumps. It MUST be a reviewer-identity PAT (`nathanpayne-claude` / `-cursor` / `-codex`), not `nathanjohnpayne` — GitHub rejects self-approval, and the workflow's preflight guards now hard-fail if the token resolves to the author identity OR to any login not in `.github/review-policy.yml` `available_reviewers`. See nathanjohnpayne/mergepath#179 for the audit-trail rationale.

Or use the CLI (faster):

```bash
# Substitute the 1Password item ID for whichever reviewer identity
# you choose to use as the CI approver (claude / cursor / codex).
# The full lookup table is in REVIEW_POLICY.md § PAT lookup table.
gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo} --body "$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')"   # nathanpayne-claude
```

**`REVIEWER_ASSIGNMENT_TOKEN` is the only reviewer-identity PAT
stored as a repo CI secret.** It exists specifically because the
Dependabot auto-merge + Agent Review Pipeline workflows run inside
GitHub Actions where there's no interactive `op read`. Pick ONE of
the reviewer identities (claude / cursor / codex) and use its PAT
for this slot — the workflow validates the resolved identity against
`available_reviewers` and rejects anything else.

For Phase 2 internal self-peer review (the back-and-forth that
happens during a review session), the OTHER two reviewer-identity
PATs are NOT stored as repo CI secrets. Phase 2 runs in the agent's
own session: the agent switches its Git identity to its reviewer
account with a PAT read directly from 1Password
(`op read 'op://Private/<item-id>/token'`) and posts the review with
that PAT. See REVIEW_POLICY.md § Phase 2 and each repo's `CLAUDE.md`
/ `AGENTS.md` for the identity-switch procedure.

**Do NOT add `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `CLAUDE_PAT` /
`CODEX_PAT` / `CURSOR_PAT` as repo secrets.** An earlier iteration of
`agent-review.yml` had an `invoke-reviewer` job that ran the Claude
Code CLI headlessly as a CI-side reviewer; this was the wrong flow
(parallel to the authoring session, stale-API-key failure surface,
duplicate work) and was removed. Phase 2 now lives entirely inside
the authoring agent's session.

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

**Known issue:** The `Self-Review Required` and `Label Gate` status checks are
configured as required but may never report if the CI workflows that post them
(`pr-review-policy.yml`) fail silently due to misconfigured repository secrets.
This blocks all merges. Workarounds:
- Fix the CI secrets so status checks report, **or**
- Use the GitHub web UI "Merge without waiting for requirements" bypass checkbox

The `--admin` flag on `gh pr merge` does **not** bypass required status checks —
it only bypasses review requirements. The break-glass hook (`BREAK_GLASS_ADMIN=1`)
only bypasses the Claude Code PreToolUse guard, not GitHub's branch protection API.

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

Machine user reviewer identities (nathanpayne-claude, etc.) are **collaborators**,
not repo owners. GitHub fine-grained PATs on personal accounts only cover repos
owned by the token account — they cannot access collaborator repos. The "All
repositories" scope in fine-grained PATs means all repos the account *owns* (zero
for collaborators), not repos they collaborate on.

**Use classic PATs with `repo` scope for all reviewer identities.** This is stored
in 1Password with the field name `token` (not `credential` or `password`).

1Password item IDs (all classic PATs with `ghp_` prefix, field `token`, vault `Private`):

| Reviewer Identity | 1Password Item ID | `op read` command |
|---|---|---|
| `nathanpayne-claude` | `pvbq24vl2h6gl7yjclxy2hbote` | `op read "op://Private/pvbq24vl2h6gl7yjclxy2hbote/token"` |
| `nathanpayne-cursor` | `bslrih4spwxgookzfy6zedz5g4` | `op read "op://Private/bslrih4spwxgookzfy6zedz5g4/token"` |
| `nathanpayne-codex` | `o6ekjxjjl5gq6rmcneomrjahpu` | `op read "op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token"` |
| `nathanjohnpayne` | `sm5kopwk6t6p3xmu2igesndzhe` | `op read "op://Private/sm5kopwk6t6p3xmu2igesndzhe/token"` |

Use the item ID (not the item title) to avoid shell issues with parentheses in
1Password item names like `GitHub PAT (pr-review-claude)`.

### Reviewer PAT quick check

`gh` resolves auth differently for read paths vs write paths — the
canonical convention is in `REVIEW_POLICY.md` § Reviewer PAT Quick Start
and `CLAUDE.md` § Active-account convention. Short form:

- **Read paths** (`gh api user`, GETs, `gh pr view`) honor `GH_TOKEN`.
- **Write paths** (`gh pr review`, `gh pr create`, `gh pr merge`,
  `gh pr edit`, `gh api -X POST`) use the keyring's **active**
  account regardless of `GH_TOKEN`. Set the active account once per
  machine: `gh auth switch -u nathanpayne-<agent>`.

```bash
# Read-path identity check — GH_TOKEN works here.
GH_TOKEN="$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')" \
  gh api user --jq '.login'
# expected: nathanpayne-claude

# Write-path: with the agent identity active, GH_TOKEN is irrelevant
# for the byline. Just run the command.
gh pr review <PR#> --repo <owner/repo> --comment --body "Review comment"

# Author-identity write: switch around the call. Substitute your
# agent identity (claude / cursor / codex) for the switch-back.
gh auth switch -u nathanjohnpayne && \
  gh pr merge <PR#> --squash --delete-branch && \
  gh auth switch -u nathanpayne-<agent>
```

- Use the item ID from the table above for your agent identity. Do not use the 1Password item title.
- Verify the keyring active account with `gh config get -h github.com user`
  (NOT `gh auth status` — that command honors GH_TOKEN and
  mis-reports when GH_TOKEN is set). Fix once with
  `gh auth switch -u nathanpayne-<agent>`. The `op-preflight.sh`
  script warns when active ≠ expected.
- On local interactive machines, the `op read` command itself may trigger the
  1Password biometric prompt even if `op whoami` says you are not signed in.
- `Review Can not approve your own pull request` means you are the active
  account on a PR you authored. Switch to a different agent's reviewer
  identity (or skip self-approve per the no-self-approve rule).

### Token rotation (as needed)

The current PATs are set to never expire. If you ever need to rotate
a reviewer identity PAT (`nathanpayne-claude`, `nathanpayne-codex`,
`nathanpayne-cursor`):

1. Generate a new **classic** PAT with `repo` scope for the machine user account
2. Update the `token` field on the corresponding 1Password item
3. Revoke the old token in GitHub
4. Verify agent access still works: `GH_TOKEN="$(op read 'op://Private/<item-id>/token')" gh api user`

Note: reviewer identity PATs are NOT stored as repo CI secrets. They are
read from 1Password per-session by the authoring agent for the in-session
identity switch, so rotation does not require updating any repo secrets.

The `REVIEWER_ASSIGNMENT_TOKEN` repo secret (a **reviewer-identity**
PAT used by the Dependabot auto-merge + Agent Review Pipeline
workflows; see "Add `REVIEWER_ASSIGNMENT_TOKEN` to repo secrets" above)
follows a similar process but also needs a `gh secret set
REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo}` call on every repo
after rotating the 1Password item.

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

The canonical deploy entry point is **`scripts/deploy.sh`**. It wraps `op-firebase-deploy` with two safety guards and the Cloudflare cache purge step so a single `scripts/deploy.sh` (or `npm run deploy`) is the complete, safe deploy surface.

```bash
# Full deploy (build + deploy + cache purge)
scripts/deploy.sh

# Scope the deploy to a single Firebase target
scripts/deploy.sh -- --only hosting
scripts/deploy.sh -- --only firestore:rules

# Skip the build step (assume dist/ is already current)
scripts/deploy.sh --skip-build

# Skip the Cloudflare purge (no CF env vars set, or purge separately)
scripts/deploy.sh --skip-cf-purge

# Break-glass: bypass the main-only / must-be-current-with-origin guards
scripts/deploy.sh --force
```

The guards (see [mergepath#77](https://github.com/nathanjohnpayne/mergepath/issues/77) for the incident that motivated them):

1. **Current branch must be `main`.** Deploys should ship the reviewed, merged state of the project, not a worktree's in-progress branch.
2. **Local `main` must not be behind `origin/main`.** After `git fetch`, `git rev-list --count HEAD..origin/main` must be 0. Otherwise the deploy refuses.

Both guards can be bypassed with `--force` for break-glass scenarios. Never use `--force` during routine deploys.

Cloudflare cache purge runs when `CF_API_TOKEN` and `CF_ZONE_ID` are set in the environment. `CF_API_TOKEN` is sourced automatically by `scripts/op-preflight.sh --mode deploy` (or `--mode all`) from the shared "All Domains — Cache Purge API token" 1Password item — no `op read` needed in your shell. `CF_ZONE_ID` is per-repo; each downstream consumer sets its own zone ID (e.g., in the repo's bootstrap or as a hardcoded value in its `scripts/deploy.sh` wrapper) since one CF token covers all domains but each domain has its own zone. Without both variables the purge step no-ops with a clear log line.

**Do not run `op-firebase-deploy` or `firebase deploy` directly for routine deploys.** They skip the branch + freshness guards and the cache purge. Direct invocation is reserved for debugging or one-off flows where the deploy surface is known.

Under the hood, `scripts/deploy.sh` delegates to `op-firebase-deploy` with any arguments after `--`:

```bash
op-firebase-deploy              # full deploy
op-firebase-deploy --only hosting
op-firebase-deploy --only firestore:rules
op-firebase-deploy --only functions
```

`op-firebase-deploy`:
1. Auto-detects the Firebase project from `.firebaserc`
2. Reads source credentials in this order (per #154):
   1. **Genuinely user-supplied `GOOGLE_APPLICATION_CREDENTIALS`** — when a human explicitly set the env var (debugging, alternate project, one-off flow). The script distinguishes this from preflight-injected ADC by comparing against `OP_PREFLIGHT_ADC_TMPFILE`.
   2. **Project SA key** from `op://Firebase/{project-id} — Firebase Deployer SA Key` — the **default day-to-day deploy credential**, both interactive and CI. Stable, no RAPT/refresh-token expiry.
   3. **Preflight-injected `GOOGLE_APPLICATION_CREDENTIALS`** — used when no project SA key is provisioned. The shared 1Password ADC's RAPT-expiry surface (#137) is the cost of this fallback; consumers wanting stable deploys should provision the project SA key.
   4. **Shared 1Password ADC** read directly from `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` — used when neither preflight nor SA key are available.
   5. **Local ADC file** `~/.config/gcloud/application_default_credentials.json` — last resort.
3. Logs the selected credential source on stderr (`[op-firebase-deploy] source credential: ...`) so deploy auth debugging is no longer opaque.
4. If the source credential is a `service_account` key matching the target `firebase-deployer@{project-id}.iam.gserviceaccount.com`, uses it directly (no impersonation wrapper needed — faster, no `serviceAccountTokenCreator` required).
5. Otherwise, unwraps nested impersonated credentials if needed, stamps the target project into `quota_project_id`, and writes a temporary `impersonated_service_account` credential file.
6. Runs `firebase deploy --non-interactive`.
7. Cleans up the temp credentials on exit.

No browser prompt is needed for routine use once a valid credential exists in the resolution chain and the 1Password CLI is unlocked.

This 1Password-first source-credential model is the default for template-derived repos. Do not replace it with ADC-first day-to-day docs, routine browser-login steps, `firebase login`, or long-lived deploy keys unless a human explicitly asks for that change.

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
   - `roles/iam.serviceAccountUser`
   - `roles/artifactregistry.writer`
   - `roles/run.admin`
4. Grants your user `roles/iam.serviceAccountTokenCreator` on the deployer service account
5. Creates or updates a dedicated `gcloud` configuration named `{project-id}` with project, impersonation, and `billing/quota_project` defaults

`op-firebase-setup` can still print Google Cloud's generic ADC quota warning if the source credential was originally stamped for another project. That warning is expected here: the wrapper and `op-firebase-deploy` both override quota attribution to the target project for actual commands and deploys.

Optional after setup:

```bash
gcloud config configurations activate {project-id}
```

That makes `gcloud` default to the project-specific impersonated configuration for manual GCP work.

## Rollback Procedure

Firebase Hosting supports instant rollback:

```bash
# List recent releases
firebase hosting:releases:list

# Roll back via CLI
firebase hosting:channel:deploy live --release-id <VERSION_ID>
```

Or use Firebase Console → Hosting → Release History → Roll back.

## Post-Deployment Verification

1. Open the live URL in an incognito window
2. Verify core app functionality
3. Check browser DevTools → Console for errors

## CI/CD Integration

Deploys are manual via `op-firebase-deploy`. CI workflows (repo linting, review policy enforcement) run on push/PR via GitHub Actions — see `.github/workflows/`.

When connecting CI, prefer Workload Identity Federation or another `external_account` credential as the source credential. If CI already exposes `GOOGLE_APPLICATION_CREDENTIALS` pointing at an `external_account` file, `op-firebase-deploy` can reuse it to impersonate the deployer service account and attribute quota to the target project.

### CI/CD & Headless Deploy

For headless environments (Claude Code cloud tasks, GitHub Actions, etc.) where
1Password biometric auth is unavailable, use the project SA key directly:

```bash
# Pull the SA key from 1Password (one-time, requires biometric on an interactive machine)
op document get "{project-id} — Firebase Deployer SA Key" \
  --vault Firebase --out-file ~/firebase-keys/{project-id}-sa-key.json

# Deploy with the SA key (no impersonation, no 1Password needed at deploy time)
GOOGLE_APPLICATION_CREDENTIALS=~/firebase-keys/{project-id}-sa-key.json npm run deploy
```

When the source credential is a `service_account` key matching the target deployer SA, `op-firebase-deploy` skips the impersonation wrapper and uses the key directly.

For Claude Code cloud scheduled tasks:
1. Retrieve the key: `op document get "{project-id} — Firebase Deployer SA Key" --vault Firebase`
2. Copy the JSON contents
3. In the task's cloud environment, add an env var: `FIREBASE_SA_KEY=<paste JSON>`
4. Add a setup script:
   ```bash
   echo "$FIREBASE_SA_KEY" > /tmp/sa-key.json
   export GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa-key.json
   ```

Each project's SA key is stored in the 1Password **Firebase** vault with the naming convention `{project-id} — Firebase Deployer SA Key`.

## Secrets Management

- No API keys or secrets should be committed to the repository.
- **Deploy auth uses the project Firebase-vault SA key as the default credential** (#154 — codified after recurring `firebase login --reauth` friction from #137 traced to RAPT/refresh-token expiry on the shared 1Password ADC). The SA key lives in the 1Password Firebase vault — it's not stored on disk except as a tempfile during a single deploy invocation, and never committed to a repo. Impersonated credentials remain available for cases where the SA key isn't provisioned, but the policy default is to provision the key per-project per § Provisioning the Firebase-vault SA key below.
- Runtime secrets can still use `op://Private/<item>/<field>` references in committed template files and `op inject` into gitignored runtime files when a repo actually needs 1Password-managed application secrets.
- Never commit resolved secret output, service-account JSON, or ADC credentials.

### Provisioning the Firebase-vault SA key

Run once per Firebase project, after `op-firebase-setup` has created the `firebase-deployer` service account:

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

# 4. Verify: a routine deploy should now log
#    "[op-firebase-deploy] source credential: project Firebase-vault
#    SA key (...)" and run without prompting for firebase login --reauth.
op-firebase-deploy --only hosting   # or whatever target
```

Rotation (e.g., key compromised, GCP-side key expiry, agent identity change): repeat steps 1–4 with `--key-file-type=json` on `gcloud iam service-accounts keys create`. Old key on the SA can be deleted via `gcloud iam service-accounts keys delete <key-id>` after the new one is verified.

## Auth Maintenance

**Interactive machines (biometric available):** If day-to-day auth stops working, first make sure the 1Password CLI is signed in and either the project SA key in `op://Firebase/{project-id} — Firebase Deployer SA Key` or the shared ADC at `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` is readable.

**Headless environments:** Use the project SA key from the Firebase vault as the primary credential source (see CI/CD & Headless Deploy above). The shared ADC requires interactive refresh and is not suitable for unattended use.

If the shared source credential itself needs rotation, refresh it once with `gcloud auth application-default login`, overwrite the `Private/GCP ADC` item with the new `application_default_credentials.json`, and, if desired, align its own quota project with:

```bash
gcloud auth application-default set-quota-project {project-id}
```

If deploy impersonation breaks because IAM bindings or project configuration drifted:

```bash
op-firebase-setup {project-id}
```

### Firebase CLI "Authentication Error: credentials are no longer valid" (daily reauth)

`op-firebase-deploy` (and `scripts/deploy.sh` by extension) occasionally fails
mid-deploy with:

```
Authentication Error: Your credentials are no longer valid. Please run firebase login --reauth
```

The 1Password source-credential chain is still healthy when this fires —
`gcloud auth application-default print-access-token` against the materialized
ADC still mints a valid token. The failure is inside firebase CLI, which
ignores `GOOGLE_APPLICATION_CREDENTIALS` in some hosting-deploy code paths
and falls back to the user-login cache at
`~/.config/configstore/firebase-tools.json`. That cache's access token
expires roughly daily and is not refreshed by the 1Password flow.

**Workaround:** run `firebase login --reauth` once, then re-run the exact
same `scripts/deploy.sh` (or `op-firebase-deploy`) command. It will succeed
on the next attempt. See nathanjohnpayne/mergepath#137 for the open
investigation and the longer-term fix under consideration
(detect stale configstore in `op-firebase-deploy` and print a clear message
instead of the current cryptic "Assertion failed: resolving hosting target"
trailer).

### 1Password ADC item refresh token expired (#137 failure mode B)

A closely-related but distinct failure can fire immediately after the
reauth above. If `scripts/op-preflight.sh` materializes a 1Password ADC
item whose underlying `refresh_token` has been revoked or expired by
Google, `op-firebase-deploy` will refuse the credential with:

```
Error: GOOGLE_APPLICATION_CREDENTIALS points to an unusable credential file: /var/folders/.../op-preflight-adc-*
```

Starting with the #137 fix, `op-preflight.sh` now validates the
materialized ADC against the OAuth2 `/token` endpoint before exporting
`GOOGLE_APPLICATION_CREDENTIALS`. When the credential is stale,
preflight prints an actionable warning and skips the export — downstream
callers (`op-firebase-deploy`, `gcloud` wrappers) then fall back to the
local firebase-login / ADC path that the reauth has just refreshed.

**Fix permanently** by refreshing the 1Password item:

```bash
gcloud auth application-default login
# then copy the freshly-written JSON into the 1Password item:
op document edit 'GCP ADC' --vault=Private \
  ~/.config/gcloud/application_default_credentials.json
# (or `op item edit` if stored as an item field)
```

After that, the next preflight run will materialize a usable credential
and the `GOOGLE_APPLICATION_CREDENTIALS` export resumes normally.
