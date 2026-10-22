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

## Firebase and Google Cloud Tooling

The template retains the approved 1Password-backed Firebase credential-custody model: each project's deployer service-account key belongs in the Firebase vault, with shared 1Password ADC retained as a legacy resolver fallback. Do not revert to deploy keys on disk or routine `firebase login` guidance without explicit human approval. Existing `op-firebase-setup` and `op-firebase-deploy` helpers describe legacy account setup and credential resolution; do not run them to enable production deployment while the production block remains.

Production deployment is blocked until separately reviewed tooling ensures repository build code and dependencies have neither deploy credentials nor author/reviewer PATs and cannot reach credential-manager files or preflight caches; publishes an immutable artifact with a digest and attestation bound to the intended repository and full source revision; and has trusted post-build tooling verify that binding and artifact integrity before acquiring deploy credentials, then deploy the verified artifact without rebuilding or executing the candidate checkout and inject each credential only into its consuming subprocess. The current helper scripts do not provide these guarantees. Do not use deploy/all preflight or legacy helper commands to bypass the block; see [DEPLOYMENT.md](DEPLOYMENT.md) and [Build and deploy isolation](docs/agents/shared-operating-rules.md#build-and-deploy-isolation).

The `scripts/gcloud/gcloud` wrapper remains available for ordinary non-deployment `gcloud` commands. Routine replacement of a Firebase deploy key remains incomplete until separately reviewed, non-deploying validation proves the replacement usable; suspected-compromise containment is a separate owner-led incident decision. See [key rotation guidance](DEPLOYMENT.md#rotating-a-firebase-deploy-sa-key).

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
