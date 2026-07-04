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

The full bootstrap loop runs across each consumer repo. Current consumers:

<!-- bootstrap-loop-list-start -->
- friends-and-family-billing
- device-platform-reporting
- device-source-of-truth
- swipewatch
- nathanpaynedotcom
- overridebroadway
<!-- bootstrap-loop-list-end -->

Run the bootstrap script across all of them:

```bash
# Resolve the repo list FIRST (while pwd is anywhere), THEN cd. The
# awk lookup must point at mergepath's DEPLOYMENT.md explicitly —
# `cd ~/Documents/GitHub` doesn't put us inside mergepath, so a bare
# `DEPLOYMENT.md` arg would silently expand to nothing and the loop
# would no-op. See #252 (Codex P1).
repos=$(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
        ~/Documents/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/Documents/GitHub
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
              ~/Documents/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //'); do
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
# Resolve repo list before cd-ing away from mergepath (see #252 Codex P1).
repos=$(awk '/<!-- bootstrap-loop-list-start -->/,/<!-- bootstrap-loop-list-end -->/' \
        ~/Documents/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/Documents/GitHub
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
        ~/Documents/GitHub/mergepath/DEPLOYMENT.md | grep '^- ' | sed 's/^- //')

cd ~/Documents/GitHub
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
- Access to the project SA key in `op://Firebase/{project-id} — Firebase Deployer SA Key` (the **preferred default** for both interactive and CI/headless deploys per [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical)), with the shared 1Password ADC `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential` as a fallback, plus support for an explicit `GOOGLE_APPLICATION_CREDENTIALS` file as the highest-priority override
- Permission to create resources in the target Firebase/GCP project and impersonate the deployer service account

## Deploy credential precedence (canonical)

For `scripts/deploy.sh` and the underlying `op-firebase-deploy`, the source-credential resolution order is:

