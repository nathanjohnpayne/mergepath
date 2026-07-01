# Prompt: Build the Consolidated Phase 4b Approval Report

**How to use this file.** Paste everything between `===== BEGIN PROMPT =====` and
`===== END PROMPT =====` into a coding agent (Claude Code / Codex CLI) working in
the `mergepath` repo. It is self-contained: it carries the system context, the
feature requirements, the exact report layout, a worked sample, acceptance
criteria, and the files to touch. A short note to Nathan on the design decisions
baked in is at the bottom, outside the prompt.

---

===== BEGIN PROMPT =====

## Role and task

You are implementing a new feature in the **mergepath** repository: a
**Consolidated Phase 4b Approval Report**. When the automated Phase 4b handoff
(shipped disabled in PR #580, `plans/automated-phase-4b-handoff.md`) posts a
**fully automated `APPROVED` review**, the review body must *be* a consolidated
report that lets a product manager or product engineer answer two questions
without opening the code:

1. **Was the automated review rigorous?** (Did it actually do the work, on the
   right commit, under the right constraints—or did it rubber-stamp?)
2. **What did this review cost?** (Tokens, wall-clock, notional API-equivalent
   dollars, plan capacity, and the human time it displaced.)

The report also carries **inline running totals** (cumulative across all
auto-approved PRs in the repo, computed at post time) so the reader sees per-PR
detail and the fleet trend in one place.

Ship it **disabled-by-default and fail-closed**, matching the existing feature's
posture. Do not change the merge gate.

## System context (what already exists—do not rebuild)

The automated Phase 4b handoff is already specified and stubbed. Relevant pieces:

- **Orchestrator** `scripts/phase-4b-review.sh`. HEAD-pins the SHA, selects a
  reviewer ≠ author, runs one adapter pass, parses the verdict, posts the review
  under the reviewer PAT via `scripts/gh-as-reviewer.sh` using the pull-review
  API with `commit_id == HEAD`, then verifies the created review reports that
  same SHA. Emits a machine-parseable JSON summary. Exit codes:
  `0` approved+posted · `1` changes requested · `3` error · `4` fell back to
  manual handoff · `5` automation disabled/skipped.
- **Adapters** `scripts/phase-4b/adapters/review-via-codex.sh` (Direction A,
  Claude→Codex, `codex exec --sandbox read-only --output-schema`) and
  `review-via-claude.sh` (Direction B, Codex→Claude, `claude -p --permission-mode
  plan --tools "" --output-format json`). Read-only; never post to GitHub.
- **Verdict schema** `scripts/phase-4b/verdict.schema.json`. Every adapter emits:
  `{ verdict: "APPROVED" | "CHANGES_REQUESTED", summary: string, findings: [ {
  severity: "P0"|"P1"|"P2"|"P3", path, line, body } ], usage: { token_count,
  input_tokens, output_tokens, source } | null }`. `usage` is populated **only**
  from CLI-exposed counts; adapters must never ask the model to estimate its own
  tokens. `usage: null` means "the CLI did not expose a reliable count."
- **Shared lib** `scripts/phase-4b/lib.sh`. Config readers, reviewer selection,
  bounded-execution/timeout helpers, and the `jq` verdict validator that mirrors
  the schema and reads `feedback_policy`.
- **Policy** `.github/review-policy.yml` → `phase_4b_automation` block
  (`enabled: false`, `mode: local`, `max_review_rounds`, `fail_closed: true`,
  `fallback_on_error: manual-handoff`); plus `feedback_policy`
  (P0/P1 required, P2/P3 discretionary by default), `available_reviewers`,
  `default_external_reviewer: nathanpayne-codex`, `author_identity:
  nathanjohnpayne`.
- **Merge gate (unchanged)** `scripts/codex-review-check.sh` gate (c) accepts an
  `APPROVED` on the current HEAD from a non-author `available_reviewers` identity
  as the "Phase 4b substitute" clearance (`codex.allow_phase_4b_substitute`,
  #218). `merge-clearance-gate.yml` and `auto-clear-blocking-labels.yml` consume
  it. **Your feature must not alter any of these.**
- **Two auth planes.** Reasoning plane = the reviewer CLI on the operator's
  **subscription plan only** (Codex `auth_mode=chatgpt`; Claude
  `apiProvider=firstParty`, `authMethod=claude.ai`/`oauth_token`). API-key env
  vars are scrubbed; if not plan-logged-in the review fails closed. Attribution
  plane = the reviewer PAT via `gh-as-reviewer.sh`. **Billed marginal cost of a
  review is therefore $0**—it runs against a flat-rate subscription. The report's
  dollar figures are *notional* (what the same tokens would have cost on the
  metered API), clearly labeled as not billed.

The **strict posting rule** already in the design: the orchestrator auto-posts
`APPROVED` only for an unambiguous, schema-conformant approval with **no
findings in any `feedback_policy`-required tier**; an approving verdict that
still carries findings routes to the manual handoff so follow-up issues get filed
first. Your report must render honestly under this rule (see "Findings section").

## What to build

A report generator that the orchestrator calls on the approve-and-post path,
producing the Markdown body of the `APPROVED` review. Structure it as a new
`scripts/phase-4b/report.sh` (sourced by the orchestrator), so it is unit-testable
in isolation and the orchestrator stays thin.

The report has six sections, in this order: **Verdict · Rigor · Findings · Cost &
effort · Running totals · Audit metadata (with an embedded machine-readable
block)**. Exact layout and a worked sample are below.

### R1 — The report is the review body

The generator returns Markdown that becomes the `body` of the pull-review API
call the orchestrator already makes. No separate PR comment. The existing
`commit_id == HEAD` pin and post-write SHA verification are unchanged; the report
just replaces the plain summary string as the body.

### R2 — Rigor section (validate the review actually did its job)

Render a table of checks with pass/fail and concrete evidence. Every row must be
derived from a real signal captured during the run—not asserted. At minimum:

| Check | Evidence source |
|---|---|
| Verdict is schema-conformant | `jq` validation against `verdict.schema.json` in `lib.sh` |
| Reviewed the current HEAD | orchestrator HEAD-pin + `created_commit == HEAD` verify |
| Reviewer ≠ author (cross-agent) | `reviewer_agent != author_agent` assertion |
| Plan-only auth (no metered API) | Codex `auth_mode=chatgpt` / Claude `apiProvider=firstParty` probe; API-key env absent |
| Read-only posture | Codex `--sandbox read-only` / Claude `--permission-mode plan --tools ""` |
| Exhaustive review pass | adapter prompt used the bounded "Exhaustive code review" instruction |
| Fail-closed decision rule | approved ⇒ 0 findings in required tiers, per `feedback_policy` |
| Local gates green | `check_phase_4b_automation`, `codex-review-check.sh` gate (c), `resolve-pr-threads.sh --list`, `coderabbit-wait.sh`, `git diff --check` |
| Reviewer CLI version recorded | `codex --version` / `claude --version` captured pre-run (#586) |

If a signal is genuinely unavailable, print `n/a — <reason>`; never print a green
check you did not verify. The point of this section is to make a **zero-finding**
approval legible as "reviewed hard, found nothing blocking" rather than
"skipped"—so proof-of-work (time + tokens + exhaustive-pass wording + CLI
version) matters as much as the pass/fail marks.

### R3 — Findings section (severity breakdown + disposition)

Render a severity table: `severity | count | required by policy? | disposition`.
Because the strict posting rule means an auto-posted approval has **zero
required-tier findings**, this table normally shows `P0 0 / P1 0` as "exhaustive
pass, none found." Advisory findings (P2/P3) that the review surfaced and that
were filed as non-blocking follow-up issues are listed with their issue links
(as the real PR did: P2→#585/#586, P3→#587/#588). Support both postures:

- **Strict (default):** advisory findings ⇒ the orchestrator fell back to manual,
  so a posted auto-approval shows 0/0/0/0 and the section reads "no findings."
- **Approve-with-advisories (if `feedback_policy` + a `file_advisories_as_issues`
  toggle permit it):** list each advisory with its filed issue link and mark it
  non-blocking.

Never let a required-tier finding appear alongside a posted `APPROVED`. If your
data shows one, that is a bug—fail closed, do not post.

### R4 — Cost & effort section (show the expense)

This is the PM/PE money view. Report, for **this review**:

- **Wall-clock latency** (seconds) and **timeout budget used** (e.g.
  `65s / 900s = 7%`). This is the real scarce resource—merge-cycle time.
- **Tokens**: `total`, `input`, `output` when the CLI exposes them; else `total`
  only with `input/output = not exposed by CLI`. Pull from the verdict `usage`
  object. Note that Claude also exposes `cache_creation_input_tokens` /
  `cache_read_input_tokens` in its envelope—capture them if present (extend the
  `usage` schema; see Deliverables), since they materially change cost.
- **Billed cost: `$0.00 (subscription plan)`**—always, on the plan-only path.
- **Notional API-equivalent cost**: `tokens × current list price`, from a
  configurable price table (see Cost model). Label it exactly as
  "notional / not billed."
- **Plan-capacity signals**: throttle/usage-limit events observed during the run
  (the real validation hit a Codex plan throttle once). Count them; a nonzero
  count is a capacity-cost signal even when dollars are $0.
- **Adapter turns**: how many adapter invocations produced this posted verdict
  (normally 1; the orchestrator does one pass per invocation).
- **Human shuttle avoided**: the manual Phase 4b handoff "typically adds 30
  minutes to a few hours per PR" (`REVIEW_POLICY.md` § Phase 4b Triggers). Show a
  fixed, cited estimate range as the offsetting benefit so the reader can weigh
  cost against value.

### R5 — Running totals section (cumulative, computed at post time)

Immediately below the per-PR cost, render repo-wide cumulative figures **to
date, computed when the report is generated**: count of auto-approved PRs,
cumulative wall-clock, cumulative tokens, cumulative notional $, cumulative human
time saved, and the **fail-closed fallback rate** (auto-approvals ÷ total
automated attempts)—the single best "is this trustworthy?" number for a PM.

Compute totals **statelessly from GitHub** (recommended): each report embeds a
hidden machine-readable block (R6); at post time, query prior auto-approved
reviews across the repo authored by `available_reviewers` identities that contain
the report marker, parse their embedded JSON, and aggregate. This has no state
file to drift and is fully auditable. If GitHub-derived aggregation is too slow or
rate-limited, fall back to an append-only ledger at `.mergepath/phase-4b-ledger.jsonl`
(one line per posted report) as a cache—but treat GitHub as the source of truth.
Make the source of the totals explicit in the report footer
(`totals source: github-derived (N reports)` or `ledger cache`).

### R6 — Embedded machine-readable block

End the review body with an HTML comment carrying the structured record, so the
report is both human-readable and machine-parseable (this is what R5 aggregates
and what a future dashboard consumes):

```
<!-- p4b-report:v1
{ "schema": "p4b-report/v1", "pr": 580, "head_sha": "d05ff4d…",
  "verdict": "APPROVED", "direction": "claude->codex",
  "reviewer": "nathanpayne-codex", "author_agent": "claude",
  "adapter_turns": 1, "elapsed_seconds": 65, "timeout_seconds": 900,
  "tokens": { "total": 113918, "input": null, "output": null,
              "cache_creation": null, "cache_read": null, "source": "codex-stderr" },
  "billed_usd": 0.0, "notional_usd": 0.42, "price_table_version": "2026-07-01",
  "throttle_events": 0,
  "findings": { "p0": 0, "p1": 0, "p2": 0, "p3": 0 },
  "advisory_issues": [],
  "gates": { "check_phase_4b_automation": "pass", "codex_review_check_c": "pass",
             "unresolved_threads": 0, "coderabbit": "success", "git_diff_check": "pass" },
  "reviewer_cli_version": "codex/0.137",
  "plan_auth": { "codex": "chatgpt", "claude": null },
  "human_minutes_saved_estimate": [30, 180],
  "generated_at": "2026-07-01T06:12:35Z" }
-->
```

Keep the JSON minimal-escaped and schema-versioned (`p4b-report/v1`) so parsers
can evolve. Do not put anything in this block you did not measure.

### R7 — Fail-closed and data-integrity rules

- The report generator is **advisory to safety, never a gate**: if report
  generation fails, the orchestrator still posts the plain-summary approval it
  posts today (report failure must not block a valid approval, and must not
  fabricate one either).
- **No estimated tokens, ever.** Missing counts render as `not exposed by CLI`.
- **No green checks without evidence.** Unverifiable rigor rows render `n/a`.
- Totals must **degrade gracefully**: if prior-report aggregation fails, print
  `running totals unavailable — <reason>` rather than wrong numbers.
- Everything ships behind `phase_4b_automation.enabled` (already false). Add a
  sub-toggle `phase_4b_automation.report.enabled` (default `true` *when the
  parent is enabled*) so the report can be turned off without disabling
  automation.

## Data-source map (where each datum comes from)

| Report datum | Source |
|---|---|
| verdict, summary, findings[], usage | adapter stdout (verdict.schema.json) |
| head SHA, reviewer, author agent, direction | orchestrator run context |
| elapsed seconds, timeout budget | orchestrator bounded-exec timer / `P4B_*_TIMEOUT_SECONDS` |
| token counts (total/in/out) | verdict `usage`; Codex stderr `tokens used`; Claude JSON envelope `usage` |
| cache tokens, `total_cost_usd` | Claude `--output-format json` envelope (extend `usage`) |
| plan-auth posture | pre-run `codex login status` / `claude auth status --json` |
| throttle events | adapter stderr classification during the run |
| gate results | `check_phase_4b_automation`, `codex-review-check.sh`, `resolve-pr-threads.sh --list`, `coderabbit-wait.sh`, `git diff --check` exit states |
| reviewer CLI version | `codex --version` / `claude --version` captured pre-run |
| advisory issue links | issue numbers returned when the orchestrator files follow-ups |
| notional $ | tokens × price table |
| running totals | aggregation of prior `p4b-report:v1` blocks (github-derived) or ledger cache |
| human-minutes-saved | fixed cited constant from `REVIEW_POLICY.md` § Phase 4b Triggers |

## Cost model

Billed marginal cost is `$0.00` on the plan-only path—state that plainly.
**Notional** cost exists to make consumption legible:

```
notional_usd = (input_tokens/1e6 × price.input)
             + (output_tokens/1e6 × price.output)
             + (cache_creation_tokens/1e6 × price.cache_write)
             + (cache_read_tokens/1e6 × price.cache_read)
```

When only a `total` token count is exposed (Codex), apply a single
`price.blended` per-million rate and mark the figure `~approx (total-token
blended rate)`. Store rates per model in a versioned table—either a
`phase_4b_automation.report.prices` map in `review-policy.yml` or
`scripts/phase-4b/prices.json`—and stamp `price_table_version` into every report
so historical totals stay reproducible. **Do not hardcode prices from memory;
populate the table from current published list prices and treat it as
config.** If a model's price is missing from the table, render notional cost as
`n/a — no price for <model>` rather than guessing.

## Required report layout and worked sample

Render exactly this shape (this sample uses PR #580's real head, real reviewer,
and real measured numbers from the validation thread; treat it as the golden
output for a Claude→Codex clean approval):

---

## ✅ Automated Phase 4b review — APPROVED

Automated cross-agent review posted on the current HEAD. Feature reviewed by the
external reviewer identity headless, on the operator subscription plan. This body
is the consolidated audit + cost record for the approval.

**Verdict:** `APPROVED` · **Reviewer:** `nathanpayne-codex` · **Direction:**
Claude → Codex (`codex exec`, read-only) · **HEAD:** `d05ff4d0` ·
**Decision rule:** approve only if zero findings in `feedback_policy`-required
tiers (P0/P1).

### Rigor

| Check | Result | Evidence |
|---|---|---|
| Verdict schema-conformant | ✅ | validated against `verdict.schema.json` (`lib.sh` jq mirror) |
| Reviewed current HEAD | ✅ | posted `commit_id=d05ff4d0`; created-review SHA re-verified == HEAD |
| Cross-agent (reviewer ≠ author) | ✅ | author agent `claude` ≠ reviewer agent `codex` |
| Plan-only auth (no metered API) | ✅ | `auth_mode=chatgpt`; no `OPENAI_API_KEY`/`CODEX_API_KEY` in child env |
| Read-only posture | ✅ | `codex --ask-for-approval never exec --sandbox read-only` |
| Exhaustive review pass | ✅ | bounded "Exhaustive code review" prompt; 1 adapter pass |
| Fail-closed rule honored | ✅ | 0 required-tier findings ⇒ approval eligible |
| Local gates green | ✅ | `check_phase_4b_automation` 67/67 · gate (c) clear · 0 unresolved threads · CodeRabbit success · `git diff --check` clean |
| Reviewer CLI version | ✅ | `codex/0.137` |

### Findings

| Severity | Count | Required by policy? | Disposition |
|---|---:|---|---|
| P0 | 0 | required | exhaustive pass, none found |
| P1 | 0 | required | exhaustive pass, none found |
| P2 | 0 | discretionary | — |
| P3 | 0 | discretionary | — |

No blocking or advisory findings on the approved head. (When the reviewer surfaces
advisory P2/P3 items, they are filed as non-blocking follow-up issues and listed
here with links; a required-tier finding can never accompany a posted approval.)

### Cost & effort

| Metric | This review |
|---|---|
| Wall-clock latency | **65 s** (timeout budget 900 s · 7% used) |
| Tokens | **113,918 total** (input/output not exposed by Codex CLI) |
| Billed cost | **$0.00** — operator subscription plan |
| Notional API-equivalent | **~$0.42** *(not billed; blended total-token rate, price table `2026-07-01`)* |
| Plan-capacity throttle events | 0 |
| Adapter turns | 1 |
| Human shuttle avoided | **~30 min – 3 h** (manual Phase 4b handoff cost, per `REVIEW_POLICY.md`) |

### Running totals — repo, to date

| Metric | Cumulative |
|---|---|
| Auto-approved PRs | 24 |
| Automated attempts (posted + fell-back) | 27 |
| **Auto-approval / fail-closed rate** | **24 / 27 = 89% approved · 11% fell back to manual (fail-closed working)** |
| Cumulative wall-clock | 41 min |
| Cumulative tokens | 2.36 M |
| Cumulative notional API-equivalent | ~$9.40 *(not billed)* |
| Cumulative human time saved (est.) | ~12 – 72 h |

*Totals source: github-derived (24 `p4b-report:v1` records).*

### Audit metadata

Head `d05ff4d017d3bfebed6fefa41ad39e6d7f3573c6` · reviewer `nathanpayne-codex` ·
adapter `review-via-codex.sh` · 1 pass · timeout 900 s · tokens source
`codex-stderr` · policy `phase_4b_automation.enabled=true`,
`feedback_policy=by-priority(P0,P1 required)` · generated `2026-07-01T06:12:35Z`.

```
<!-- p4b-report:v1 {"schema":"p4b-report/v1","pr":580,"head_sha":"d05ff4d0…","verdict":"APPROVED","direction":"claude->codex","reviewer":"nathanpayne-codex","author_agent":"claude","adapter_turns":1,"elapsed_seconds":65,"timeout_seconds":900,"tokens":{"total":113918,"input":null,"output":null,"cache_creation":null,"cache_read":null,"source":"codex-stderr"},"billed_usd":0.0,"notional_usd":0.42,"price_table_version":"2026-07-01","throttle_events":0,"findings":{"p0":0,"p1":0,"p2":0,"p3":0},"advisory_issues":[],"gates":{"check_phase_4b_automation":"pass","codex_review_check_c":"pass","unresolved_threads":0,"coderabbit":"success","git_diff_check":"pass"},"reviewer_cli_version":"codex/0.137","plan_auth":{"codex":"chatgpt","claude":null},"human_minutes_saved_estimate":[30,180],"generated_at":"2026-07-01T06:12:35Z"} -->
```

---

**What a PM/PE should conclude from the sample:** a real cross-agent review ran on
the exact merged commit, on-plan and read-only, spent ~65 s and ~114 K tokens
doing an exhaustive pass, found nothing blocking, and displaced ~30 min – 3 h of
human shuttling—at $0 billed and ~$0.42 notional. Across the repo, ~9 in 10
automated attempts approve and the rest fail closed to a human, for ~$9 notional
and tens of human-hours saved.

## Acceptance criteria

1. On the auto-approve path, the posted `APPROVED` review body is the six-section
   report; the plain-summary body is used only if report generation fails.
2. Every rigor row and cost figure is derived from a captured run signal; missing
   data renders `n/a`/`not exposed by CLI`, never a fabricated value or an
   estimated token count.
3. A required-tier finding can never accompany a posted `APPROVED` (assert and
   fail closed).
4. Running totals are computed at post time from prior `p4b-report:v1` records
   (github-derived), with a ledger-cache fallback and an explicit totals-source
   footer; aggregation failure degrades to "running totals unavailable," not
   wrong numbers.
5. The embedded `p4b-report:v1` JSON validates against a committed
   `scripts/phase-4b/report.schema.json` and round-trips through the aggregator.
6. The merge gate, merge-clearance gate, and auto-clear workflow are byte-unchanged.
7. Ships behind `phase_4b_automation.enabled` (false) plus
   `phase_4b_automation.report.enabled`; defaults leave current behavior unchanged.
8. Offline tests cover: report rendering for a clean approval, advisory-issues
   rendering, missing-usage/`not exposed` paths, notional-cost math incl. missing
   price, totals aggregation over N fixture records, and the fail-open-on-report-
   error / never-fabricate-approval behavior. Wire a `scripts/ci/check_*` and
   add it to `repo_lint.yml` (the `check_ci_scripts_wired` meta-check requires it).

## Non-goals

- No merge-gate, branch-protection, or `gh-as-reviewer.sh` identity changes.
- No CI-runner execution mode (local-first, like the parent feature).
- No live dashboard—only the embedded machine-readable block that a future
  dashboard could read.
- No changes to reviewer selection, adapters' review logic, or the verdict
  contract beyond the additive `usage` cache-token fields.

## Edge cases to handle

- `usage: null` (Codex often exposes only a total; a CLI may expose nothing).
- Claude cache tokens present but total/`total_cost_usd` shapes differ by CLI build.
- Zero prior reports (first auto-approval): totals show `1`/current-run values.
- Aggregation hits GitHub rate limits mid-scan → ledger cache or "unavailable."
- Price table missing the model → notional `n/a`, report still posts.
- Multi-pass validation runs (like PR #580's 4-turn accounting): the template is
  a superset—render one row per turn in an optional "turns" subtable when
  `adapter_turns > 1`, summing tokens/time, exactly as the "Approval accounting
  correction" comment on #580 did.

## Deliverables

- `scripts/phase-4b/report.sh` — report generator (sourced by the orchestrator).
- `scripts/phase-4b/report.schema.json` — schema for the `p4b-report:v1` block.
- `scripts/phase-4b/prices.json` (or a `review-policy.yml` price map) — versioned
  notional-cost rates.
- Additive `usage` fields (`cache_creation_input_tokens`,
  `cache_read_input_tokens`, `total_cost_usd`) in `verdict.schema.json`, all
  optional/nullable, populated only from CLI metadata.
- Orchestrator hook in `scripts/phase-4b-review.sh`: build the body via
  `report.sh` on the approve path; fall back to plain summary on generator error.
- `phase_4b_automation.report` block in `.github/review-policy.yml` (documented,
  `enabled: true` under the disabled parent).
- Tests `tests/test_phase_4b_report.sh` + `scripts/ci/check_phase_4b_report`,
  wired into `repo_lint.yml`; register new files in `.mergepath-sync.yml`.
- Docs: extend `plans/automated-phase-4b-handoff.md` (new § on the report) and
  `scripts/phase-4b/README.md`.

Follow the repo's conventions in `AGENTS.md` and the shell-safety rules
(`set -euo pipefail`, quoted vars, no bare `gh` writes—route through
`gh-as-reviewer.sh`). Keep the reference disabled and fail-closed.

===== END PROMPT =====

---

## Note to Nathan (not part of the prompt)

Design decisions I baked in, per your answers and the #580 evidence:

- **Report lives in the `APPROVED` review body** (your pick), not a separate
  sticky comment. It reuses the orchestrator's existing HEAD-pinned pull-review
  POST, so attribution and the SHA pin come for free.
- **Inline running totals** (your pick) computed **statelessly from prior
  embedded report blocks** rather than a state file—no drift, fully auditable,
  with a ledger cache as the escape hatch if GitHub aggregation is too slow.
- **The "expense" is framed as four real costs, not one dollar number**:
  wall-clock (the actual scarce resource), tokens, plan-capacity/throttle events,
  and a clearly-labeled *notional* API-equivalent $—because the plan-only billing
  design means the true billed marginal cost is $0. I paired it with the
  human-time-saved constant from `REVIEW_POLICY.md` so a PM sees cost against
  value. If you'd rather the report lead with billed-$ only and drop the notional
  figure, that's a one-line change to R4.
- **Rigor for a zero-finding approval** is the subtle part. The strict posting
  rule means auto-approvals have no blocking findings, so "rigor" can't be "look
  how many bugs it caught." I made it "proof of work": exhaustive-pass wording +
  time + tokens + read-only + plan-auth + CLI version + gates green. That's what
  separates a real review from a rubber stamp in the data.
- The **sample uses #580's real numbers** (head `d05ff4d`, `nathanpayne-codex`,
  65 s, 113,918 tokens) but the running-totals figures are illustrative
  placeholders—there's no fleet history yet.

One open question worth deciding before you hand this off: under the current
strict rule, an approval *with* advisory P2/P3 findings falls back to manual, so
those advisories never appear on an auto-posted report. If you want the report to
showcase advisory findings (like #585–#588) as evidence of rigor, you'd need to
allow "approve-with-advisories + auto-file issues," which loosens the posting
rule. I specced the report to handle both, but flagged it rather than choosing—it
changes the safety posture.
