# Mergepath

**Reference implementation of the AI Agent Tooling Standard.**

The goal is to allow multiple AI coding agents and development tools to operate consistently without configuration drift. See [`BRAND.md`](BRAND.md) for the umbrella vocabulary (Playground, Cockpit, Tiebreaker, Checks) and naming history.

## For AI Agents

Read these files in order before taking any action:

1. `AGENTS.md` — behavioral instructions and operating rules
2. `rules/repo_rules.md` — binding structural constraints
3. Relevant `specs/` files — intended behavior
4. `.ai_context.md` — supplemental system context

## Code Review Policy

Every change in this repository goes through the policy in `REVIEW_POLICY.md`, including a self-peer review by the authoring agent's reviewer identity and, for changes that cross the threshold or touch protected paths, automated external review via the OpenAI Codex GitHub app (Phase 4a) or a manual CLI fallback (Phase 4b).

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
| `scripts/cockpit.sh` | Launches the Mergepath Cockpit, a local browser dashboard over the fleet's PRs, CI and agent runs |
| `scripts/worktree-cleanup.sh` | Audits stale git worktrees and, with `--apply`, removes the safe ones |
| `scripts/install-worktree-cleanup-agent.sh` | Installs the daily launchd job that runs the worktree cleanup unattended |
| `.mergepath-sync.yml` | Propagation manifest for synced canonical, kit, and templated surfaces |
| `.github/ISSUE_TEMPLATE/` | Synced issue-template kit; consumers may add product-specific templates |
| `.github/pull_request_template.md` | Synced canonical pull-request template |
| `ai_agent_tooling_standard.md` | Full repository standard (reference) |

## Local Tools: Cockpit and Worktree Cleanup

These run on your own machine and never in CI.

**Mergepath Cockpit** is a local browser dashboard. Warm the credential cache, then launch it:

```bash
eval "$(scripts/op-preflight.sh --agent codex --mode review)"
scripts/cockpit.sh
```

Agent history reads at most 64 checkouts: the hub and any configured roots first, then the newest worktrees. When there are more, Cockpit says so on startup (`Agent history reads 64 of N checkouts…`) and the history panel shows coverage as incomplete. If launch fails, the message names the step that failed, for example `Cockpit cannot start: failed while discovering checkouts and worktrees.` Behavior is specified in `specs/cockpit_foundation.md` and `specs/cockpit_agents.md`.

**Worktree cleanup** removes worktrees left behind by agent sessions. A dry run lists what it would do; `--apply` removes only safe candidates, meaning the upstream branch is gone or the PR is closed or merged, and nothing in the working tree would be lost (uncommitted, untracked or gitignored files such as `.env`):

```bash
scripts/worktree-cleanup.sh                        # dry run: report only
scripts/worktree-cleanup.sh --apply --min-age 24h  # remove safe candidates untouched for a day
```

Locked worktrees and orphan directories are left alone unless you pass `--force-locked` or `--orphan-clean`. A worktree git refuses to remove is reported under `failed:` and the run carries on. Committed work survives: removing a worktree keeps its branch, and a detached worktree is removed only when a local branch, tag or remote contains its commit or GitHub still holds it as the PR's head. A detached worktree holding a commit nothing else has is kept, with the command to save it.

**Daily cleanup.** To run that cleanup automatically, install the per-user launchd job from a clone whose main checkout is on an up-to-date `main`:

```bash
scripts/install-worktree-cleanup-agent.sh          # install; runs daily at 04:17
scripts/install-worktree-cleanup-agent.sh --check  # installed, loaded and current?
scripts/install-worktree-cleanup-agent.sh --run-now
scripts/install-worktree-cleanup-agent.sh --uninstall
```

The job runs the main checkout's `scripts/worktree-cleanup.sh --apply --min-age 24h` and appends to `~/.cache/mergepath/worktree-cleanup.log`. It never passes `--force-locked` or `--orphan-clean`. Details are in `docs/agents/operating-rules.md` and `specs/worktree_cleanup_audit.md`.

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
