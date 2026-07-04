# Bootstrap Wizard Runbook

Operator-facing reference for `scripts/bootstrap-new-repo.sh`. Goal: **an operator can run a fresh bootstrap without reading the source.**

The wizard is the canonical path for spinning up a brand-new repo from the Mergepath template. It replaces a 30-step manual checklist with a single invocation, and is the implementation of issue #156 (sub-issues A through E).

## When to run

Use the wizard when:

- You're creating a brand-new repo that should inherit Mergepath's governance posture (review policy, label set, reviewer collaborator set, CodeRabbit / Codex App posture, Project v2 board, Phase 0/1 scaffolding).
- The repo lives under `nathanjohnpayne` (or another owner you control) and does NOT already exist as a remote.

Do NOT use the wizard for:

- Existing repos — the wizard refuses to overwrite a populated target dir AND refuses to bootstrap over a pre-existing remote (preflight rejects both with `exit 2`).
- Forks — Mergepath's review policy assumes single-owner; a fork's review topology is different.

## Quick start

```bash
# From mergepath's worktree root, on main, clean.
eval "$(scripts/op-preflight.sh --agent claude --mode all)"   # cache PATs
scripts/bootstrap-new-repo.sh my-new-repo \
  --description "A short one-line description." \
  --visibility private \
  --firebase none \
  --codex-app n \
  --project new
```

The wizard prompts for any input you didn't pass via flag, confirms, then runs four stages: `template-mirror` → `github-infra` → `firebase-and-codereview` → `board-and-summary`. The final stage emits an end-of-run summary block (also appended to `~/GitHub/my-new-repo/.bootstrap-log`) with DONE / SKIPPED / WARNINGS / NEXT STEPS sections.

## Flags

| Flag | Argument | Default | Notes |
|---|---|---|---|
| (positional) | `<new-repo-name>` | (required) | Exactly one positional. |
| `--description` | `"..."` | (prompt) | Short one-line repo description. |
| `--visibility` | `public` \| `private` | (prompt, default `private`) | Maps to `gh repo create --public/--private`. |
| `--firebase` | `dev` \| `dev+prod` \| `none` | (prompt, default `none`) | Selects the Firebase scope for stage D. |
| `--reviewers` | `agent1,agent2,...` | `claude,cursor,codex` | Each agent resolves to `nathanpayne-<agent>`. |
| `--codex-app` | `y` \| `n` | (prompt, default `n`) | Print the Codex App install URL at the end of stage D. |
| `--project` | `new` \| `<N>` | (prompt, default `new`) | `new` creates a fresh Project v2 board; `<N>` attaches to existing project number. |
| `--skip-firebase` | (none) | off | Alias for `--firebase none`; skips stage D's Firebase substeps. |
| `--skip-board` | (none) | off | Skips stage E's Project v2 board sub-step. **The rest of stage E still runs** — scaffolds + summary are too valuable to gate on whether you wanted a board. |
| `--dry-run` | (none) | off | Print what would happen; zero side effects on disk or via gh/git/op. |
| `--resume` | `[<stage>]` | off | Resume a partially-completed run. With an explicit stage name, skip up to and including `<stage>`. Without, read the last completed stage from `$TARGET_DIR/.bootstrap-state`. |
| `--target-dir` | `<path>` | `$HOME/GitHub/<name>` | Override the new repo's local working tree. |
| `--help`, `-h` | | | Show flag summary. |
| `--version` | | | Print version info. |

## Prompts

When you don't pass a flag, the wizard prompts interactively. Each prompt is single-line, default-on-empty. The prompts run in this order:

1. **Description** — free-form one-line string.
2. **Visibility** — `public` or `private` (default `private`).
3. **Firebase scope** — `dev` / `dev+prod` / `none` (default `none`).
4. **Codex App install URL printout** — `y` / `N`.
5. **Project v2 board** — `new` / `<N>` (default `new`).

After prompts, the wizard prints a "collected inputs" block and asks `Proceed? [y/N]`. Skip the confirm prompt with `BOOTSTRAP_AUTO_CONFIRM=1`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All in-scope stages completed (or all skipped per `--resume`). |
| `1` | Bad arguments / unknown flag / required arg missing. |
| `2` | Preflight failed — missing dependency, dirty target dir, existing remote, mergepath not on main. |
| `3` | Mid-run stage failure. State file at `$TARGET_DIR/.bootstrap-state` records progress; re-run with `--resume`. |
| `4` | User aborted at a confirmation prompt. |

