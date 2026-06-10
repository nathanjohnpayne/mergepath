# Mergepath

**Reference implementation of the AI Agent Tooling Standard.**

The goal is to allow multiple AI coding agents and development tools to operate
consistently without configuration drift. See [`BRAND.md`](BRAND.md) for
the umbrella vocabulary (Playground, Cockpit, Tiebreaker, Checks) and
naming history.

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
| `BRAND.md` | Mergepath umbrella vocabulary (surfaces, reserved names, naming history) |
| `mergepath/playground/index.html` | Mergepath Playground — tune the review policy and replay recent PRs against the draft |
| `scripts/policy-sim.sh` | Bakes real `gh` PR data into a temp copy of the Mergepath Playground for local replay |
| `.mergepath-sync.yml` | Propagation manifest for synced canonical, kit, and templated surfaces |
| `.github/ISSUE_TEMPLATE/` | Synced issue-template kit; consumers may add product-specific templates |
| `.github/pull_request_template.md` | Synced canonical pull-request template |
| `ai_agent_tooling_standard.md` | Full repository standard (reference) |

## Firebase Auth Template

This template includes the canonical Google Cloud and Firebase helper scripts for this account:

- `scripts/gcloud/gcloud` installs a local wrapper so ordinary `gcloud` commands can use 1Password-backed or explicit source credentials without a routine interactive `gcloud auth login`, while attributing quota to the resolved target project from explicit flags, the repo's `.firebaserc`, or the active `gcloud` config.
- `scripts/firebase/op-firebase-setup` creates a per-project `firebase-deployer@{project-id}.iam.gserviceaccount.com`, grants deploy roles, and configures impersonation.
- `scripts/firebase/op-firebase-deploy` resolves a source credential per the canonical precedence (project Firebase-vault SA key first, with shared 1Password ADC and impersonation as fallbacks) and runs `firebase deploy` with the target project stamped in as the quota project.

The canonical source-credential precedence is documented in `DEPLOYMENT.md` § [Deploy credential precedence (canonical)](DEPLOYMENT.md#deploy-credential-precedence-canonical). The default day-to-day credential — interactive and CI — is the per-project Firebase-vault SA key (`op://Firebase/{project-id} — Firebase Deployer SA Key`), with the shared 1Password ADC as a fallback and an explicit `GOOGLE_APPLICATION_CREDENTIALS` as the highest-priority override.

This 1Password-first deploy-auth model is intentional. Do not revert template-derived repos to deploy-key-on-disk or routine `firebase login`-based guidance unless a human explicitly requests that change.

See `DEPLOYMENT.md` for the full bootstrap and deploy flow.

## Directory Structure

| Directory | Purpose |
|---|---|
| `rules/` | Binding repository constraints |
| `specs/` | Intended system behavior |
| `plans/` | Execution and migration plans |
| `mergepath/` | Mergepath Playground and reserved slots for future Mergepath surfaces (see `BRAND.md`) |
| `tests/` | Automated validation |
| `src/` | Application code |
| `functions/` | Backend handlers |
| `scripts/` | Build, CI, and automation tooling |
| `docs/` | Architecture and design documentation |
| `dist/` | Generated build artifacts (do not edit manually) |
