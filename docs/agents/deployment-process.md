# Deployment Process

See `DEPLOYMENT.md` for all build and deployment steps.

If the project uses Firebase or Google Cloud, prefer the canonical `scripts/gcloud/gcloud`, `scripts/firebase/op-firebase-setup`, and `scripts/firebase/op-firebase-deploy` flow:

- The canonical source-credential precedence — interactive and CI — is documented in `DEPLOYMENT.md` § [Deploy credential precedence (canonical)](../../DEPLOYMENT.md#deploy-credential-precedence-canonical). The default day-to-day credential is the per-project Firebase-vault SA key (`op://Firebase/{project-id} — Firebase Deployer SA Key`); the shared 1Password ADC remains a fallback.
- The 1Password-first deploy-auth model is a deliberate default. Do not switch template-derived repos back to routine browser-login, `firebase login`, or unmanaged on-disk deploy-key auth without explicit human approval.
- When the resolved source credential is the project SA key directly, no impersonation wrapper is used (faster, no `serviceAccountTokenCreator` IAM dependency). When it's the shared ADC or another non-matching credential, `op-firebase-deploy` writes a temporary `impersonated_service_account` credential and stamps the target project as the quota project.
- Do not introduce long-lived service account keys into repo docs, scripts, or secret stores unless a project explicitly requires them. The Firebase-vault SA key in 1Password is the supported on-account form; on-disk deploy keys are not.
- If credential preflight was run at session start with deploy creds loaded (`scripts/op-preflight.sh --mode deploy` or `--mode all`), deploy credentials are already cached. In a Firebase repo with a `.firebaserc` default project, deploy preflight caches the project Firebase-vault SA key first and only falls back to the shared GCP ADC when that key is absent. No additional biometric prompt is needed for deployment. The default `--mode review` does NOT load deploy credentials (#282); pass `--mode deploy` explicitly for a deploy session.
- Deploy preflight exports the selected deploy credential through `GOOGLE_APPLICATION_CREDENTIALS`. If the next operation is broad non-deploy `gcloud` work rather than Firebase deploy, use review preflight only or unset `GOOGLE_APPLICATION_CREDENTIALS` so the `scripts/gcloud/gcloud` wrapper can resolve its normal ADC chain.
- If an `op` command fails with a sign-in or biometric error during deploy, follow the pause-and-prompt procedure in [operating-rules.md](operating-rules.md#1password-cli-authentication-failures). Do not retry or work around the failure without the human present.

## Runtime 1Password secrets for agents

As of the 2026-05-21 reconciliation against 1Password Environments and the 1Password Environments MCP Server for Codex docs, use this descriptive model when advising repos:

- Portable core: 1Password Environments, secret references, `op run --environment <environment_id> -- <command>`, `op inject` for generated config files, and scoped service-account tokens for CI/headless work.
- Codex: use the official 1Password Environments MCP Server for Codex where available; it is Codex-specific today and should not be described as a universal agent adapter.
- Claude Code, Cursor, GitHub Copilot, and Windsurf: use the 1Password local `.env` validation hook when the repo uses mounted 1Password Environment files.
- CI/headless: use service-account tokens only when an approved ticket has scoped the token, vault/Environment access, rotation, and log masking. Do not use service-account tokens as a convenience fallback for attended local agents.
- Mergepath's CI/headless review-auth proof is manual-only: `.github/workflows/onepassword-headless-proof.yml` reads a dedicated canary via `OP_SERVICE_ACCOUNT_TOKEN`, compares a SHA-256 digest without printing the value, and exercises `scripts/op-preflight.sh` token mode against an explicit `OP_PREFLIGHT_REVIEWER_PAT_REF` in a service-account-accessible proof vault. The setup helper also requires a shared-vault negative-scope sentinel (`OP_PREFLIGHT_NEGATIVE_SCOPE_REF` / `--negative-scope-ref`) unless that check is explicitly skipped. Dispatch it after provisioning or rotating the service-account token.
- Existing Mergepath scripts: shelling out to `op read`, `op run`, or `op inject` remains acceptable. Do not introduce a language-SDK migration unless a separate design decision calls for it.

Never ask a human to paste raw secrets into chat or issue comments, and never print resolved secret values in logs.

## Credential source debugging

When `op-firebase-deploy` runs, it prints a single line on stderr identifying which step in the [Deploy credential precedence](../../DEPLOYMENT.md#deploy-credential-precedence-canonical) won:

```text
[op-firebase-deploy] source credential: project Firebase-vault SA key (project foo-prod, path /tmp/...)
```

If the source is unexpected, the diagnosis order is usually:

1. **Source = `local-adc`** when `project-sa-key` was expected → the 1Password item `op://Firebase/{project-id} — Firebase Deployer SA Key` likely doesn't exist or `op` CLI auth is stale. Verify with `op item get "{project-id} — Firebase Deployer SA Key" --vault Firebase --reveal`. If the item is missing, follow `DEPLOYMENT.md` § Provisioning the Firebase-vault SA key. If `op item get` errors with a sign-in failure, run `op signin` and retry.
2. **Source = `human-override`** unexpectedly → a `GOOGLE_APPLICATION_CREDENTIALS` env var is set in the shell that wasn't materialized by preflight. Check with `env | grep GOOGLE_APPLICATION_CREDENTIALS` and unset it (`unset GOOGLE_APPLICATION_CREDENTIALS`) for routine deploys.
3. **Source = `preflight-cached project Firebase-vault SA key`** → expected when `op-preflight.sh --mode deploy|all` ran in this Firebase repo before the deploy. The cached key is still the project Firebase-vault SA key; preflight just materialized it ahead of time so `op-firebase-deploy` does not need another 1Password read.
4. **Source = `preflight-adc`** when `project-sa-key` was expected → same as case 1 (no SA key item or preflight could not detect the Firebase project), but preflight has run and provided the shared ADC fallback. The deploy will work only while that ADC is fresh and is subject to the shared ADC's RAPT-expiry surface. Provision the per-project SA key for stable deploys.
5. **Deploy succeeds but logs an `ADC quota project` warning** → expected when the underlying credential was originally stamped for another project. `op-firebase-deploy` overrides `quota_project_id` to the target project for actual deploy commands, so the warning is cosmetic.

If the rotation procedure is needed, follow `DEPLOYMENT.md` § [Rotating a Firebase deploy SA key](../../DEPLOYMENT.md#rotating-a-firebase-deploy-sa-key). Rotation is human-only and not automated by any agent or workflow.