## Stages

### Stage A: scaffold (#203 / sub-A)

The wizard itself — argument parsing, preflight, prompts, dispatch, resume. Not a stage that runs side effects; it's the harness.

### Stage B: template-mirror (#204 / sub-B)

Implementation: `scripts/bootstrap/template-mirror.sh`.

1. `rsync` the mergepath worktree into the target dir, honoring the exclude list (mergepath-only files, packaging dirs, screenshots, etc.).
2. Remove post-rsync orphans the exclude list can't catch (e.g., `tests/test_mergepath_playground.sh`).
3. Drop mergepath-specific entries from the new repo's `.repo-template.yml` (the `mergepath_playground` spec_test_map key + the `extra_top_level_dirs` guard).
4. Apply name substitutions across the documented 6 name-bearing files (via `scripts/bootstrap/substitute.sh`).
5. Initialize the new repo's git history with a single `"Initial commit (bootstrapped from mergepath)"` commit.
6. Open a PR on Mergepath itself to add the new repo to the cross-repo loop lists in `DEPLOYMENT.md` and `REVIEW_POLICY.md` (gated on anchor presence — if the anchors aren't there, the step warns and skips).

**Failure recovery.** Each step captures its rc and short-circuits. On failure, the state file does NOT carry a `template-mirror` entry; re-run with `--resume` to retry. The cross-repo loop step has a "return to main on failure" recovery so a half-applied loop change doesn't strand mergepath's worktree on the throwaway branch.

### Stage C: github-infra (#205 / sub-C)

Implementation: `scripts/bootstrap/github-infra.sh`.

1. `gh repo create --source=. --push` against the target dir — creates the remote and pushes the bootstrap commit. Legitimate push to main on a greenfield remote (no `main` to protect yet).
2. Seed the 12 canonical labels (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`, `human-action`, `decision-needed`, `agent-action`, `phase-0` through `phase-4`).
3. Invite reviewer-identity collaborators (`nathanpayne-claude`, `-cursor`, `-codex` per `--reviewers`). Each invite is async; the wizard pauses for the human to accept each in the agent account's GitHub session.
4. Provision the `REVIEWER_ASSIGNMENT_TOKEN` repo secret. Path order: inline (`BOOTSTRAP_REVIEWER_PAT_VALUE` env, tests only) → 1Password item → interactive prompt for a fine-grained PAT.
5. Prompt for and provision optional LLM secrets (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) with skip option.

The wizard does not provision `AUTHOR_MERGE_TOKEN` by default, but `dependabot-auto-merge.yml` **requires it** as of nathanjohnpayne/mergepath#426: the Dependabot auto-merge workflow uses `AUTHOR_MERGE_TOKEN` for the `gh pr merge` step (so the merge is recorded under `author_identity`) and hard-fails if it is unset or resolves to anything other than `author_identity`. Provision it on any repo where Dependabot auto-merge is enabled. The same secret independently gates non-Dependabot auto-merge, which otherwise stays disabled with PRs merged manually as `nathanjohnpayne`. In both cases the workflow verifies the token resolves to the configured `author_identity` before calling `gh pr merge`.

For runtime application secrets in newly bootstrapped repos, do not add Secure Note / `notesPlain` bootstrap entries. The shared model is: use Environments and `op run` for runtime variable sets, use the 1Password MCP Server only for attended Codex Environment workflows, use the 1Password local `.env` validation hook for supported non-Codex agents that read mounted Environment files, and use `.env.tpl` + `op inject` only when the repo truly needs a generated config file on disk. Adoption decisions for these adapters belong to the 1Password audit ADR workstream; this runbook records the current compatibility guidance.

All write-path `gh` calls run under the author identity (`nathanjohnpayne`) through token-verifying helpers. Stage B/C/E live writes use `scripts/gh-as-author.sh` per command, so the machine-global gh account selection is not read or changed for attribution.

**Failure recovery.** Hard failures on `gh repo create` are fatal (stage returns non-zero, state file omits the entry). Secret-provision failures are warned-but-not-fatal: workflows will fail loudly on the first PR if the token isn't set, surfacing the gap.

### Stage D: firebase-and-codereview (#206 / sub-D)

Implementation: `scripts/bootstrap/firebase-and-codereview.sh`.

When `--firebase` is `dev` or `dev+prod`:

1. Create the Firebase project(s) per `DEPLOYMENT.md`.
2. Run `op-firebase-setup` to mint per-project deployer service-account keys and store them in 1Password.
3. Wire the project IDs into the new repo's `.firebaserc` and `.github/workflows/deploy-*.yml`.

When `--firebase` is `none` (the default), the Firebase steps are all skipped with a single log line.

CodeRabbit + Codex App posture is configured regardless:

- Print the CodeRabbit App install URL (operator must accept on github.com per agent identity).
- If `--codex-app y`: print the Codex App install URL + environment setup steps (chatgpt.com/codex/cloud/settings/environments — manual step the wizard cannot fully automate).
- Wire `.github/review-policy.yml`'s `coderabbit` + `codex` blocks to match the operator's choices.
- The template's `.coderabbit.yml` ships with `reviews.profile: chill` by default. Per CodeRabbit's docs, the 🧹 Nitpick category is "only in Assertive mode" — `chill` suppresses nitpicks at the source while preserving substantive findings (Potential issue / ⚠️ / Refactor / Security). The 2026-05-13 sweep (#234) surfaced 56 unresolved nit threads across 9 repos, none substantive; #237 commits to the quieter posture at the template level. Override per-repo by setting `reviews.profile: assertive` locally if a specific repo wants the polish pass. The override sticks because the wizard's template-mirror only seeds `.coderabbit.yml` on first bootstrap, not on every sync wave.

**Failure recovery.** Firebase project-creation failures are fatal (the wizard refuses to record completion). CodeRabbit/Codex URL printouts can't fail in a meaningful way.

### Stage E: board-and-summary (#207 / sub-E)

Implementation: `scripts/bootstrap/board-and-summary.sh`.

1. **Project v2 board.** Skipped when `--skip-board` is set OR when `BOOTSTRAP_INPUT_PROJECT=skip` (env-var control, used by tests):
   - `--project new`: `gh project create --owner nathanjohnpayne --title <repo> --format json`, parse `.number`, then `gh project field-create` for the Status field (`SINGLE_SELECT` with Backlog / Ready / In progress / In review / Done), then `gh project edit --readme "..."`.
   - `--project <N>`: reuse existing project; skip create + field- create + readme writes.
2. **Empty implementation-spec / plan scaffolds.** Always run (even when `--skip-board` skips sub-step 1):
   - `specs/<repo>.md` — placeholder with the wizard's "deliberate-not-in-scope" note for repo-local behavior specs.
   - `plans/<repo>-sprint-0.md` — same shape.
   - `scripts/gh-projects/examples/<repo>/create-issues.sh` — minimal issue-seeding skeleton with `<repo>` placeholders. Executable.
3. **Final summary block.** Always run. Printed to stdout AND appended to `$TARGET_DIR/.bootstrap-log`. Sections:
   - `REPO` / `PROJECT` / `LOCAL DIR` header.
   - `DONE` — stages found in the state file at summary time.
   - `SKIPPED` — stages NOT in the state file (or whose sub-steps were explicitly skipped, e.g., Firebase under `--skip-firebase`).
   - `WARNINGS` — things the wizard couldn't automate (e.g., `.env.local` from Firebase web console; collaborator invite acceptance).
   - `CROSS-REPO LOOP UPDATE` — pointer to the Mergepath PR opened in stage B (or a manual-action note if anchors were absent).
   - `NEXT STEPS (human-action)` — the explicit checklist of things the operator owns: accept invites, write the canonical PRD in `nathanjohnpayne/docs/projects/<repo>/prds/`, fill the repo-local implementation spec, populate issues, set spend caps, drive Sprint 0.

The project-board calls are `gh` write paths and run under the same token-verified author helper as stage C. The scaffold writes are direct shell redirects (no gh involved) and don't need the wrapper.

**Failure recovery.** Project-board failures are fatal (stage returns non-zero). Scaffold-write failures are fatal. Summary emission failures are fatal but rare — the summary is in-memory string construction with a single tmpfile dump.

## Resume mechanism

The wizard records each completed stage's name to `$TARGET_DIR/.bootstrap-state` (append-only, one stage per line). On re-run:

- `--resume` (no argument) reads the LAST line of `.bootstrap-state` and skips everything up to and including that stage.
- `--resume <stage>` overrides the state-file lookup with an explicit stage name.

An unknown resume stage (typo or stale state file from an older wizard version) exits 1 with a diagnostic pointing at the state file (`Codex P1 round 1 on PR #232` introduced this guard).

The state file is the source of truth for the summary's DONE list — edit it manually if you're recovering from a botched state.

## Failure modes

Per stage, the most common failures and their recovery paths:

### Preflight

- **Missing dependency** (`gh`, `op`, `git`, `yq`, `rsync`, or `firebase`/`gcloud` when Firebase is enabled): exit 2 with `missing required dependency: <tool>`. Install the tool and re-run.
- **Dirty target dir**: exit 2 with `target dir X is not empty`. Wipe the dir or pick a different name; the wizard refuses to overwrite.
- **Existing remote**: exit 2 with `remote already exists`. The repo's already there; the wizard refuses to bootstrap over it.
- **Mergepath not on main / dirty**: exit 2 with a guidance line. Switch mergepath to main and commit/stash before bootstrapping.

### Stage B (template-mirror)

- **rsync failure**: usually disk full or perms. Fix root cause, re-run.
- **yq not on PATH or kislyuk/yq detected**: exit 2 with a targeted diagnostic. Install `mikefarah/yq` via `brew install yq` (Codex P1 on PR #233 round 3 made this fail-closed).
- **Cross-repo loop step refuses dirty mergepath**: stage B re-verifies the mergepath preflight check. Stash/commit and re-run.

### Stage C (github-infra)

- **`gh repo create` fails**: usually a name collision or auth scope issue. Stage fails, state file omits the entry. Re-run with `--resume template-mirror` after fixing.
- **Label / invite failures**: per-label / per-invite are warn-not- fatal; the loop continues. The summary surfaces the gaps.
- **Secret-set failures**: warn-not-fatal. Workflows will fail loudly on the first PR; set the secret manually then.

### Stage D (firebase-and-codereview)

- **Firebase project creation fails**: hard fail. Usually a quota / billing / org-policy issue. Resolve in the Firebase console, re-run with `--resume github-infra`.
- **CodeRabbit / Codex App install URL printouts**: cannot fail; pure log output.

### Stage E (board-and-summary)

- **`gh project create` fails**: hard fail. Often auth-scope (the PAT needs Projects: Read+Write). Re-run with `--resume firebase-and- codereview` after granting scope.
- **`gh project field-create` fails on a board that already has a Status field**: warn-not-fatal. Configure the field manually if needed.
- **Scaffold-write failures**: rare — disk perms. Fix, re-run.

## Human-action items the wizard cannot automate

These items require human attention AFTER the wizard completes. The summary block enumerates them; this section is the canonical reference:

1. **Accept reviewer collaborator invites.** Each invited agent identity (`nathanpayne-claude`, `-cursor`, `-codex`) must sign into the new repo's invitations page and accept. Wizard invokes the invite but cannot accept it.
2. **Populate `.env.local` from Firebase web console.** When Firebase is enabled, the deployer SA key handles deploys but the web app config (`firebaseConfig`) requires manual copy-paste from console.firebase.google.com.
3. **Install the Codex App.** The wizard prints the install URL; the human must accept on github.com/apps/codex AND configure a Codex environment at chatgpt.com/codex/cloud/settings/environments. "Code Review enabled" is not sufficient — both pieces are required for review-readiness.
4. **Install the CodeRabbit App.** Same shape: wizard prints the URL, human accepts.
5. **Write the PRD and implementation spec.** The canonical PRD belongs in `nathanjohnpayne/docs/projects/<repo>/prds/`; the wizard-created `specs/<repo>.md` placeholder is the repo-local implementation spec. `scripts/project-doc-sync.sh` is responsible for generated PRD/spec mirrors once the project is added to `.mergepath-project-docs.yml`.
6. **Populate Phase 0 / Phase 1 issues.** The wizard creates the `scripts/gh-projects/examples/<repo>/create-issues.sh` skeleton. The human fills it in and runs it.
7. **Set provider-level spend caps.** Before pasting LLM API keys (Anthropic, OpenAI), the human sets account-level spend caps at `platform.openai.com/account/limits` and `console.anthropic.com/settings/limits`.
8. **Drive Sprint 0 PR #1.** The first end-to-end PR through the review flow (CodeRabbit advisory + reviewer identity + Phase 4 external review) validates the bootstrap.

## Environment variables

Most operators don't need these. Documented for the test fixtures and edge-case runs:

| Var | Effect |
|---|---|
| `BOOTSTRAP_REPO_OWNER` | GitHub owner for new repos. Default: `nathanjohnpayne`. |
| `BOOTSTRAP_LIB_DIR` | Override the per-stage module directory. |
| `BOOTSTRAP_MERGEPATH_ROOT` | Override the source root for stage B's rsync. Used by fixture tests. |
| `BOOTSTRAP_SKIP_TOOL_CHECK=1` | Bypass preflight's dependency check (tests). |
| `BOOTSTRAP_SKIP_MERGEPATH_GUARD=1` | Bypass the "mergepath on main and clean" preflight (tests). |
| `BOOTSTRAP_AUTO_CONFIRM=1` | Skip the post-prompt `Proceed? [y/N]` confirmation. |
| `BOOTSTRAP_AUTO_PROMPT=skip` | Skip all interactive prompts. All inputs must come from flags. |
| `BOOTSTRAP_SKIP_INVITE_PAUSE=1` | Skip the "press enter once invites are accepted" pause in stage C. |
| `BOOTSTRAP_SKIP_SECRETS=1` | Skip stage C's secret-provisioning substeps. |
| `BOOTSTRAP_SKIP_BOARD=1` | Skip stage E's Project v2 board sub-step (summary + scaffolds still run). |
| `BOOTSTRAP_SKIP_AUTHOR_TOKEN=1` | Tests only: skip the author-token wrapper and run the `gh` shim directly. |
| `BOOTSTRAP_SKIP_STAGES` | Comma-separated stage names to skip entirely (no dispatch, no record). |
| `BOOTSTRAP_SKIP_CROSS_REPO_LOOP=1` | Skip stage B's "open a PR on mergepath" step. |
| `BOOTSTRAP_AUTHOR_IDENTITY` | Override the target identity for author-token verification. Default: `nathanjohnpayne`. |
| `BOOTSTRAP_AUTHOR_NAME` / `BOOTSTRAP_AUTHOR_EMAIL` | Override the git identity for the initial commit. |
| `BOOTSTRAP_REVIEWER_PAT_VALUE` | Inline `REVIEWER_ASSIGNMENT_TOKEN` value (tests). |
| `BOOTSTRAP_REVIEWER_PAT_OP_REF` | Override the 1Password reference for the reviewer PAT. |
| `BOOTSTRAP_INPUT_*` | Pre-set any input via env (bypasses both flag and prompt). |

## Files produced

By the end of a successful run, the target dir contains:

- The full mirrored mergepath template (minus the exclude list).
- `.git/` initialized with one commit.
- `.bootstrap-log` — full transcript of every side effect + the end-of-run summary block.
- `.bootstrap-state` — append-only list of completed stages.
- `specs/<repo>.md` — placeholder implementation spec.
- `plans/<repo>-sprint-0.md` — placeholder Sprint 0 plan.
- `scripts/gh-projects/examples/<repo>/create-issues.sh` — placeholder issue-seeding skeleton (executable).

And on GitHub:

- Remote repo `nathanjohnpayne/<repo>` with the bootstrap commit pushed to main.
- 12 canonical labels.
- Reviewer-identity collaborators invited.
- `REVIEWER_ASSIGNMENT_TOKEN` repo secret set.
- `AUTHOR_MERGE_TOKEN` unset by default (the wizard does not provision it). Required wherever Dependabot auto-merge is enabled (#426) — `dependabot-auto-merge.yml` hard-fails without it — and also gates non-Dependabot auto-merge, which stays disabled until a human provisions the author-owned token.
- (When Firebase is enabled) per-project deployer SA keys minted + workflows wired.
- Project v2 board (#N) with Status single-select field configured.

And on Mergepath:

- A PR adding `<repo>` to the cross-repo loop lists in `DEPLOYMENT.md` and `REVIEW_POLICY.md` (when the anchors are present).

## See also

- **#156** — parent design document for the wizard.
- **#203 / sub-A** — wizard scaffold (this doc's harness).
- **#204 / sub-B** — template-mirror stage.
- **#205 / sub-C** — github-infra stage.
- **#206 / sub-D** — firebase-and-codereview stage.
- **#207 / sub-E** — board-and-summary stage + this runbook.
- `AGENTS.md` § Code Review Policy — the review topology the wizard configures.
- `DEPLOYMENT.md` — the deploy + credential setup the wizard mirrors.
- `REVIEW_POLICY.md` — the review-policy YAML the wizard wires into `.github/review-policy.yml`.