1. **Genuine human-supplied override** — `GOOGLE_APPLICATION_CREDENTIALS` set by the human OUTSIDE preflight (no `OP_PREFLIGHT_FIREBASE_SA_TMPFILE` or `OP_PREFLIGHT_ADC_TMPFILE` marker matching the same path). Wins. Used for one-off debugging, alternate-account deploys, or CI runners that materialize their own credential.
2. **Project Firebase-vault SA key** — `op://Firebase/{project-id} — Firebase Deployer SA Key`, when present. **The standard day-to-day credential, both interactive and CI.** Stable (no `firebase login --reauth` churn from RAPT/refresh-token expiry on the shared ADC; see [#137](https://github.com/nathanjohnpayne/mergepath/issues/137)), parity between local and CI flows, no dependence on Firebase CLI local-login state. In a repo with a `.firebaserc` default project, `scripts/op-preflight.sh --mode deploy` (or `--mode all`) now caches this key first and exports `OP_PREFLIGHT_FIREBASE_SA_TMPFILE` / `OP_PREFLIGHT_FIREBASE_PROJECT`, so the deploy wrapper does not spend time probing the stale shared ADC before using the durable project key.
3. **Preflight-injected shared ADC** — when no project SA key is provisioned or detectable, `scripts/op-preflight.sh --mode deploy` (or `--mode all`) materializes the shared 1Password ADC into a tempfile and exports its path as `OP_PREFLIGHT_ADC_TMPFILE`. Subject to the same RAPT-expiry surface as the shared ADC.
4. **Shared 1Password ADC read directly** — `op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential`, read by the script when neither preflight nor an SA key are available. Same RAPT-expiry surface.
5. **Local ADC file** — `~/.config/gcloud/application_default_credentials.json` from a prior `gcloud auth application-default login`. Last resort.

`op-firebase-deploy` logs the selected source on stderr: `[op-firebase-deploy] source credential: ...`. Deploy auth debugging is no longer opaque — read the line to know which step won.

This precedence applies to deploy flows ONLY. General `gcloud` commands go through the local `gcloud` wrapper at `scripts/gcloud/gcloud`, which uses a narrower 3-step chain — `GOOGLE_APPLICATION_CREDENTIALS` if set, else the shared 1Password ADC (`op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential`), else the local ADC file. The `gcloud` wrapper does NOT consult the per-project Firebase-vault SA key from step 2 above; that step is specific to `op-firebase-deploy`. Quota attribution for `gcloud` commands is resolved separately from explicit flags / `.firebaserc` / active config rather than from the deploy script's project pin.

### Trade-off

This precedence shifts the day-to-day human deploy path from "impersonation-first via shared ADC" to "stored per-project SA key first." The trade-off is intentional:

- **Why this is acceptable.** The SA key is per-project (blast radius bounded to one Firebase project), stored in 1Password (encryption + access control + audit trail per the org's existing controls), and rotatable on demand without coordination. The stability win — no daily `firebase login --reauth` from RAPT expiry on the shared ADC ([#137](https://github.com/nathanjohnpayne/mergepath/issues/137)) — materially improves deploy reliability across all consumer repos. It also gives interactive and CI/headless flows the same source credential, removing a class of "works in CI, fails locally" deploy bugs.
- **What we give up.** The strict "no long-lived credentials on disk" property of impersonation-first is weakened for deploys: the SA key sits in 1Password rather than being purely ephemeral. We retain the property for the broader `gcloud` surface (general cloud workflows still use impersonation by default; the SA-key-first precedence only applies under `op-firebase-deploy`).
- **Rotation.** The SA key is rotated by re-issuing via the Firebase console or `op-firebase-setup`'s key-issuance flow, updating the 1Password item, and invalidating the prior key. The next deploy's source-credential lookup picks up the new key automatically. Detailed rotation steps land alongside [#154 sub-C](https://github.com/nathanjohnpayne/mergepath/issues/210) in `docs/agents/deployment-process.md`.

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
op-firebase-setup {project-id} --provision-sa-key
```

See [First-Time Setup](#first-time-setup) for details. This creates the `firebase-deployer` service account, grants the necessary deploy roles, configures impersonation as a fallback path, and (with `--provision-sa-key`) mints the deployer SA key and uploads it to `op://Firebase/{project-id} — Firebase Deployer SA Key`. The flag is opt-in; without it, the script does impersonation-only setup and leaves SA-key provisioning as a documented manual step.

### 5. Provision the Firebase-vault SA key (preferred default)

If you ran step 4 with `--provision-sa-key`, the SA key is already in 1Password and you can skip to step 6. Otherwise, follow [§ Secrets Management → Provisioning the Firebase-vault SA key](#provisioning-the-firebase-vault-sa-key) to materialize the SA key — the doc-block procedure is functionally identical to what `--provision-sa-key` runs inside the setup script. The SA key is the **preferred default** credential for routine deploys (interactive + CI) per #154 — it avoids the recurring `firebase login --reauth` friction (#137) caused by RAPT/refresh-token expiry on the shared 1Password ADC.

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
| `AUTHOR_MERGE_TOKEN` | PAT for the **author identity** (`nathanjohnpayne`) — NOT a reviewer identity | Classic with `repo` scope (author account) |

The `dependabot-auto-merge.yml` workflow uses `REVIEWER_ASSIGNMENT_TOKEN` to post the reviewer-identity `--approve`. It MUST be a reviewer-identity PAT (`nathanpayne-claude` / `-cursor` / `-codex`), not `nathanjohnpayne` — GitHub rejects self-approval, and the workflow's preflight guards hard-fail if the token resolves to the author identity OR to any login not in `.github/review-policy.yml` `available_reviewers`. The `gh pr merge` itself runs under `AUTHOR_MERGE_TOKEN` (see below) so the merge is recorded under `author_identity`. See nathanjohnpayne/mergepath#179 and #426 for the audit-trail rationale.

Or use the CLI (faster):

```bash
# Substitute the 1Password item ID for whichever reviewer identity
# you choose to use as the CI approver (claude / cursor / codex).
# The full lookup table is in REVIEW_POLICY.md § PAT lookup table.
gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo} --body "$(op read 'op://Private/pvbq24vl2h6gl7yjclxy2hbote/token')"   # nathanpayne-claude
gh secret set AUTHOR_MERGE_TOKEN --repo {owner}/{repo} --body "$(op read 'op://Private/sm5kopwk6t6p3xmu2igesndzhe/token')"   # nathanjohnpayne (author identity)
```

`AUTHOR_MERGE_TOKEN` is **required** wherever Dependabot auto-merge is enabled: as of nathanjohnpayne/mergepath#426 the workflow uses it for the `gh pr merge` step (recording `mergedBy` as `author_identity`) and hard-fails if it is empty or resolves to anything other than `author_identity`. It is the author-identity counterpart to `REVIEWER_ASSIGNMENT_TOKEN`, and the Agent Review Pipeline's auto-merge step uses it too.

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

**Known issue:** The `Self-Review Required` and `Label Gate` status checks are configured as required but may never report if the CI workflows that post them (`pr-review-policy.yml`) fail silently due to misconfigured repository secrets. This blocks all merges. Workarounds:
- Fix the CI secrets so status checks report, **or**
- Use the GitHub web UI "Merge without waiting for requirements" bypass checkbox

The `--admin` flag on `gh pr merge` does **not** bypass required status checks — it only bypasses review requirements. The break-glass hook (`BREAK_GLASS_ADMIN=1`) only bypasses the Claude Code PreToolUse guard, not GitHub's branch protection API.

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
- Verify token identity with `GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login` or by letting the wrappers call `identity-check.sh --expect-token-identity` before the write.
- On local interactive machines, the `op read` command itself may trigger the 1Password biometric prompt even if `op whoami` says you are not signed in.
- `Review Can not approve your own pull request` means the PR author is wrong, the reviewer token resolved to the author identity, or the no-self-approve scoping rule applies (Phase 4 / above-threshold PRs only — see REVIEW_POLICY.md § No-self-approve scoping). For under-threshold PRs the reviewer identity is allowed and expected to `--approve`.

### Token rotation (as needed)

The current PATs are set to never expire. If you ever need to rotate a reviewer identity PAT (`nathanpayne-claude`, `nathanpayne-codex`, `nathanpayne-cursor`):

1. Generate a new **classic** PAT with `repo` scope for the machine user account
2. Update the `token` field on the corresponding 1Password item
3. Revoke the old token in GitHub
4. Verify agent access still works: `GH_TOKEN="$(op read 'op://Private/<item-id>/token')" gh api user`

Note: reviewer identity PATs are NOT stored as repo CI secrets. They are read from 1Password per-session by the authoring agent for the in-session identity switch, so rotation does not require updating any repo secrets.

The `REVIEWER_ASSIGNMENT_TOKEN` repo secret (a **reviewer-identity** PAT used by the Dependabot auto-merge approval + Agent Review Pipeline workflows; see "Add `REVIEWER_ASSIGNMENT_TOKEN` to repo secrets" above) follows a similar process but also needs a `gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo {owner}/{repo}` call on every repo after rotating the 1Password item. The `AUTHOR_MERGE_TOKEN` repo secret (an **author-identity** PAT used by the Dependabot auto-merge `gh pr merge` step + the Agent Review Pipeline auto-merge) follows the same process with a `gh secret set AUTHOR_MERGE_TOKEN --repo {owner}/{repo}` call after rotating its 1Password item.

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

Cloudflare cache purge runs when `CF_API_TOKEN` and `CF_ZONE_ID` are set in the environment. `CF_API_TOKEN` is sourced automatically by `scripts/op-preflight.sh --mode deploy` (or `--mode all`) from the shared "All Domains — Cache Purge API token" 1Password item — no `op read` needed in your shell. `CF_ZONE_ID` is per-repo; each downstream consumer sets its own zone ID (e.g., in the repo's bootstrap or as a hardcoded value in its `scripts/deploy.sh` wrapper) since one CF token covers all domains but each domain has its own zone. Without both variables the purge step no-ops with a clear log line.

Deploy preflight in a Firebase repo reads credentials in the same stable order as `op-firebase-deploy`: first the project Firebase-vault SA key identified by `.firebaserc`, then the shared GCP ADC only if the project key is absent or invalid. This keeps attended deploy sessions from repeatedly hitting the human authorized-user ADC path that expires under Google Workspace reauth/RAPT policy.

Because deploy preflight exports the selected credential through `GOOGLE_APPLICATION_CREDENTIALS`, ordinary `gcloud` commands in that same shell may also see the project SA key. For broad, non-deploy `gcloud` work, use review preflight only or unset `GOOGLE_APPLICATION_CREDENTIALS` and let the `scripts/gcloud/gcloud` wrapper resolve its normal ADC chain.

**Do not run `op-firebase-deploy` or `firebase deploy` directly for routine deploys.** They skip the branch + freshness guards and the cache purge. Direct invocation is reserved for debugging or one-off flows where the deploy surface is known.

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
   - `roles/secretmanager.viewer`
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

When connecting CI, the recommended source credential is the same per-project Firebase-vault SA key used by interactive deploys — see [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical) and the headless setup below. Materialize the SA key into the runner's filesystem (e.g., from a CI secret) and point `GOOGLE_APPLICATION_CREDENTIALS` at it; `op-firebase-deploy` will detect the `service_account` shape, skip the impersonation wrapper, and use the key directly. Workload Identity Federation or another `external_account` credential is also supported — if CI exposes `GOOGLE_APPLICATION_CREDENTIALS` pointing at an `external_account` file, `op-firebase-deploy` reuses it via the impersonation wrapper to attribute quota to the target project. The SA-key path is preferred because it gives interactive and CI flows the same source-credential shape and removes a class of "works in CI, fails locally" deploy bugs.

### CI/CD & Headless Deploy

For headless environments (Claude Code cloud tasks, GitHub Actions, etc.) where 1Password biometric auth is unavailable, use the project SA key directly:

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
eval "$(scripts/op-preflight.sh --agent codex --check)"
```

The workflow is `workflow_dispatch` only. Run it after provisioning or rotating the service-account token; do not enable it as an automatic PR or push workflow unless the proof secrets are intentionally available to that event class.

### Provisioning the Firebase-vault SA key

Run once per Firebase project. The preferred path is the `--provision-sa-key` flag on the setup script — it mints the key, uploads it, and wipes the local tempfile in a single attended invocation:

```bash
op-firebase-setup {project-id} --provision-sa-key

# Verify: a routine deploy should now log
# "[op-firebase-deploy] source credential: project Firebase-vault SA key (...)"
# and run without prompting for firebase login --reauth.
op-firebase-deploy --only hosting   # or whatever target
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

# 4. Verify: a routine deploy should now log
#    "[op-firebase-deploy] source credential: project Firebase-vault
#    SA key (...)" and run without prompting for firebase login --reauth.
op-firebase-deploy --only hosting   # or whatever target
```

### Rotating a Firebase deploy SA key

The SA key is the standard day-to-day deploy credential per [Deploy credential precedence (canonical)](#deploy-credential-precedence-canonical). Rotate it on a calendar cadence and on demand for any of these triggers:

- **Calendar rotation** — target every 90 days. Track the last-rotation timestamp in the 1Password item's notes field so the next rotation is auditable.
- **Compromise indicator** — key leaked in logs/screenshots, exposed by a misconfigured CI runner, or invalidated by org policy. Rotate immediately and audit downstream usage.
- **Personnel change affecting key custody** — a maintainer with 1Password vault access leaves, or vault membership changes.

Procedure (assumes `op-firebase-setup` already ran, the `firebase-deployer` SA exists, and your principal has `iam.serviceAccountKeyAdmin` on the project):

```bash
PROJECT_ID="{project-id}"
SA_EMAIL="firebase-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_PATH="$(mktemp -t firebase-sa-key.json)"

# 1. Mint a new JSON key for the deployer SA.
gcloud iam service-accounts keys create "$KEY_PATH" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

# 2. Capture the old key's id BEFORE replacing the 1Password item, so
#    we can revoke it cleanly after verification. The old key's
#    private_key_id is also stored inside the 1Password item.
OLD_KEY_ID=$(op document get "${PROJECT_ID} — Firebase Deployer SA Key" \
  --vault Firebase 2>/dev/null \
  | jq -r '.private_key_id')

# 3. Replace the 1Password item with the new key. Use the SAME title
#    "{project-id} — Firebase Deployer SA Key" so op-firebase-deploy's
#    item-title lookup keeps working without a per-rotation script edit.
#    Update the item's notes to record the rotation date.
op document edit "${PROJECT_ID} — Firebase Deployer SA Key" \
  "$KEY_PATH" \
  --vault Firebase \
  --notes "Rotated $(date -u +%Y-%m-%d) (see DEPLOYMENT.md § Rotating a Firebase deploy SA key)"

# 4. Wipe the local copy.
rm -f "$KEY_PATH"

# 5. Verify with a non-prod deploy. The source-credential log line
#    must still show "project Firebase-vault SA key" — if it falls
#    through to a different source, the new key isn't being read
#    (mistyped item title, vault permissions, etc.) and rolling
#    forward could leave the project on stale auth.
op-firebase-deploy --only hosting   # or any low-risk target

# 6. Once the new-key deploy succeeds, revoke the old key in GCP.
#    Doing this AFTER step 5 ensures we never leave the project
#    without a valid key.
if [ -n "$OLD_KEY_ID" ]; then
  gcloud iam service-accounts keys delete "$OLD_KEY_ID" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" --quiet
fi

# 7. (Optional) Record the rotation in the repo's CHANGELOG.md or
#    deploy log if the repo tracks security events. The 1Password
#    notes field from step 3 is the primary record.
```

This procedure is intentionally human-only — the bootstrap wizard (#156) does NOT automate rotation. Rotation cadence is low enough (quarterly) that the manual path is fine, and the cost of a botched automation (silently invalidating production deploy auth across multiple consumers) exceeds the benefit. If a maintainer wants to rotate keys for several projects in a single sitting, run the procedure above once per project — `PROJECT_ID` is the only thing that changes between iterations.

If step 5 fails (deploy doesn't pick up the new key), the most common causes are:
- **Mistyped item title.** The script reads `op://Firebase/{project-id} — Firebase Deployer SA Key` exactly. Confirm with `op item get "${PROJECT_ID} — Firebase Deployer SA Key" --vault Firebase`.
- **Stale `op` session.** Run `op signin` and re-try.
- **Source credential precedence override.** A `GOOGLE_APPLICATION_CREDENTIALS` env var set outside preflight wins over the SA key. Unset it and re-run.

**Roll back / recovery.** GCP does NOT let you re-download a previous key's private JSON — only `private_key_id` (which step 2 captures) is recoverable, and that's just the public identifier, not the key material. So the rollback path depends on what you retained:

- **If you saved a backup of the old deployer SA key JSON BEFORE step 3** (e.g., the JSON file `gcloud iam service-accounts keys create` wrote in step 1 of the prior rotation, copied to a separate secure tempfile or `op document create -old` item), restore that backup into the 1Password item with the same canonical title and re-run step 5. This is the only true rollback.
- **If no backup exists** (the common case, since step 3 overwrites the only canonical copy), the recovery is roll-FORWARD, not roll-back: mint a fresh key with step 1, replace the 1Password item with it (step 3), verify with step 5, then revoke any keys still attached to the SA that aren't the new one. Only step 6 (revoking the prior key) is destructive — if you haven't reached step 6 yet, the prior key is still valid in GCP and the most reliable recovery is to delete the failed-verification 1Password item entry, re-fetch the prior key from a secure backup if available, or mint-and-rotate again.

The takeaway: if you want a recoverable rollback, retain a copy of the old JSON before step 3 and store it temporarily in a secure location (e.g., another `op document create`-ed item with `-old` in the title, then delete after the new key is verified).

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

Current `op-firebase-deploy` isolates Firebase CLI's configstore for the deploy subprocess, so stale `firebase login` user tokens should no longer override the selected 1Password-backed Application Default Credential. This keeps routine deploys on the project Firebase-vault SA key and avoids the daily `firebase login --reauth` loop.

If an older helper is still installed, deploys can fail mid-deploy with:

```text
Authentication Error: Your credentials are no longer valid. Please run firebase login --reauth
```

The 1Password source-credential chain may still be healthy when this fires. The failure is inside Firebase CLI, which checks cached user-login state at `~/.config/configstore/firebase-tools.json` before using ADC. That cache's access token expires roughly daily and is not refreshed by the 1Password flow.

**Fix:** install the current `op-firebase-deploy` helper and re-run the same `scripts/deploy.sh` (or `op-firebase-deploy`) command. The expected source log is the project Firebase-vault SA key, and the command should complete without prompting for `firebase login --reauth`.

### 1Password ADC item refresh token expired (#137 failure mode B)

A closely-related but distinct failure can fire immediately after the reauth above. If `scripts/op-preflight.sh` materializes a 1Password ADC item whose underlying `refresh_token` has been revoked or expired by Google, `op-firebase-deploy` will refuse the credential with:

```
Error: GOOGLE_APPLICATION_CREDENTIALS points to an unusable credential file: /var/folders/.../op-preflight-adc-*
```

Starting with the #137 fix, `op-preflight.sh` validates the materialized ADC against the OAuth2 `/token` endpoint before exporting `GOOGLE_APPLICATION_CREDENTIALS`. In Firebase repos, deploy preflight tries the project Firebase-vault SA key before this shared ADC path, so a provisioned project key avoids the RAPT-prone credential entirely. When the shared ADC is still needed and is stale, preflight prints an actionable warning and skips the export — downstream callers (`op-firebase-deploy`, `gcloud` wrappers) then fall back to the next available credential.

**Fix permanently** by refreshing the 1Password item:

```bash
gcloud auth application-default login
# then copy the freshly-written JSON into the 1Password item:
op document edit 'GCP ADC' --vault=Private \
  ~/.config/gcloud/application_default_credentials.json
# (or `op item edit` if stored as an item field)
```

After that, the next preflight run will materialize a usable credential and the `GOOGLE_APPLICATION_CREDENTIALS` export resumes normally.

For routine Firebase deploys, the preferred permanent fix is to provision or rotate the project Firebase-vault SA key instead of depending on the shared human ADC. The shared ADC remains a fallback for projects that have not provisioned the key and for non-Firebase `gcloud` operations.

## Changelog

**2026-05-15: Deploy credential precedence updated.** Project Firebase-vault SA keys are now the default for `op-firebase-deploy`. See #154 / #211 for implementation history; live consumer verification on matchline pending (#211 close-out).

**2026-05-22: Deploy preflight caches the project SA key first.** In Firebase repos, `op-preflight.sh --mode deploy|all` now materializes the project Firebase-vault SA key before trying the shared GCP ADC. This removes the routine stale-ADC/RAPT probe from attended deploy sessions when the durable project key exists.

**2026-05-15: `op-firebase-setup --provision-sa-key` flag added.** The setup script now optionally mints the deployer SA key and uploads it to `op://Firebase/{project-id} — Firebase Deployer SA Key` as part of the same attended invocation, folding the previously-manual DEPLOYMENT.md procedure into the script. Opt-in to preserve the prior impersonation-only behavior contract. See #154 close-out.
