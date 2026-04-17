# Project Template

This repository follows the **AI Agent Tooling Standard**.

The goal is to allow multiple AI coding agents and development tools to operate
consistently without configuration drift.

## For AI Agents

Read these files in order before taking any action:

1. `AGENTS.md` — behavioral instructions and operating rules
2. `rules/repo_rules.md` — binding structural constraints
3. Relevant `specs/` files — intended behavior
4. `.ai_context.md` — supplemental system context

## Code Review Policy

Every change in this repository goes through the policy in `REVIEW_POLICY.md`,
including a self-peer review by the authoring agent's reviewer identity and,
for changes that cross the threshold or touch protected paths, automated
external review via the OpenAI Codex GitHub app (Phase 4a) or a manual CLI
fallback (Phase 4b).

## Key Files

| File | Purpose |
|---|---|
| `AGENTS.md` | Instructions for AI agents |
| `DEPLOYMENT.md` | Build and deployment |
| `CONTRIBUTING.md` | Development workflow |
| `.ai_context.md` | High-level system context |
| `mockups/mergepath.html` | Mergepath dashboard — tune the review policy and replay recent PRs against the draft |
| `scripts/policy-sim.sh` | Bakes real `gh` PR data into a temp copy of the Mergepath dashboard for local replay |
| `ai_agent_tooling_standard.md` | Full repository standard (reference) |

## Firebase Auth Template

This template includes the canonical Google Cloud and Firebase helper scripts for this account:

- `scripts/gcloud/gcloud` installs a local wrapper so ordinary `gcloud` commands can use 1Password-backed or explicit source credentials without a routine interactive `gcloud auth login`, while attributing quota to the resolved target project from explicit flags, the repo's `.firebaserc`, or the active `gcloud` config.
- `scripts/firebase/op-firebase-setup` creates a per-project `firebase-deployer@{project-id}.iam.gserviceaccount.com`, grants deploy roles, and configures impersonation.
- `scripts/firebase/op-firebase-deploy` turns a 1Password-backed or explicit source credential, or a CI-provided `external_account` credential, into a temporary impersonated credential for `firebase deploy`, with the target project stamped in as the quota project.

Human maintainers should use 1Password-backed GCP ADC plus service account impersonation. CI should prefer Workload Identity Federation or another `external_account` source credential instead of stored service-account keys.

This 1Password-first deploy-auth model is intentional. Do not revert template-derived repos to ADC-first or deploy-key-based guidance unless a human explicitly requests that change.

See `DEPLOYMENT.md` for the full bootstrap and deploy flow.

## Directory Structure

| Directory | Purpose |
|---|---|
| `rules/` | Binding repository constraints |
| `specs/` | Intended system behavior |
| `plans/` | Execution and migration plans |
| `mockups/` | Static prototypes and interactive policy/playground mockups |
| `tests/` | Automated validation |
| `src/` | Application code |
| `functions/` | Backend handlers |
| `scripts/` | Build, CI, and automation tooling |
| `docs/` | Architecture and design documentation |
| `dist/` | Generated build artifacts (do not edit manually) |
