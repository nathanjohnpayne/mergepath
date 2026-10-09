---
spec_id: credential_isolation
---

# Authority credential isolation

`audit-branch-protection.sh --require-credential-isolation` and its fleet mode report drift when an author, reviewer, service-account or privileged automation credential remains a repository-scoped Actions secret. The protected `merge-queue-policy` environment must disable administrator bypass and allow only its literal default branch through custom branch policies. Wildcards, tags, additional branches and unrestricted/protected-branches-only configurations grant no pass.

The audit reads secret names and environment settings, never secret values. Paginated counts must agree and every record must be readable. API, scope or schema failures return infrastructure error (2); observed placement/protection drift returns 3; complete isolated observations return 0. The option is explicit because the existing protection auditor's Administration:read permission alone cannot list Secrets or Environments.

Rollout requires provisioning environment secrets from their trusted vault sources, verifying trusted default-branch workflows can consume them, and then deleting the repository-scoped copies. It also requires moving any PR-controlled privileged-token consumer to a trusted execution path. An audit implementation alone does not complete that rollout or close issue #1547.

Credential isolation uses the actual repository default branch independently of the branch-protection target selected by `--branch`. The authority-secret set includes both merge-queue policy/source tokens.
