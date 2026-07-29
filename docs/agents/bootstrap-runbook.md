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

1. `rsync` the mergepath worktree into the target dir, honoring the exclude list (mergepath-only files, packaging dirs, screenshots, the hub-only machinery docs, and the pure-identity `BRAND.md` / `docs/agents/repository-overview.md` — see step 5).
2. Remove post-rsync orphans the exclude list can't catch (e.g., `tests/test_mergepath_playground.sh`).
3. Drop mergepath-specific entries from the new repo's `.repo-template.yml` (the `mergepath_playground` spec_test_map key + the `extra_top_level_dirs` guard).
4. Apply name substitutions across the documented name-bearing files (via `scripts/bootstrap/substitute.sh`).
5. **Scaffold neutral consumer identity docs (#744/#747).** A lexical `mergepath → <repo>` swap leaves mergepath's self-referential hub identity intact and false, so `BRAND.md` and `docs/agents/repository-overview.md` (100% identity) are excluded from the mirror and replaced with honest "downstream consumer" stubs; the three hub-only **machinery** docs (`docs/agents/{bootstrap-runbook,propagation-ordering,templated-propagation}.md`) are excluded (they describe processes a consumer doesn't run); and the `AGENTS.md` "Repository Layout" section documenting the mergepath-only `packaging/` dir is scrubbed. `ai_agent_tooling_standard.md` is **kept** — it's the methodology-neutral Standard the consumer follows (it correctly names mergepath as the reference implementation and isn't name-substituted, so it stays true), and `README.md` / `.ai_context.md` link to it. The mixed doc `.ai_context.md` keeps its shared content — its one false line is fixed at the mergepath source so it flows through substitution honestly. #747 extends the same pass to the two remaining mixed docs: the substituted `README.md` has its "Reference implementation" tagline replaced with honest downstream framing, the BRAND umbrella-vocabulary sentences rewritten to point at the stub, and the Key-Files/Directory rows for consumer-excluded surfaces (the playground, `scripts/policy-sim.sh`, the sync manifest) dropped; and the verbatim-copied `REVIEW_POLICY.md` has its § Phase 3.5 wave-audit paragraph replaced with a hub-side pointer plus a consumer note framing the hub-script references (`sync-to-downstream.sh`, the manifest, `wave-audit.sh`) as living on mergepath — while distinguishing the synced consumer copy of `audit-propagation-lane.sh` and qualifying fan-out receipt with "once enrolled". Both scrubs fail closed if a hub marker survives in a form the transform no longer matches. Canonical behavior spec: `specs/bootstrap_consumer_identity.md`.
6. Reset the opt-in policy defaults the hub flipped for itself — `phase_4b_automation.enabled` is set back to `false` in the target's `.github/review-policy.yml` so a new repo opts into local reviewer-CLI automation explicitly, after validating plan-logins on its own machine (#628).
7. Initialize the new repo's git history with a single `"Initial commit (bootstrapped from mergepath)"` commit.
8. Open a PR on Mergepath itself to add the new repo to the cross-repo loop lists in `DEPLOYMENT.md` and `REVIEW_POLICY.md` (gated on anchor presence — if the anchors aren't there, the step warns and skips).

> **This stage does NOT enroll the repo as a `.mergepath-sync.yml` consumer.** The one-time template rsync (step 1) and ongoing sync-consumer enrollment are separate steps — a repo that gets only the rsync + loop-doc registration receives none of mergepath's post-bootstrap propagation and never appears in the weekly `propagation-drift` sweep. Enrollment is a human NEXT STEP (see below), not an automated part of this stage, because it needs a `facts:` block verified against the repo's own `package.json` and a canary-first first sync. This gap is what stranded `gaycruisebingo` (mergepath#741).

**Failure recovery.** Each step captures its rc and short-circuits. On failure, the state file does NOT carry a `template-mirror` entry; re-run with `--resume` to retry. The cross-repo loop step has a "return to main on failure" recovery so a half-applied loop change doesn't strand mergepath's worktree on the throwaway branch.

### Stage C: github-infra (#205 / sub-C)

Implementation: `scripts/bootstrap/github-infra.sh`.

1. `gh repo create --source=.` against the target dir, then a separate `git push -u origin HEAD` — creates the remote, then pushes the bootstrap commit. Legitimate push to main on a greenfield remote (no `main` to protect yet). The two are deliberately separate commands: bundled as `gh repo create ... --push` they shared a single exit code, so a push that failed on a transient network or credential error — with the repository already created — reported failure before any checkpoint was written, leaving a remote that nothing recorded (#790). Split, the create's success is checkpointed immediately and the push is an ordinary repeatable step a resume retries.
2. Seed the 12 canonical labels (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`, `human-action`, `decision-needed`, `agent-action`, `phase-0` through `phase-4`).
3. Invite reviewer-identity collaborators (`nathanpayne-claude`, `-cursor`, `-codex` per `--reviewers`). Each invite is async; the wizard pauses for the human to accept each in the agent account's GitHub session.
4. Provision the `REVIEWER_ASSIGNMENT_TOKEN` repo secret. Path order: inline (`BOOTSTRAP_REVIEWER_PAT_VALUE` env, tests only) → session-cached `$OP_PREFLIGHT_REVIEWER_PAT` → 1Password item-UUID reference (`op://Private/pvbq24vl2h6gl7yjclxy2hbote/token`; never a title path, per #734) → interactive prompt for a fine-grained PAT.
5. Prompt for and provision optional LLM secrets (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) with skip option.

The wizard does not provision `AUTHOR_MERGE_TOKEN` by default, but `dependabot-auto-merge.yml` **requires it** as of nathanjohnpayne/mergepath#426: the Dependabot auto-merge workflow uses `AUTHOR_MERGE_TOKEN` for the `gh pr merge` step (so the merge is recorded under `author_identity`) and hard-fails if it is unset or resolves to anything other than `author_identity`. Provision it on any repo where Dependabot auto-merge is enabled. The same secret independently gates non-Dependabot auto-merge, which otherwise stays disabled with PRs merged manually as `nathanjohnpayne`. In both cases the workflow verifies the token resolves to the configured `author_identity` before calling `gh pr merge`.

For runtime application secrets in newly bootstrapped repos, do not add Secure Note / `notesPlain` bootstrap entries. The shared model is: use Environments and `op run` for runtime variable sets, use the 1Password MCP Server only for attended Codex Environment workflows, use the 1Password local `.env` validation hook for supported non-Codex agents that read mounted Environment files, and use `.env.tpl` + `op inject` only when the repo truly needs a generated config file on disk. Adoption decisions for these adapters belong to the 1Password audit ADR workstream; this runbook records the current compatibility guidance.

All write-path `gh` calls run under the author identity (`nathanjohnpayne`) through token-verifying helpers. Stage B/C/E live writes use `scripts/gh-as-author.sh` per command, so the machine-global gh account selection is not read or changed for attribution.

**Failure recovery.** Hard failures on `gh repo create` are fatal (stage returns non-zero, state file omits the entry). Secret-provision failures are recorded-but-not-fatal by default: workflows will fail loudly on the first PR if the token isn't set, and the miss is persisted to `<target>/.bootstrap-state.warnings` and re-surfaced in the end-of-run summary's `!! RECORDED FAILURES` block so it can't ship unnoticed (#734). Set `BOOTSTRAP_STRICT_SECRETS=1` to upgrade the miss to a fatal stage failure instead — the failure is still recorded to the warnings sidecar before the stage aborts, and it names the *specific* cause (no PAT available with prompts skipped / human declined to provide one / `gh secret set` itself failed / the author write path failed before `gh secret set` ever ran / the run could not allocate a temp dir for the call's trace and capture files, so no write was attempted) with the stage-level "re-run with `--resume template-mirror`" consequence appended, not a generic "provisioning failed". Distinguishing those causes is the point of the sidecar, since all five share one warning key. A later successful `REVIEWER_ASSIGNMENT_TOKEN` retry does **not** delete that token-specific record: the sidecar is the run's audit trail, so the line is rewritten in place with a `RESOLVED:` marker (the literal prefix carries a trailing space), keeping the original failure message and appending what fixed it (#761). The summary then lists it under `ok RESOLVED` instead of `!! RECORDED FAILURES`. Unrelated recorded failures are untouched and remain visible as outstanding.

That `--resume template-mirror` remediation is load-bearing, and step 1 is what makes it possible. The stage records completion only after step 5, so an abort anywhere from the push onward leaves a created remote with no stage entry — and both the wizard's "target dir is empty" and "no existing remote" preflight checks then rejected the retry, while a retry that got past them would have called `gh repo create` on a name that already exists. Step 1 therefore records a `github-infra:remote-created:<owner>/<name>` checkpoint in `<target>/.bootstrap-state.checkpoints` as soon as the create succeeds — before the push, which is the first thing that can fail after it (#790). On a `--resume` run the checkpoint is what lets preflight accept the existing remote and lets step 1 skip the create; without it an existing remote still fails preflight closed, so `--resume` can never bootstrap over a repo this run did not create (#761). It gates the create and nothing else: the push runs on every entry, because it may well be what failed, and re-pushing a branch the remote already has is a no-op.

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
   - `WARNINGS` — things the wizard couldn't automate (e.g., `.env.local` from Firebase web console; collaborator invite acceptance), plus up to two sub-blocks rendered from `<target>/.bootstrap-state.warnings` (#734, #761). A `!! RECORDED FAILURES` sub-block lists every **outstanding** record (e.g., a missed `REVIEWER_ASSIGNMENT_TOKEN` provisioning), so a recorded miss can't ship unnoticed. An `ok RESOLVED` sub-block lists records a later attempt in the same bootstrap fixed — they still surface, because the operator wants to know a strict-mode abort happened, but they carry a "no action needed" heading rather than reading as work. Classification is a positive match on the full `@<key><TAB>RESOLVED:` + space line shape that `github-infra.sh` stamps — the key is part of the test, because only the resolver writes the marker and it always writes a keyed record, so an **unkeyed** line whose message merely starts with `RESOLVED:` is not a resolution record and stays an outstanding failure, as does any unrecognized line shape. A sidecar holding only resolved records prints no `!! RECORDED FAILURES` header at all.
   - `CROSS-REPO LOOP UPDATE` — pointer to the Mergepath PR opened in stage B (or a manual-action note if anchors were absent).
   - `NEXT STEPS (human-action)` — the explicit checklist of things the operator owns: accept invites, **enroll the repo as a `.mergepath-sync.yml` consumer** (so it receives ongoing propagation, not just the one-time rsync — mergepath#741), write the canonical PRD in `nathanjohnpayne/docs/projects/<repo>/prds/`, fill the repo-local implementation spec, populate issues, set spend caps, drive Sprint 0.

The project-board calls are `gh` write paths and run under the same token-verified author helper as stage C. The scaffold writes are direct shell redirects (no gh involved) and don't need the wrapper.

**Failure recovery.** Project-board failures are fatal (stage returns non-zero). Scaffold-write failures are fatal. Summary emission failures are fatal but rare — the summary is in-memory string construction with a single tmpfile dump.

## Resume mechanism

The wizard records each completed stage's name to `$TARGET_DIR/.bootstrap-state` (append-only, one stage per line). On re-run:

- `--resume` (no argument) reads the LAST line of `.bootstrap-state` and skips everything up to and including that stage.
- `--resume <stage>` overrides the state-file lookup with an explicit stage name. It may only **rewind**: the stage it names must appear in `.bootstrap-state`, so an explicit resume can re-run stages that already completed but can never skip past one that did not. Naming an unrecorded stage exits 1 with a diagnostic naming the last completed stage. To skip a stage you completed by hand, add it to `.bootstrap-state` or set `BOOTSTRAP_SKIP_STAGES=<stage>` — `--resume` is not a stage-skip flag (#790).

An unknown resume stage (typo or stale state file from an older wizard version) exits 1 with a diagnostic pointing at the state file (`Codex P1 round 1 on PR #232` introduced this guard). The rewind-only rule closes the same silent false-success — every stage treated as already completed, exit 0, no work done — for a stage name that happens to be spelled right.

On a stage failure the wizard prints the resume command itself, and it names the **last completed stage before the failure**, not the stage that failed: `--resume X` skips up to and including `X`, so printing the failed stage's own name told the operator to skip precisely the work that did not happen (#790). For a stage C abort that command is `--resume template-mirror`, the same one the stage's own recorded remediation names. When nothing completed before the failure there is nothing to resume past, and the wizard says to re-run without `--resume` instead.

The state file is the source of truth for the summary's DONE list — edit it manually if you're recovering from a botched state.

**Checkpoints.** A stage records completion only when it finishes, which is what makes `--resume` re-enter an aborted stage from the top. That is correct for a stage whose steps can all be repeated, and wrong for the one step that cannot: `gh repo create`. Stage C runs it first and records completion last, so any abort in between leaves an irreversible side effect the state file says nothing about. Such steps additionally record a checkpoint — one name per line — in `$TARGET_DIR/.bootstrap-state.checkpoints`, and the re-entry consults it and skips the step. Today the only checkpoint is `github-infra:remote-created:<owner>/<name>` (#761).

A checkpoint name carries the thing it records, not just the step: the remote checkpoint ends in the `owner/name` that was created, and both consumers match that exact line. The sidecar lives in the target dir, but the repository comes from the positional argument and `$BOOTSTRAP_REPO_OWNER` — and `--target-dir` lets a second run reuse the same tree under a different name. A step-only checkpoint would therefore relax both guards for *any* remote: `bootstrap-new-repo.sh other-repo --target-dir <same-dir> --resume template-mirror` would pass preflight against an unrelated existing `other-repo`, skip the create because "a" remote had been created, and then seed labels, invite reviewers and write `REVIEWER_ASSIGNMENT_TOKEN` into it. With the name bound, a resume that names a different repo gets no match, so preflight refuses it and — if preflight was suppressed — step 1 creates that repo's own remote instead of adopting one.

Checkpoints are deliberately a *separate* sidecar rather than extra state-file lines, because `--resume` with no argument reads the state file's LAST line: a checkpoint written there would be read back as a completed stage and rejected as an unknown resume stage. They are also never written under `--dry-run` — unlike the state file and the warnings sidecar, which record what the wizard *said*, a checkpoint records what it *did*, and a dry-run checkpoint would make a later live run skip a create that never happened. If you delete a remote by hand after an aborted run, delete `.bootstrap-state.checkpoints` too, or the resume will skip the create and every subsequent `gh` call will fail against the missing repo.

## Failure modes

Per stage, the most common failures and their recovery paths:

### Preflight

- **Missing dependency** (`gh`, `op`, `git`, `yq`, `rsync`, or `firebase`/`gcloud` when Firebase is enabled): exit 2 with `missing required dependency: <tool>`. Install the tool and re-run.
- **Dirty target dir**: exit 2 with `target dir X is not empty`. Wipe the dir or pick a different name; the wizard refuses to overwrite. Relaxed on a `--resume` run whose target already holds a `.bootstrap-state` file — a resume re-enters a tree the earlier stages populated on purpose. A populated dir with no state file is still refused, resume or not.
- **Existing remote**: exit 2 with `remote already exists`. The repo's already there; the wizard refuses to bootstrap over it. Relaxed on a `--resume` run only when `.bootstrap-state.checkpoints` records that this bootstrap created *that exact* `owner/name` itself; absent a matching checkpoint the check still fails closed (#761).
- **Mergepath not on main / dirty**: exit 2 with a guidance line. Switch mergepath to main and commit/stash before bootstrapping.

### Stage B (template-mirror)

- **rsync failure**: usually disk full or perms. Fix root cause, re-run.
- **yq not on PATH or kislyuk/yq detected**: exit 2 with a targeted diagnostic. Install `mikefarah/yq` via `brew install yq` (Codex P1 on PR #233 round 3 made this fail-closed).
- **Cross-repo loop step refuses dirty mergepath**: stage B re-verifies the mergepath preflight check. Stash/commit and re-run.

### Stage C (github-infra)

- **`gh repo create` fails**: usually a name collision or auth scope issue. Stage fails, state file omits the entry, and no checkpoint is written — the repository was not created, so the next attempt must create it. Re-run with `--resume template-mirror` after fixing.
- **The push fails after the remote was created** (transient network, git credentials): stage fails, but the `github-infra:remote-created:<owner>/<name>` checkpoint is already recorded. `--resume template-mirror` then passes preflight, skips `gh repo create`, and repeats only the push (#790).
- **Abort *after* the remote was created** (a `BOOTSTRAP_STRICT_SECRETS=1` secret failure, or the push itself, are the usual ones): `--resume template-mirror` is the documented retry and it works. The `github-infra:remote-created:<owner>/<name>` checkpoint written in step 1 is what lets preflight accept the now-existing remote and lets the re-entry skip `gh repo create` (#761). Nothing else about the stage is skipped — labels, invites, and secrets all run again, and they are idempotent.
- **Label / invite failures**: per-label / per-invite are warn-not- fatal; the loop continues. The summary surfaces the gaps.
- **Secret-set failures**: recorded-but-not-fatal by default. The miss is logged at ERROR level with the remediation command, persisted to `<target>/.bootstrap-state.warnings`, and re-surfaced in the end-of-run summary's `!! RECORDED FAILURES` block so it cannot ship unnoticed (#734). Set `BOOTSTRAP_STRICT_SECRETS=1` to fail the stage instead. Whichever mode, the record names which of the causes sharing the `reviewer-assignment-token` key occurred — including `gh secret set` itself failing, and, told apart from it, the author write path failing before `gh secret set` ran at all (#782). A successful later `REVIEWER_ASSIGNMENT_TOKEN` setup marks the prior token record `RESOLVED` rather than erasing it: the summary still reports it, under the `ok RESOLVED ... no action needed` heading, so the run's history survives without the record reading as outstanding work (#761).
- **Author-authentication failures during the secret set**: the `gh secret set` for `REVIEWER_ASSIGNMENT_TOKEN` runs through `scripts/gh-as-author.sh`, which can fail *before* it starts `gh` — its byline pin refusing the resolved author (exit 2), no author token resolvable (exit 3), or the wrapper missing entirely. The exit code alone does not separate that from `gh secret set` running and failing, so the wizard takes positive proof instead: the wrapped command creates a marker immediately before `exec`ing `gh`, and the record claims "the gh secret-set call itself failed" only when that marker exists. Absent it the record and the ERROR lines say the author write path failed before `gh` ran and point at author authentication — the reviewer PAT the operator just supplied is not the thing to replace (#790). On that branch the wrapper's own diagnostic — which token lookup failed, which identity the byline pin wanted — is also appended to `.bootstrap-log` before the record names its location, so the remediation detail is still there when the sidecar is read after a resume or during a later audit rather than living only in the original terminal. If there is no log file to append to, the record says the diagnostic is in the terminal output instead of pointing at an entry that was never written. Only this pre-`gh` branch persists the captured output: the marker's absence is proof that nothing in the pipeline ever `exec`'d `gh`, so nothing that could have read the piped PAT wrote any of it.
- **Temp dir unavailable during the secret set**: the call is run with a trace marker and an output capture (see the previous bullet), both of which live in a `mktemp -d` directory. If that allocation fails — `TMPDIR` missing, unwritable, or full — the wizard refuses to run the write rather than falling through with empty paths, which would have redirected the capture to `/output`, used `/gh-reached` as the marker, and then reported the resulting failure as an author-authentication problem. The miss is recorded like any other cause under this key, naming the temp dir; fix `TMPDIR` and re-run with `--resume template-mirror` (#790).
- **`REVIEWER_ASSIGNMENT_TOKEN` remediation hint**: emitted as a single `&&`-chained command — a credential preflight for one of the *selected* reviewers, then the `gh secret set` piped through `scripts/gh-as-author.sh`. Run it whole. The author wrapper verifies the account performing the write, **not** the token on its stdin, so a PAT belonging to a non-selected agent installs silently and fails on the first PR; chaining is what stops the preflight from being skipped. For the same reason the hint never recommends whatever is currently in `$OP_PREFLIGHT_REVIEWER_PAT` — reaching that path with the variable set means the stage already refused that token.
- **`REVIEWER_ASSIGNMENT_TOKEN` hint when `--reviewers` names no supported agent**: `scripts/op-preflight.sh` only knows `claude`, `cursor`, and `codex`, and the wizard does not validate `--reviewers` at parse time. When the selection contains none of them there is no cached PAT to preflight for, so the hint switches to a different, still-runnable command: mint a fine-grained PAT for one of the invited reviewer identities, then run `scripts/gh-as-author.sh -- gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo <owner>/<repo>` and supply the PAT when gh asks for it — with `--body` omitted, gh takes the value from stdin. Dropping the `&&` chain is safe here precisely because that command never reads `$OP_PREFLIGHT_REVIEWER_PAT` (#781). Before this the hint printed the chained preflight command with a literal `<selected-reviewer>` in the `--agent` slot, which pasted into a shell as a redirection rather than a remediation.

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
2. **Enroll the repo as a `.mergepath-sync.yml` consumer.** The wizard does the one-time template rsync and the loop-doc registration, but NOT ongoing-sync enrollment — a repo left unenrolled receives none of mergepath's post-bootstrap propagation and never appears in the weekly `propagation-drift` sweep (the mergepath#741 gap). Add it to `consumers:` with a `facts:` block verified against its own `package.json` (`frameworks` / `testing` / `jsx_in_js` / ESM-vs-CJS eslint variant), run `scripts/sync-to-downstream.sh --audit --repos <repo>`, and drive the first sync canary-first (it also joins the wave-0 tier in [propagation-ordering.md](propagation-ordering.md) until that backlog clears). Before that first sync, also confirm whether the repo needs any `.repo-template.yml` or per-consumer `exclusions:` adjustments (mirroring the ffb/dpr precedent) and record the result, rather than discovering gaps mid-PR.
3. **Populate `.env.local` from Firebase web console.** When Firebase is enabled, the deployer SA key handles deploys but the web app config (`firebaseConfig`) requires manual copy-paste from console.firebase.google.com.
4. **Install the Codex App.** The wizard prints the install URL; the human must accept on github.com/apps/codex AND configure a Codex environment at chatgpt.com/codex/cloud/settings/environments. "Code Review enabled" is not sufficient — both pieces are required for review-readiness.
5. **Install the CodeRabbit App.** Same shape: wizard prints the URL, human accepts.
6. **Write the PRD and implementation spec.** The canonical PRD belongs in `nathanjohnpayne/docs/projects/<repo>/prds/`; the wizard-created `specs/<repo>.md` placeholder is the repo-local implementation spec. `scripts/project-doc-sync.sh` is responsible for generated PRD/spec mirrors once the project is added to `.mergepath-project-docs.yml`.
7. **Populate Phase 0 / Phase 1 issues.** The wizard creates the `scripts/gh-projects/examples/<repo>/create-issues.sh` skeleton. The human fills it in and runs it.
8. **Set provider-level spend caps.** Before pasting LLM API keys (Anthropic, OpenAI), the human sets account-level spend caps at `platform.openai.com/account/limits` and `console.anthropic.com/settings/limits`.
9. **Drive Sprint 0 PR #1.** The first end-to-end PR through the review flow (CodeRabbit advisory + reviewer identity + Phase 4 external review) validates the bootstrap.

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
| `BOOTSTRAP_REVIEWER_PAT_OP_REF` | Override the 1Password reference for the reviewer PAT. Default is the item-UUID path `op://Private/pvbq24vl2h6gl7yjclxy2hbote/token`; use UUID paths only (#734). |
| `BOOTSTRAP_STRICT_SECRETS=1` | Fail stage C when `REVIEWER_ASSIGNMENT_TOKEN` cannot be provisioned (default: record the miss and continue). |
| `BOOTSTRAP_INPUT_*` | Pre-set any input via env (bypasses both flag and prompt). |

## Files produced

By the end of a successful run, the target dir contains:

- The full mirrored mergepath template (minus the exclude list).
- `.git/` initialized with one commit.
- `.bootstrap-log` — full transcript of every side effect + the end-of-run summary block.
- `.bootstrap-state` — append-only list of completed stages.
- `.bootstrap-state.checkpoints` — append-only list of irreversible sub-stage steps that succeeded (`github-infra:remote-created:<owner>/<name>`). Written only on live runs.
- `.bootstrap-state.warnings` — recorded must-not-miss failures, one per line, keyed or unkeyed. Present only when something was recorded.
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

**Not** produced by the wizard (still owed as a human NEXT STEP): a `.mergepath-sync.yml` consumer entry. Until that lands, the repo is bootstrapped but not enrolled for ongoing sync (mergepath#741).

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
