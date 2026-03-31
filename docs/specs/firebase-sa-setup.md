# Firebase Service Account Key Setup for Headless Deploys

## Overview

This document describes the setup of Firebase service account keys across all production projects to enable headless deploys from non-interactive environments (Claude Code cloud tasks, CI runners, scheduled automations). It captures the original goal, every issue encountered during implementation, the resolution for each, and the final working deployment architecture.

Prior to this work, all Firebase deploys required an interactive 1Password session (biometric auth via Touch ID) to retrieve GCP Application Default Credentials and impersonate the `firebase-deployer` service account. This blocked any automated or scheduled deploy workflow.

---

## Original Request

**Goal:** For each Firebase project, create a dedicated GCP service account with a non-expiring JSON key so `firebase deploy` can run in headless/CI environments without interactive login. Store each key in 1Password for portability.

**Projects:**

| Project ID | Deploy Scope |
|---|---|
| `device-platform-reporting` | Hosting, Cloud Functions, Firestore, Cloud Storage |
| `device-source-of-truth` | Hosting, Cloud Functions, Firestore, Cloud Storage |
| `friends-and-family-billing` | Hosting, Cloud Functions, Firestore, Cloud Storage |
| `nathanpaynedotcom` | Hosting (Next.js static export), Firestore, Cloud Storage |
| `soyouthinkyouwant` (Override Broadway) | Hosting (Next.js static export), Firestore, Cloud Storage |
| `swipewatch` | Hosting, Firestore, Cloud Storage |

**Per-project steps:**
1. Verify the GCP project exists
2. Create a `firebase-deployer` service account (or reuse existing)
3. Grant minimum IAM roles based on deploy scope
4. Generate a JSON key file
5. Store the key in a 1Password vault called "Firebase"
6. Verify the key works for deploy
7. Clean up local key files

---

## Issues Encountered & Resolutions

### Issue 1: `gcloud projects list` extremely slow

**Symptom:** `gcloud projects list` hung for minutes, eventually timing out. Multiple attempts with different `--format` flags all timed out.

**Root cause:** The GCP account belongs to a large organization. `gcloud projects list` enumerates every project in the org, which is extremely slow on large orgs.

**Resolution:** Used `firebase projects:list` instead, which returned results in seconds and provided all the project IDs needed. The Firebase CLI queries only the user's Firebase projects, not the entire GCP org.

### Issue 2: Project ID mismatch

