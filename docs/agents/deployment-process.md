# Deployment Process

See `DEPLOYMENT.md` for all build and deployment steps.

If the project uses Firebase or Google Cloud, prefer the canonical
`scripts/gcloud/gcloud`, `scripts/firebase/op-firebase-setup`, and
`scripts/firebase/op-firebase-deploy` flow:

- Humans normally authenticate through the shared 1Password-backed GCP ADC source credential
- The 1Password-first deploy-auth model is a deliberate default. Do not switch template-derived repos back to ADC-first, routine browser-login, `firebase login`, or long-lived deploy-key auth without explicit human approval.
- Deploys use short-lived service account impersonation
- CI should prefer Workload Identity Federation or another
  `external_account` source credential
- Do not introduce long-lived service account keys into repo docs,
  scripts, or secret stores unless a project explicitly requires them
