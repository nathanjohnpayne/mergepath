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
| [`adapters/review-via-codex.sh`](adapters/review-via-codex.sh) | Direction A (Claude→Codex). `codex exec --sandbox read-only --ask-for-approval never --output-schema verdict.schema.json`. |
| [`adapters/review-via-claude.sh`](adapters/review-via-claude.sh) | Direction B (Codex→Claude). `claude -p --permission-mode plan --output-format json`. |
| [`verdict.schema.json`](verdict.schema.json) | The normalized verdict contract both adapters emit (and the schema Codex is constrained to). |
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
- **Reasoning-plane auth (per direction):** Codex — `CODEX_API_KEY` or
  `codex login`; Claude — `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`)
  or `ANTHROPIC_API_KEY`. Keep these out of job-level env around
  repo-controlled code (Codex docs' warning).
- **Attribution-plane auth:** the reviewer PAT, resolved by
  `scripts/op-preflight.sh` and used through `scripts/gh-as-reviewer.sh`
  (the script auto-sources the preflight cache).
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
| 4 | fell back to the manual handoff (adapter error, invalid verdict, or no adapter) |
| 5 | automation disabled or `mode != local` — caller uses the manual handoff |