**Symptom:** Two project IDs from the original request didn't match any real Firebase project:
- `ai-agent-repo-template` was not a Firebase project (it's a GitHub template repo, no hosting)
- `overridebroadway` didn't exist; the actual Firebase project was `soyouthinkyouwant`

**Resolution:** Mapped each expected name to the real project ID via `firebase projects:list`. Skipped `ai-agent-repo-template` (template only). Used `soyouthinkyouwant` for Override Broadway and renamed its GCP display name from "SoYouThinkYouWant" to "Override Broadway" via `gcloud projects update`. (GCP project IDs are immutable, but display names can be changed.)

### Issue 3: IAM API not enabled

**Symptom:** `gcloud iam service-accounts create` failed on `device-platform-reporting` and `swipewatch` with:
```
API [iam.googleapis.com] not enabled on project [device-platform-reporting].
```

**Root cause:** These projects had never used the IAM API directly (service accounts were created through the Firebase Console or other paths).

**Resolution:** Ran `gcloud services enable iam.googleapis.com --project=<project>` for each affected project. This took 1-2 minutes per project. After enabling, service account creation succeeded.

### Issue 4: `gcloud auth` token expiry mid-session

**Symptom:** After completing several service account operations, `gcloud services enable` failed with:
```
Reauthentication failed. cannot prompt during non-interactive execution.
```

**Root cause:** The gcloud access token (stored at `~/.config/gcloud/adc-access-token`) expired during the long-running session. The non-interactive environment couldn't prompt for re-authentication.

**Resolution:** Paused execution and had the user run `gcloud auth login` interactively to refresh the session token, then resumed.

### Issue 5: 1Password auth timeout with parallel `op` commands

**Symptom:** When storing all 6 SA key files in 1Password simultaneously (parallel `op document create` calls), all 6 failed with:
```
[ERROR] authorization timeout
```

**Root cause:** Running multiple `op` commands in parallel triggers multiple simultaneous biometric (Touch ID) prompts. macOS can only handle one biometric prompt at a time; the rest time out.

**Resolution:** Ran the 6 `op document create` commands sequentially instead of in parallel. Each prompt was approved one at a time via Touch ID. All 6 succeeded.

### Issue 6: `op document get` refuses to overwrite files created by `mktemp`

**Symptom:** After adding the `materialize_firebase_vault_sa_key()` function to `op-firebase-deploy`, the SA key retrieval silently failed. The temp file created by `mktemp` remained empty (0 bytes).

**Root cause:** `op document get --out-file <path>` refuses to overwrite an existing file unless the `--force` flag is passed. `mktemp` creates the file before `op` runs, so `op` sees an existing file and exits with:
```
[ERROR] cannot prompt for confirmation. Use the '-f' or '--force' flag to skip confirmation.
```
This error was suppressed by `2>/dev/null`.

**Resolution:** Added `--force` to the `op document get` command:
```bash
op document get "${project} — Firebase Deployer SA Key" \
  --vault Firebase --out-file "$tmpfile" --force >/dev/null 2>&1
```

### Issue 7: `op document get` stdout pollution

**Symptom:** After fixing the `--force` issue, the deploy script still failed with "No usable GCP source credential found."

**Root cause:** `op document get --out-file <path>` prints the output file path to stdout (e.g., `/tmp/firebase-sa-kZcyUB`). The function also calls `printf '%s\n' "$tmpfile"` to return the path. The calling code captures this via command substitution `$(materialize_firebase_vault_sa_key ...)`, producing a **two-line string**:
```
/var/folders/.../firebase-sa-kZcyUB    (from op stdout)
/var/folders/.../firebase-sa-kZcyUB    (from printf)
```
This multi-line value was assigned to `SOURCE_CRED_FILE`, which then failed the `[[ -f "$SOURCE_CRED_FILE" ]]` check because the path contained a newline.

**Resolution:** Suppressed `op document get` stdout by redirecting to `/dev/null`:
```bash
op document get ... --out-file "$tmpfile" --force >/dev/null 2>&1
```
Now only the `printf` output reaches the caller, producing a clean single-line path.

### Issue 8: Background `op` processes can't do biometric auth

**Symptom:** The original `materialize_firebase_vault_sa_key()` function (modeled after `materialize_op_source_cred()`) ran `op document get` in the background with `&` and a 5-second timeout loop. The background process always failed.

**Root cause:** `op document get` requires foreground access to trigger Touch ID biometric authentication. Background processes (`&`) cannot present the macOS biometric prompt. The original `materialize_op_source_cred` function uses backgrounding because `op read` (for individual fields) can sometimes work without biometric if the session is cached, and the timeout prevents hangs. But `op document get` (for whole documents) consistently requires interactive auth.

**Resolution:** Rewrote `materialize_firebase_vault_sa_key()` to run `op document get` in the foreground (no `&`, no polling loop). This allows Touch ID to prompt naturally. The function simply runs and succeeds or fails:
```bash
if op document get "${project} — Firebase Deployer SA Key" \
     --vault Firebase --out-file "$tmpfile" --force >/dev/null 2>&1 \
   && [[ -s "$tmpfile" ]]; then
```

### Issue 9: Unnecessary impersonation when source IS target

**Symptom:** The original `op-firebase-deploy` script always wrapped the source credential in an `impersonated_service_account` credential, even when the source was already the `firebase-deployer@{project}.iam.gserviceaccount.com` service account key.

**Root cause:** The script was designed for ADC impersonation (user credential impersonates SA). When using a direct SA key, the script would create a self-impersonation wrapper, requiring `roles/iam.serviceAccountTokenCreator` on the SA itself — an unnecessary IAM binding.

**Resolution:** Added a conditional in the Python impersonation block that detects when the source credential's `client_email` matches the target SA email, and skips the impersonation wrapper:
```python
if source.get("type") == "service_account" and source.get("client_email") == service_account:
    out_path.write_text(json.dumps(source))
else:
    config = {
        "type": "impersonated_service_account",
        ...
    }
    out_path.write_text(json.dumps(config))
```

---

## Final Working Solution

### Credential Resolution Chain

The updated `op-firebase-deploy` script resolves credentials in this order:

1. **`GOOGLE_APPLICATION_CREDENTIALS` env var** — If set and pointing to a valid file, use it directly. This is the primary mechanism for CI/CD and headless environments.

2. **Project SA key from 1Password Firebase vault** — Calls `op document get "{project-id} — Firebase Deployer SA Key" --vault Firebase` in the foreground. This is a `service_account` JSON key that authenticates directly as the deployer SA.

3. **Shared ADC from 1Password Private vault** — Calls `op read "op://Private/GCP ADC/credential"` (backgrounded with 5s timeout). This is a user-level `authorized_user` credential that requires impersonation to act as the deployer SA.

4. **Local ADC file** — Falls back to `~/.config/gcloud/application_default_credentials.json` if present. Same impersonation flow as step 3.

### Self-Impersonation Skip

When the resolved source credential is a `service_account` type and its `client_email` matches the target `firebase-deployer@{project-id}.iam.gserviceaccount.com`, the script uses the key directly without wrapping it in an impersonation credential. This:
- Eliminates the need for `roles/iam.serviceAccountTokenCreator` on the SA
- Reduces one API call (no `generateAccessToken` needed)
- Works in fully offline/headless environments with no dependency on IAM Credentials API

### Script Changes (`op-firebase-deploy`)

Three additions to the canonical `op-firebase-deploy` script:

1. **`materialize_firebase_vault_sa_key()` function** — Retrieves the project SA key from 1Password Firebase vault. Runs in foreground (not backgrounded) to allow biometric auth. Uses `--force` to overwrite the mktemp file. Suppresses stdout with `>/dev/null 2>&1`.

2. **Updated `resolve_source_cred_file()`** — Inserts the Firebase vault SA key check as step 2 in the credential chain, between `GOOGLE_APPLICATION_CREDENTIALS` and the shared ADC.

3. **Conditional impersonation skip** — Python block detects when source `client_email` matches target SA and writes the credential directly instead of wrapping in `impersonated_service_account`.

### 1Password Architecture

| Vault | Purpose | Auth Model |
|---|---|---|
| **Firebase** | Project-specific SA key JSON files (one per project) | Document items, retrieved via `op document get` |
| **Private** | Shared GCP ADC (user-level credential for impersonation) | Secure Note field, retrieved via `op read` |

The Firebase vault stores `service_account` JSON keys. These are self-contained credentials that authenticate directly as the deployer SA without any impersonation or token exchange. They are the preferred credential for headless/CI environments.

The Private vault stores a single shared `authorized_user` credential (from `gcloud auth application-default login`). This credential requires impersonation to act as the deployer SA. It is suitable for interactive use but not for headless environments because it can expire and requires browser-based refresh.

---

## Per-Project Deployment Reference

### IAM Roles

**Projects with Cloud Functions** (device-platform-reporting, device-source-of-truth, friends-and-family-billing):
- `roles/firebase.developAdmin`
- `roles/iam.serviceAccountUser`

**Projects without Cloud Functions** (nathanpaynedotcom, soyouthinkyouwant, swipewatch):
- `roles/firebasehosting.admin`
- `roles/datastore.user`
- `roles/storage.admin`

### Service Accounts & Keys

| Project ID | SA Email | 1Password Item | Item ID | Vault |
|---|---|---|---|---|
| `device-platform-reporting` | `firebase-deployer@device-platform-reporting.iam.gserviceaccount.com` | `device-platform-reporting — Firebase Deployer SA Key` | `agca53lr3wgtjhrjnpyesojmma` | Firebase |
| `device-source-of-truth` | `firebase-deployer@device-source-of-truth.iam.gserviceaccount.com` | `device-source-of-truth — Firebase Deployer SA Key` | `ruiswfa5hwpwbkfz5vy462woky` | Firebase |
| `friends-and-family-billing` | `firebase-deployer@friends-and-family-billing.iam.gserviceaccount.com` | `friends-and-family-billing — Firebase Deployer SA Key` | `edzuvkafretsjow5g6a26m6tza` | Firebase |
| `nathanpaynedotcom` | `firebase-deployer@nathanpaynedotcom.iam.gserviceaccount.com` | `nathanpaynedotcom — Firebase Deployer SA Key` | `cjitzliqlvivlqfltei2drrxcq` | Firebase |
| `soyouthinkyouwant` | `firebase-deployer@soyouthinkyouwant.iam.gserviceaccount.com` | `soyouthinkyouwant — Firebase Deployer SA Key` | `4qdvazbu2ks73cq5fnvqifb5fq` | Firebase |
| `swipewatch` | `firebase-deployer@swipewatch.iam.gserviceaccount.com` | `swipewatch — Firebase Deployer SA Key` | `nlmfucz7273d6qagvrz2hqeuli` | Firebase |

### Deploy Commands

All projects use the same `op-firebase-deploy` script (installed at `~/.local/bin/op-firebase-deploy`). The project is auto-detected from `.firebaserc`.

```bash
# From any project directory:
npm run deploy              # Full deploy (hosting + rules + functions if applicable)
npm run deploy:hosting      # Hosting only

# Or directly:
op-firebase-deploy --only hosting
op-firebase-deploy --only firestore:rules
op-firebase-deploy --only functions    # Only for projects with Cloud Functions
```

---

## Usage Instructions

### Local Development (Interactive Machine)

No extra setup needed. `op-firebase-deploy` automatically tries the Firebase vault SA key, then falls back to the shared ADC. Touch ID will prompt if needed.

```bash
cd ~/GitHub/overridebroadway
npm run deploy
```

### Headless Deploy (One-Time Key Export)

On an interactive machine, pull the key once:

```bash
mkdir -p ~/firebase-keys
op document get "soyouthinkyouwant — Firebase Deployer SA Key" \
  --vault Firebase --out-file ~/firebase-keys/soyouthinkyouwant-sa-key.json
```

Then deploy without 1Password:

```bash
GOOGLE_APPLICATION_CREDENTIALS=~/firebase-keys/soyouthinkyouwant-sa-key.json \
  npm run deploy
```

### Claude Code Cloud Scheduled Tasks

1. On an interactive machine, retrieve the SA key:
   ```bash
   op document get "{project-id} — Firebase Deployer SA Key" --vault Firebase
   ```
2. Copy the JSON contents
3. In claude.ai/code/scheduled, create or edit the task's cloud environment
4. Add an environment variable: `FIREBASE_SA_KEY=<paste JSON>`
5. In the task prompt or setup script:
   ```bash
   echo "$FIREBASE_SA_KEY" > /tmp/sa-key.json
   export GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa-key.json
   npm install -g firebase-tools
   ```

### New Machine Setup

```bash
# 1. Install tools
brew install --cask 1password-cli
npm install -g firebase-tools

# 2. Install deploy scripts from the template repo
mkdir -p ~/.local/bin
cp ~/GitHub/ai_agent_repo_template/scripts/firebase/op-firebase-deploy ~/.local/bin/
cp ~/GitHub/ai_agent_repo_template/scripts/firebase/op-firebase-setup ~/.local/bin/
chmod +x ~/.local/bin/op-firebase-deploy ~/.local/bin/op-firebase-setup

# 3. Sign into 1Password
op signin

# 4. Deploy from any project
cd ~/GitHub/overridebroadway
npm run deploy
```

### Key Retrieval on a New Machine

```bash
# Pull a specific project's SA key:
op document get "{project-id} — Firebase Deployer SA Key" \
  --vault "Firebase" \
  --out-file ~/firebase-keys/{project-id}-sa-key.json

# Then either export it:
export GOOGLE_APPLICATION_CREDENTIALS=~/firebase-keys/{project-id}-sa-key.json

# Or use it inline:
GOOGLE_APPLICATION_CREDENTIALS=~/firebase-keys/{project-id}-sa-key.json firebase deploy
```

---

## Global Gitignore

The `firebase-keys/` directory is excluded globally via `~/.gitignore_global`:

```
# Firebase SA keys
firebase-keys/
```

This prevents accidental commits of service account key files from any repository.
