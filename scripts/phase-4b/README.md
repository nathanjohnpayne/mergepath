# `scripts/phase-4b/` — automated Phase 4b review handoff

Reference implementation for automating the Phase 4b external-review
handoff (REVIEW_POLICY.md § Phase 4b). Design and diagrams:
[`plans/automated-phase-4b-handoff.md`](../../plans/automated-phase-4b-handoff.md).

These are **reference stubs**: runnable, fail-closed, and unit-tested with
fake CLIs, but the live `codex` / `claude` integration should be validated
against a real CLI before the feature is enabled in a repo (see the open
questions in the plan).

## Components

| Path | Role |
|------|------|
| [`../phase-4b-review.sh`](../phase-4b-review.sh) | Orchestrator. Selects the reviewer (≠ author), dispatches to an adapter, fails closed on any doubt, and posts the verdict under the reviewer PAT via `gh-as-reviewer.sh`. |
| [`adapters/review-via-codex.sh`](adapters/review-via-codex.sh) | Direction A (Claude→Codex). `codex --ask-for-approval never exec --sandbox read-only --output-schema verdict.schema.json`. |
| [`adapters/review-via-claude.sh`](adapters/review-via-claude.sh) | Direction B (Codex→Claude). `claude -p --system-prompt ... --permission-mode plan --effort medium --tools "" --output-format json`. |
| [`verdict.schema.json`](verdict.schema.json) | The normalized verdict contract both adapters emit, with optional adapter-populated token usage metadata when the CLI exposes it. |
| [`lib.sh`](lib.sh) | Shared config readers, reviewer selection, and `jq`-based verdict validation. |

## How it plugs in (no merge-gate changes)

