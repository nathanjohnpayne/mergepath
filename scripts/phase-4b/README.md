# `scripts/phase-4b/` — automated Phase 4b review handoff

Reference implementation for automating the Phase 4b external-review
handoff (REVIEW_POLICY.md § Phase 4b). Design and diagrams:
[`plans/automated-phase-4b-handoff.md`](../../plans/automated-phase-4b-handoff.md).

This started as a disabled reference implementation: runnable, fail-closed,
unit-tested with fake CLIs, and accompanied by real plan-backed `codex` /
`claude` validation evidence in PR #580's review thread. **Mergepath itself
runs it ENABLED since 2026-07-02 (#628: `phase_4b_automation.enabled: true`,
xhigh effort on both adapters, accounting live)** — the bootstrap template
mirror resets the switch to `false`, so any OTHER repo still opts in
explicitly and should re-run the live adapter validation from its own
enablement environment before flipping `phase_4b_automation.enabled: true`.
Invocation and the trusted-path rule (run from a main-ref checkout, never
the PR-under-review's checkout) live in REVIEW_POLICY.md and AGENTS.md.

## Components

| Path | Role |
|------|------|
| [`../phase-4b-review.sh`](../phase-4b-review.sh) | Orchestrator. Selects the reviewer (≠ author), dispatches to an adapter, fails closed on any doubt, and posts the verdict under the reviewer PAT via `gh-as-reviewer.sh`. |
| [`adapters/review-via-codex.sh`](adapters/review-via-codex.sh) | Direction A (Claude→Codex). `codex --ask-for-approval never exec --sandbox read-only --output-schema verdict.schema.json`. |
| [`adapters/review-via-claude.sh`](adapters/review-via-claude.sh) | Direction B (Codex→Claude). `claude -p --system-prompt ... --permission-mode plan --effort medium --tools "" --output-format json`. |
| [`verdict.schema.json`](verdict.schema.json) | The normalized verdict contract both adapters emit, with optional adapter-populated token usage metadata when the CLI exposes it. **Single source of truth for the structural contract** — the `lib.sh` validator derives its key sets and enums from this file (see below). |
| [`lib.sh`](lib.sh) | Shared config readers, reviewer selection, `jq`-based verdict validation, JSON-block extraction, and the per-adapter timeout/effort resolvers. |
| [`collect-enablement-evidence.sh`](collect-enablement-evidence.sh) | Captures the pre-enablement evidence (#586): CLI versions, plan-auth status, API-key env scan, resolved config, and an optional adapter dry-run. Markdown or `--json`; exits `1` when BLOCKED. |
| [`accounting.sh`](accounting.sh) | Approval-loop accounting (#602). Sourced by the orchestrator; renders the "## Phase 4b Approval Accounting" block + embedded `p4b-accounting:v1` record into the automated `APPROVED` review body. Pure functions, no network; advisory to safety (any failure ⇒ the plain summary posts). |
| [`accounting.schema.json`](accounting.schema.json) | JSON Schema for the embedded `p4b-accounting/v1` record; the golden #580 sample is validated against it in `tests/test_phase_4b_accounting.sh`. |
| [`prices.json`](prices.json) | Versioned public-list-price table (#604) for the accounting's **notional** (not-billed) cost figures; every record stamps the `price_table_version` it used. |

### Verdict contract: drift resistance & extraction

- **Schema-derived validation (#585).** `p4b_validate_verdict` no longer
  hand-mirrors the verdict's structural constants. It reads the top-level key
  set, the `verdict` enum, the per-finding key set, the `severity` enum, and
  the `usage` key set **from `verdict.schema.json` at validation time**, so
  editing the schema reconfigures the validator automatically — the two cannot
  silently drift. Only the semantics the JSON Schema cannot express stay in
  `jq`: the config-dependent `feedback_policy` approval gate, the
  all-or-nothing `usage` object, and the 1-based `line` bound. A missing or
  malformed schema makes validation fail closed. `tests/test_phase_4b_automation.sh`
  adds behavior-locking parity fixtures (`tests/fixtures/phase_4b_verdicts.jsonl`),
  schema-vs-validator boundary assertions, and — when a JSON Schema validator
  (`check-jsonschema`/`ajv`) is installed — an independent cross-check that every
  validator-accepted fixture is also schema-valid.
- **Hardened JSON extraction (#587).** `p4b_extract_json_block` (used by the
  Claude adapter to pull the verdict out of model output) is a string-aware
  brace-depth scanner rather than a naive first-`{`-to-last-`}` slice. It tracks
  JSON string literals (honoring `\"` / `\\` escapes) so braces inside string
  values don't miscount, and it stops at the matching close of the **first**
  balanced object — so balanced-brace prose *after* the JSON object can no
  longer extend the slice and corrupt it. Unbalanced or object-free input emits
  nothing, so schema validation still fails closed on ambiguous output.

### Approval-loop accounting (#602)

When `phase_4b_automation.accounting.enabled` is not `false` (the default is
`true`; with mergepath's parent switch now on, the block is live — on a repo
whose parent `enabled` is false it still gates everything), the
orchestrator sources `accounting.sh` and:

1. **Records every loop.** Each invocation appends one loop record to a
   per-PR loop log under `.mergepath/phase-4b-loops/` (gitignored runtime
   state; override with `P4B_ACCT_STATE_DIR`) — including CHANGES_REQUESTED
   rounds and fail-closed fallbacks (reason + duration, counted as positive
   safety evidence), so a changes-requested-then-fixed cycle renders its full
   history.
2. **Augments the APPROVED body.** On an approval it appends the
   "## Phase 4b Approval Accounting" block — loop table, findings lifecycle
   with dispositions, a rigor proof-of-work table (rows are green only when
   the backing signal was captured; otherwise `n/a — reason`), the four-part
   cost model (wall-clock / CLI-exposed tokens / throttle / labeled
   **notional** $ with billed `$0.00` on the plan; a CLI-REPORTED cost —
   Claude envelope `total_cost_usd` → `tokens.cost_usd` /
   `totals.reported_cost_usd` — is preferred over the price-table notional,
   labeled `CLI-reported`), repo running totals with
   an explicit totals-source footer, and the embedded machine-readable
   `<!-- p4b-accounting:v1 ... -->` record (`accounting.schema.json`,
   comment-delimiter sequences inside record strings emitted as JSON
   unicode escapes so a hostile title can never close the comment early).
3. **Fails open for reporting, closed for integrity.** Any generation error ⇒
   the plain-summary approval posts unchanged (a report failure never blocks
   or fabricates an approval; exit codes are untouched). The builder and the
   renderer both refuse a record whose loop history would pair a posted
   `APPROVED` with a required-tier finding; token counts are never estimated
   (`unavailable` + source); a missing price ⇒ notional `n/a` while the record
   still posts; running-totals aggregation trouble degrades to `unavailable`
   rather than wrong numbers.

Running totals prefer an injected GitHub-derived prior-record file
(`P4B_ACCT_PRIOR_RECORDS_JSONL`, e.g. prior review bodies piped through
`p4b_acct_extract_records`); when none is injected the hook layer fetches
one itself — a single read-only `gh api graphql` call over the most
recently updated 50 merged PRs (cap via `P4B_ACCT_PRIOR_SCAN_PRS`),
plan-safe, PATH-shimmable in tests — so the real orchestrator path reports
repo-wide totals from any checkout. On fetch failure they fall back to the
append-only `.mergepath/phase-4b-ledger.jsonl` cache (two-phase commit: the record is
staged at render time and appended only after the review POST actually
succeeds, so dry-runs, head drift, and POST failures never contaminate it —
those failure paths also correct the per-PR loop log in place, so local state
never claims a phantom posted approval), else render `unavailable`. A prior
record with an unavailable (null) tokens/elapsed/notional measurement makes
that CUMULATIVE figure `unavailable` too, per metric — never coerced to 0. Notional pricing
requires the opt-in `accounting.{codex,claude}_price_key` mappings into
`prices.json` because the adapters do not capture exact model IDs yet.
Covered by `tests/test_phase_4b_accounting.sh` via
`scripts/ci/check_phase_4b_accounting`; design detail in
`plans/automated-phase-4b-handoff.md` § 17 and the reconciled spec
`plans/issue-602-phase-4b-accounting-SPEC.md`.

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
- **Timeouts + effort (configurable, #589):** the reviewer CLI timeout and
  effort are read per-adapter from `phase_4b_automation` so Codex and Claude can
  be tuned without editing the adapter scripts. The orchestrator resolves them
  (`p4b_resolve_adapter_timeout` / `p4b_resolve_adapter_effort`) and passes them
  down via `P4B_REVIEW_CLI_TIMEOUT_SECONDS` and `P4B_{CLAUDE,CODEX}_EFFORT`.
  - **Timeout:** `adapter_timeout_seconds` (shared) with optional
    `codex_timeout_seconds` / `claude_timeout_seconds` overrides. Must be an
    integer in `[1, 3600]`; absent ⇒ `900`. A non-integer or out-of-range value
    is rejected **fail-closed** (the orchestrator exits `3`) so a typo can never
    effectively unbound the CLI. `P4B_ADAPTER_TIMEOUT_SECONDS` /
    `P4B_REVIEW_CLI_TIMEOUT_SECONDS` still override at runtime for tests/manual
    runs. A timeout exits through the same fail-closed manual-handoff path as any
    other adapter error.
  - **Effort:** `claude_effort` (`low|medium|high|xhigh|max`, default `medium`,
    → `claude --effort`) and `codex_effort` (`minimal|low|medium|high|xhigh`,
    `xhigh` model-dependent, default empty = Codex CLI default, → `codex -c
    model_reasoning_effort`, validated against codex-cli 0.137; `--strict-config`
    is not used, so an unrecognized key on a future CLI is a harmless no-op). An
    invalid value is rejected fail-closed.
- **Review metadata:** posted reviews include reviewed head SHA, reviewer
  identity, adapter, adapter run count, timeout, token usage when exposed by
  the CLI, and an explicit `not exposed` marker for model-internal turn count.
  CLI token counters are best-effort because reviewer CLI stderr/envelope
  formats can change; when parsing fails the adapters safely emit `usage: null`.
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

Before flipping the switch, capture the enablement evidence (#586) from the
environment that will post reviews, on plan auth, with no API-key env vars set:

```bash
# Markdown for a PR comment, or --json for machine checks. Exits 1 if BLOCKED
# (an API key is set, or no direction has a plan-authed CLI). Add
# --diff-file <patch> (or --pr N --repo owner/repo) to include a live dry-run.
scripts/phase-4b/collect-enablement-evidence.sh
```

It records `codex --version` / `claude --version`, each adapter's plan-auth
status, the disallowed-API-key scan, the resolved per-adapter timeout/effort,
and (optionally) a successful adapter dry-run — the exact evidence the
enablement PR should paste. Then flip the switch:

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
