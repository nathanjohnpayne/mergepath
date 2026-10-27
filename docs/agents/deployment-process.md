# Deployment Process

This file is repo-owned: the credentials, commands, and environments below belong to the repository carrying this copy. The fleet-wide secret-handling floor that constrains all of them — no secrets through a human, no long-lived keys by convenience, no unilateral downgrade of a repo's auth model — lives in [`shared-operating-rules.md`](shared-operating-rules.md) § Secret handling. The separate [Build and deploy isolation](shared-operating-rules.md#build-and-deploy-isolation) contract governs when credentials may be acquired and which processes may access them.

See `DEPLOYMENT.md` for all build and deployment steps.

If the project uses Firebase or Google Cloud, use the canonical `scripts/gcloud/gcloud` and `scripts/firebase/op-firebase-setup` helpers for their supported non-deployment tasks. Production deployment is blocked in this repository until separately reviewed tooling provides credential-free builds and trusted post-build artifact verification and deployment.

- The legacy source-credential precedence is documented in `DEPLOYMENT.md` § [Deploy credential precedence (canonical)](../../DEPLOYMENT.md#deploy-credential-precedence-canonical). It describes runtime resolution only; it does not authorize production deployment.
- The 1Password-first deploy-auth model is a deliberate default here, and the no-unilateral-downgrade rule above is what forbids swapping it for routine browser-login or `firebase login` when a lookup fails.
- When the resolved source credential is the project SA key directly, no impersonation wrapper is used (faster, no `serviceAccountTokenCreator` IAM dependency). When it's the shared ADC or another non-matching credential, `op-firebase-deploy` writes a temporary `impersonated_service_account` credential and stamps the target project as the quota project.
- The Firebase-vault SA key in 1Password is this repo's supported on-account form of the "no long-lived keys by convenience" rule; on-disk deploy keys are not an accepted substitute for it.
- Build the production artifact on a separate runner or account with no deploy credentials, author/reviewer PATs, or access to the operator's credential-manager files or preflight cache. Same-user environment unsetting and cache-file permissions do not provide this isolation. After the build succeeds, trusted post-build tooling must verify the immutable artifact's digest and repository/revision attestation before acquiring deploy credentials; deploy that verified artifact without rebuilding or running candidate code. Inject each credential only into its consuming subprocess. Follow [Build and deploy isolation](shared-operating-rules.md#build-and-deploy-isolation) for the complete contract.
- For review work that needs author or reviewer PATs, check preflight status before evaluating its output: `preflight_exports="$(scripts/op-preflight.sh --agent codex --mode review)" && eval "$preflight_exports"`; replace `codex` with the current agent name (`claude`, `cursor`, or `codex`). If this returns nonzero, stop and ask the human to confirm readiness before retrying; do not continue with credential-dependent commands. The current `--mode deploy` is not an approved deployment path because a cache hit can export both review PATs from the shared session file, and evaluating its output places exports in the caller's whole shell. Do not invoke or evaluate it as deployment setup. `--mode all` also combines review and deploy credentials and must not be used for builds or deployment. The default `--mode review` does not load deploy credentials (#282).
- Existing runtime behavior: **`--mode all` can return success without deploy credentials** when neither the SA key nor usable ADC loads; it still exports PATs, warns on stderr, and reuses that degraded result for `OP_PREFLIGHT_DEPLOY_DEGRADED_BACKOFF_SECONDS` (default 900s). This documents legacy behavior only; no current preflight mode is approved for deployment. Production deployment remains blocked until separately reviewed post-build tooling selects only deploy credentials and injects each into its one consuming subprocess after artifact verification.
- The legacy deploy preflight exports credentials into its caller's environment; it is not a credential-scoped subprocess adapter. Do not evaluate deploy-mode exports in an interactive shell or build session. The future trusted adapter must avoid exposing PATs and unrelated shell processes to deploy credentials.
- If an `op` command fails with a sign-in or biometric error during deploy, follow the pause-and-prompt procedure in [operating-rules.md](operating-rules.md#1password-cli-authentication-failures). Do not retry or work around the failure without the human present.

## Runtime 1Password secrets for agents

As of the 2026-05-21 reconciliation against 1Password Environments and the 1Password Environments MCP Server for Codex docs, use this descriptive model when advising repos:

- Portable core: 1Password Environments, secret references, `op run --environment <environment_id> -- <command>`, `op inject` for generated config files, and scoped service-account tokens for CI/headless work.
- Codex: use the official 1Password Environments MCP Server for Codex where available; it is Codex-specific today and should not be described as a universal agent adapter.
- Claude Code, Cursor, GitHub Copilot, and Windsurf: use the 1Password local `.env` validation hook when the repo uses mounted 1Password Environment files.
- CI/headless: use service-account tokens only when an approved ticket has scoped the token, vault/Environment access, rotation, and log masking. Do not use service-account tokens as a convenience fallback for attended local agents.
- Mergepath's CI/headless review-auth proof is manual-only: `.github/workflows/onepassword-headless-proof.yml` reads a dedicated canary via `OP_SERVICE_ACCOUNT_TOKEN`, compares a SHA-256 digest without printing the value, and exercises `scripts/op-preflight.sh` token mode against an explicit `OP_PREFLIGHT_REVIEWER_PAT_REF` in a service-account-accessible proof vault. The setup helper also requires a shared-vault negative-scope sentinel (`OP_PREFLIGHT_NEGATIVE_SCOPE_REF` / `--negative-scope-ref`) unless that check is explicitly skipped. Dispatch it after provisioning or rotating the service-account token.
- Existing Mergepath scripts: shelling out to `op read`, `op run`, or `op inject` remains acceptable. Do not introduce a language-SDK migration unless a separate design decision calls for it.

## Per-repository author token

`AUTHOR_MERGE_TOKEN` moves from the shared classic `nathanjohnpayne` PAT to one fine-grained PAT per repository, in that repository's `merge-queue-policy` environment ([`specs/author_merge_token.md`](../../specs/author_merge_token.md), #2728). The owner mints, stores, sets, rotates and revokes every copy. An agent never reads, sets or deletes the secret.

- **Policy flip:** an agent may open a repository's cutover PR setting `author_merge_token_class: fine-grained` in `.github/review-policy.yml` only after the owner says that repository's token is set and verified (runbook steps 1 to 5). Setting it earlier makes C14 and the approval continuation fail closed on the classic fallback.
- **One key, one spelling:** never add a second `author_merge_token_class` line; change the existing one. Write it exactly `author_merge_token_class: <value>` at the start of the line. A repeated key fails closed as `duplicate-key`, and any other spelling (a quoted key, a space before the colon) fails closed as `malformed-key`.
- **Diagnosing a failure:** a job that says the token does not meet `fine-grained` resolved a value that is not a fine-grained PAT. The most likely cause is a missing environment copy, so the job fell back to the classic repository secret; the environment copy may also be empty, classic or the wrong value. Ask the owner to check the environment secret's presence and its 1Password source item. It is an owner fix, not something to retry.

## Credential source debugging

When `op-firebase-deploy` runs, it prints a single line on stderr identifying which step in the [Deploy credential precedence](../../DEPLOYMENT.md#deploy-credential-precedence-canonical) won:

```text
[op-firebase-deploy] source credential: project Firebase-vault SA key (project foo-prod, path /tmp/...)
```

If the source is unexpected, the diagnosis order is usually:

1. **Source = `local-adc`** when `project-sa-key` was expected → the 1Password item `op://Firebase/{project-id} — Firebase Deployer SA Key` likely doesn't exist or `op` CLI auth is stale. Verify with `op item get "{project-id} — Firebase Deployer SA Key" --vault Firebase --reveal`. If the item is missing, follow `DEPLOYMENT.md` § Provisioning the Firebase-vault SA key. If `op item get` errors with a sign-in failure, run `op signin` and retry.
2. **Source = `human-override`** unexpectedly → a `GOOGLE_APPLICATION_CREDENTIALS` env var is set in the shell that wasn't materialized by preflight. Check with `env | grep GOOGLE_APPLICATION_CREDENTIALS` and unset it (`unset GOOGLE_APPLICATION_CREDENTIALS`) for routine deploys.
3. **Source = `preflight-cached project Firebase-vault SA key`** → legacy source label only. Current `--mode deploy` cache hits can also emit review PATs, so this is not evidence of an approved trusted deployment flow.
4. **Source = `preflight-adc`** when `project-sa-key` was expected → same as case 1 (no SA key item or preflight could not detect the Firebase project), but preflight has run and provided the shared ADC fallback. The deploy will work only while that ADC is fresh and is subject to the shared ADC's RAPT-expiry surface. Provision the per-project SA key for stable deploys.
5. **Deploy succeeds but logs an `ADC quota project` warning** → expected when the underlying credential was originally stamped for another project. `op-firebase-deploy` overrides `quota_project_id` to the target project for actual deploy commands, so the warning is cosmetic.

If the rotation procedure is needed, follow `DEPLOYMENT.md` § [Rotating a Firebase deploy SA key](../../DEPLOYMENT.md#rotating-a-firebase-deploy-sa-key). Rotation is human-only and not automated by any agent or workflow.
