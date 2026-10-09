---
spec_id: credential_isolation
---

# Authority credential isolation

`audit-branch-protection.sh --require-credential-isolation` and its fleet mode report drift when an author, reviewer, service-account or privileged automation credential remains a repository-scoped Actions secret. The protected `merge-queue-policy` environment must disable administrator bypass and allow only its literal default branch through custom branch policies. Wildcards, tags, additional branches and unrestricted/protected-branches-only configurations grant no pass.

The audit reads secret names and environment settings, never secret values. For an organization-owned repository, it also checks every organization secret shared with that repository. Paginated counts must agree and every record must be readable. A missing credential environment is drift only after a complete, readable environment inventory confirms its absence; a 404 alone cannot prove absence. API, scope or schema failures return infrastructure error (2); observed placement/protection drift returns 3; complete isolated observations return 0. The option is explicit because the existing protection auditor's Administration:read permission alone cannot list Secrets or Environments.

Rollout requires provisioning environment secrets from their trusted vault sources, verifying trusted default-branch workflows can consume them, and then deleting the repository-scoped copies. It also requires moving any PR-controlled privileged-token consumer to a trusted execution path. An audit implementation alone does not complete that rollout or close issue #1547.

Credential isolation uses the actual repository default branch independently of the branch-protection target selected by `--branch`. The authority-secret set includes both merge-queue policy/source tokens.

This opt-in audit reports the credential exposure and environment access restrictions requested by #1547; a PASS is scoped to those observations. It does not certify native merge-queue readiness, require provisioned credentials on a queue-disabled repository, impose the queue-specific three-secret inventory, or reject additional deployment approval controls. Native queue activation retains its separate complete topology checks in `scripts/lib/merge-queue-protection.sh`, including the exact three-secret environment inventory and exclusion of reviewers and wait timers. No setting, credential provisioning, deletion or rotation is performed by this audit.