The orchestrator posts an `APPROVED` review on the current HEAD under a
non-author reviewer identity. That is exactly the **Phase 4b substitute**
clearance the existing merge gate already accepts
(`scripts/codex-review-check.sh` gate (c), `codex.allow_phase_4b_substitute`,
#218), so `auto-clear-blocking-labels.yml` and `merge-clearance-gate.yml`
clear with no changes.

```
phase-4b-classifier.sh (is 4b needed?) ─▶ phase-4b-review.sh
                                              │ select reviewer ≠ author
                                              ▼
                         review-via-{codex,claude}.sh  (read-only reasoning)
                                              │ normalized verdict JSON
                                              ▼
                         gh-as-reviewer.sh ── APPROVED/CHANGES_REQUESTED on HEAD
                                              ▼
                         codex-review-check.sh gate (c)  →  auto-clear  →  merge
```

## Dependencies

- **Runtime:** `bash` (3.2+), `jq`, `gh`, `git`, and the reviewer CLI
  (`codex` and/or `claude`) on `PATH`.
- **Reasoning-plane auth (per direction) — subscription plan only:** the
  adapters verify the persisted CLI auth mode before launch and run the
  reviewer CLI under a tightly allowlisted child environment. Codex must report
  `auth_mode=chatgpt`; Claude must report `apiProvider=firstParty` with either
  `authMethod=claude.ai` plus a `subscriptionType`, or
  `authMethod=oauth_token` for a headless Claude Code subscription token.
  Reasoning therefore bills against the operator's **individual plan**, never
  the metered API. API-key env vars, GitHub tokens, deploy/cloud credentials,
  and SSH-agent state are not inherited by the child CLI.
  Log in once per direction: Codex via `codex login` (ChatGPT account);
  Claude via its subscription login or `claude setup-token`
  (`CLAUDE_CODE_OAUTH_TOKEN`, which is preserved). If the CLI is not
  plan-logged-in, the read-only call fails and the orchestrator falls back to
  the manual handoff (fail-closed) — it never uses the API.
- **Child-process credential isolation:** the reviewer CLI child process is
  launched with an allowlisted environment (`PATH`, `HOME`, locale/tmp basics,
  plus `CODEX_HOME` or `CLAUDE_CODE_OAUTH_TOKEN` only when needed). It does not
  inherit GitHub tokens, pay-per-token API keys, deploy/cloud credentials, or
  SSH agent state from the parent session. Only the parent orchestrator keeps
  the reviewer PAT, and only for the final `gh-as-reviewer.sh` write after the
  head SHA is re-read. The write uses the pull-review API with `commit_id` set
  to the reviewed SHA and verifies the created review response is pinned to
  that SHA.
- **Tool/file-access isolation:** Codex runs from an empty scratch review root
  with scratch `HOME`/`CODEX_HOME`; the copied Codex auth file lives outside the
  review root. Claude runs with a compact structured-output prompt, a
  text-only system prompt, `--effort medium`, `--tools ""`, `--safe-mode`,
  disabled slash commands, and no session persistence. The diff is supplied on
  stdin in both directions, so neither reviewer needs repo or home-directory
  read tools.
- **Timeouts:** adapter execution and the underlying reviewer CLI are bounded
  by `P4B_ADAPTER_TIMEOUT_SECONDS` / `P4B_REVIEW_CLI_TIMEOUT_SECONDS`
  (default `900`). A timeout exits through the same fail-closed manual handoff
  path as any other adapter error.
- **Review metadata:** posted reviews include reviewed head SHA, reviewer
  identity, adapter, adapter run count, timeout, token usage when exposed by
  the CLI, and an explicit `not exposed` marker for model-internal turn count.
- **Feedback-policy approval gate:** the verdict validator reads
  `feedback_policy` when present (#574). `APPROVED` may not carry findings in
  any policy-required severity tier; absent `feedback_policy` defaults to
  P0/P1 required and P2/P3 discretionary. `mode: address-all` makes every
  finding block an automated approval. Separately, the orchestrator refuses to
  post any `APPROVED` verdict that still carries findings, because repo policy
  requires observations/risks from an approving external reviewer to become
  post-review issues before that approval clears the merge gate.
- **Attribution-plane auth:** the selected reviewer's PAT is resolved through
  `scripts/gh-as-reviewer.sh`. The orchestrator sets
  `GH_AS_REVIEWER_IDENTITY` and deliberately clears a stale
  `OP_PREFLIGHT_REVIEWER_PAT` from the authoring agent session before the
  wrapper runs, so the wrapper verifies the selected reviewer identity instead
  of hard-failing on the current agent's cached reviewer PAT.
- **Config:** the `phase_4b_automation:` block in
  `.github/review-policy.yml` (ships **disabled**, so behavior is unchanged
  until a repo opts in).

## Enabling

```yaml
# .github/review-policy.yml
phase_4b_automation:
  enabled: true
  mode: local
```

While disabled (default), `phase-4b-review.sh` exits `5` and the caller
uses today's manual handoff (`post-phase-4b-handoff.sh`).

`max_review_rounds` is a declarative cap for the outer review flow. This
reference helper performs one exhaustive adapter pass per invocation; callers
that re-run it after `CHANGES_REQUESTED` own round counting and escalation.

## Try it (dry-run, offline, with fake CLIs)

```bash
printf 'verdict' > /tmp/diff.txt
CODEX_BIN=/path/to/fake-codex \
  scripts/phase-4b-review.sh 123 --repo nathanjohnpayne/mergepath \
    --author claude --head deadbeef --diff-file /tmp/diff.txt --dry-run
```

`--dry-run` performs selection + adapter dispatch + verdict validation and
prints the intended action without posting. Adapter CLIs are injectable via
`CODEX_BIN` / `CLAUDE_BIN`, which is how `tests/test_phase_4b_automation.sh`
exercises the package without network or real model calls.

## Exit codes (orchestrator)

| Code | Meaning |
|------|---------|
| 0 | APPROVED — review posted (or would, under `--dry-run`) |
| 1 | CHANGES_REQUESTED — posted; author addresses findings, then re-run |
| 3 | usage / infrastructure error |
| 4 | fell back to the manual handoff (adapter error, timeout, invalid verdict, head drift, or no adapter) |
| 5 | automation disabled or `mode != local` — caller uses the manual handoff |
