<!--
DELIVERY NOTE (not part of the issue content)

I could not write to GitHub directly: the connected GitHub connector is read-only
for this repo, so both editing the #602 body and commenting returned
403 "Resource not accessible by integration."

To make this the source of truth, do ONE of:
  A. Paste PART 1 below into the issue #602 body (Edit → replace), then paste
     PART 2 as a comment. One paste each.
  B. Grant a GitHub connector with issues:write (claude.ai connector settings, or
     `claude mcp` / /mcp in an interactive session) and ask me to post it.
  C. Commit this file to plans/ as the canonical spec and point #602 at it.

Everything below is the reconciled spec: original ticket + the #580 report work,
best-of-both.
-->

# PART 1 — paste as the issue #602 body

> **Status: SOURCE OF TRUTH for implementation.** Reconciled 2026-07-01 from the original ticket framing + the consolidated-report spec drafted off the #580 thread. Where the two disagreed, the choice and reason are recorded in the reconciliation comment (PART 2). Parent design: `plans/automated-phase-4b-handoff.md` (#580). Build against this body.

## Summary

Add first-class **Phase 4b approval-loop accounting**: every automated Phase 4b review records the full **rigor, cost, time, and quality** story, automatically and completely, so an operator never has to reconstruct it after the fact (as had to happen on #580).

The accounting is **loop-centric** (every adapter attempt is recorded, not just the final approval), **folded into the `APPROVED` review body** as the canonical block, carries **inline running totals** across all auto-approved PRs, and emits a **machine-readable ledger** for later audit/finance/PRD aggregation. It ships **disabled-by-default and fail-closed**, and changes **no merge-gate code**.

## Consumer and the questions it must answer

The consumer is the operator paying for model usage and shipping software with agents: **product engineer, product manager, and finance stakeholder**. The block must let them answer, without opening the code:

- How much LLM work did this approval require, and **what did it cost** (tokens, time, dollars)?
- How many loops did each agent run; how long did each take; what did each find (P0/P1/P2/P3/nitpick)?
- Which findings were fixed, rebutted, deferred, filed as issues; **which commits fixed which findings**?
- Did the process **fail closed** anywhere, and did that prevent an unsafe approval?
- For a **zero-finding** approval: how do I know it was reviewed hard rather than rubber-stamped?
- **Was the approval worth the cost and delay?**

## Where it lives and how it is posted (decided)

- The accounting block **is the body of the automated `APPROVED` review**, posted through the orchestrator's existing HEAD-pinned pull-review POST (`commit_id == HEAD`, created-review SHA re-verified). No separate sticky comment.
- Report generation is **advisory to safety, never a gate**: if generation fails, the orchestrator posts the plain-summary approval it posts today. A report failure must never block a valid approval, and must never fabricate one.
- Ships behind the existing `phase_4b_automation.enabled` (false) plus a new sub-toggle `phase_4b_automation.accounting.enabled` (default `true` under the disabled parent), so accounting can be turned off without disabling automation.

## System context (exists already — do not rebuild)

- **Orchestrator** `scripts/phase-4b-review.sh`: HEAD-pins, selects reviewer ≠ author, runs one adapter pass per invocation, parses/validates the verdict, posts via `scripts/gh-as-reviewer.sh`, emits a JSON summary. Exit codes: `0` approved+posted · `1` changes requested · `3` error · `4` fell back to manual · `5` disabled/skipped.
- **Adapters** `scripts/phase-4b/adapters/review-via-codex.sh` (Direction A, Claude→Codex, `codex exec --sandbox read-only --output-schema`) and `review-via-claude.sh` (Direction B, Codex→Claude, `claude -p --permission-mode plan --tools "" --output-format json`). Read-only; never post to GitHub.
- **Verdict schema** `scripts/phase-4b/verdict.schema.json`: `{ verdict: APPROVED|CHANGES_REQUESTED, summary, findings:[{severity:P0|P1|P2|P3, path, line, body}], usage:{token_count,input_tokens,output_tokens,source}|null }`. `usage` is populated **only** from CLI-exposed counts; adapters must never estimate tokens.
- **Shared lib** `scripts/phase-4b/lib.sh`: config readers, reviewer selection, bounded-exec/timeout helpers, `jq` verdict validator that reads `feedback_policy`.
- **Policy** `.github/review-policy.yml`: `phase_4b_automation` block; `feedback_policy` (P0/P1 required, P2/P3 discretionary by default); `available_reviewers` (`nathanpayne-claude|-cursor|-codex`); `default_external_reviewer: nathanpayne-codex`; `author_identity: nathanjohnpayne`. Configurable adapter **timeout/effort** land via **#589** (closed) — record the *configured* values per loop.
- **Merge gate (unchanged)** `scripts/codex-review-check.sh` gate (c): an `APPROVED` on the current HEAD from a non-author `available_reviewers` identity is the Phase 4b substitute clearance (`codex.allow_phase_4b_substitute`, #218). Do not touch it, `merge-clearance-gate.yml`, or `auto-clear-blocking-labels.yml`.
- **Two auth planes.** Reasoning plane = reviewer CLI on the operator's **subscription plan only** (Codex `auth_mode=chatgpt`; Claude `apiProvider=firstParty`). API-key env is scrubbed; not-plan-logged-in fails closed. Attribution plane = reviewer PAT via `gh-as-reviewer.sh`. **Billed marginal cost of a review is $0** (flat-rate plan); dollar figures in the accounting are *notional* (metered-API equivalent), always labeled as not billed.
- **Strict posting rule** (design invariant): the orchestrator auto-posts `APPROVED` only for a schema-conformant approval with **zero findings in any `feedback_policy`-required tier**. An approving verdict that carries findings routes to manual. The loop-centric model records the loops that surfaced advisories as history even though the posted approval is clean — this is how rigor is shown without loosening the rule.

## Accounting model

### Loop-centric recording

Record **every** Phase 4b loop/attempt, including direct adapter probes, orchestrator dry-runs, fail-closed fallbacks, and (when data is collectable) manual old-style handoffs. Per loop capture:

- `loop`, `reviewer` identity, `adapter` + `direction` (`claude->codex` / `codex->claude` / `manual`), reviewed `head_sha`, adapter command path, `verdict`, `posted?` (posted / dry-run / not-posted), `fell_back?`.
- **Timing**: start, end, `elapsed_seconds`; plus repo-level `wall_time_first_loop_to_approval_seconds`.
- **Tokens** (when exposed): `input`, `output`, `cache_creation`, `cache_read`, `reasoning`, `total`, and `source`; explicit `"unavailable"` with reason when the CLI exposes nothing. Extend the verdict `usage` object with the cache/reasoning fields (additive, nullable, CLI-sourced only).
- **Findings** normalized to the accounting severity superset `{P0, P1, P2, P3, nitpick, unknown}` (verdict contract stays P0–P3; nitpick/unknown buckets absorb CodeRabbit/Codex-bot/other sources and anything unmapped).
- **CLI version** evidence per loop (integrate with **#586**), configured **timeout/effort** (from **#589**), `throttle_events`, and `plan_auth` posture.
- **Fail-closed** record per loop: `{happened, reason, duration_seconds}` — counted as **positive safety evidence**, never hidden.

### Findings lifecycle

Track each finding across loops: `first_loop`, `last_seen`, and distinguish **current-head unique findings** from **repeated/stale** ones. Record a **disposition**: `fixed` (with **fix commit** link), `rebutted`, `deferred-to-follow-up` (with **issue** link), `accepted-risk`, `false-positive`, or `unresolved`.

### Rigor-as-proof-of-work (zero-finding approvals)

Because the strict rule means an auto-posted approval has no blocking findings, "rigor" cannot be "bugs caught." Render a rigor table whose rows are each backed by a captured run signal, so a clean approval reads as *reviewed hard* rather than *skipped*: verdict schema-valid; reviewed current HEAD (pin verified); reviewer ≠ author; plan-only auth (no metered API); read-only posture; exhaustive-pass prompt used; fail-closed rule honored; local gates green (`check_phase_4b_automation`, gate (c), `resolve-pr-threads.sh --list`, `coderabbit-wait.sh`, `git diff --check`); reviewer CLI version recorded. Any signal genuinely unavailable renders `n/a — reason`; never a green check without evidence.

## Cost model (the finance answer)

Marginal **billed** cost on the plan-only path is `$0.00` — state it plainly. **Notional** cost makes consumption legible:

```
notional_usd = input/1e6·p.input + output/1e6·p.output
             + cache_creation/1e6·p.cache_write + cache_read/1e6·p.cache_read
```

When only a total is exposed (Codex), apply a single `p.blended` per-million rate and mark it `~approx`. Store rates per model in a **versioned** table (`scripts/phase-4b/prices.json` or a `phase_4b_automation.accounting.prices` map) and stamp `price_table_version` into every record so historical totals stay reproducible. **Do not hardcode prices from memory**; populate from current published list prices and treat as config. Missing price ⇒ notional `n/a`, record still posts.

When the CLI **reports** a cost directly (the Claude print-mode envelope's `total_cost_usd`), prefer it over the computed notional: the per-loop record carries it as `tokens.cost_usd`, the per-approval `totals.reported_cost_usd` sums it fail-closed (null unless every loop with measured usage also reported one — never a partial underreport), and the cost row labels its source (`CLI-reported` vs the price-table notional). Absent stays `n/a` — the never-guess contract is unchanged.

Present the expense as four real costs, not one number: **wall-clock** (the actual scarce resource — merge-cycle latency), **tokens**, **plan-capacity/throttle events**, and the labeled **notional $**. Pair it with **human shuttle time avoided** — the manual Phase 4b handoff "typically adds 30 minutes to a few hours per PR" (`REVIEW_POLICY.md` § Phase 4b Triggers) — so the reader weighs cost against value.

## Running totals (cumulative, computed at post time)

Below the per-PR cost, render repo-wide cumulative figures computed when the block is generated: auto-approved PR count, automated-attempt count, **auto-approval / fail-closed rate** (the best single trust signal), cumulative wall-clock, cumulative tokens (by provider), cumulative notional $, and cumulative human-time saved.

Compute **statelessly from GitHub** (recommended): each posted block embeds the machine-readable record; at post time, aggregate prior records across the repo (reviews by `available_reviewers` identities carrying the block marker). No state file to drift, fully auditable. Fallback: append-only `.mergepath/phase-4b-ledger.jsonl` cache if GitHub aggregation is rate-limited. Always print the totals source in the footer; aggregation failure degrades to `running totals unavailable — reason`, never wrong numbers.

## Output shape — worked sample (golden output for the #580 case)

This reproduces the #580 four-loop story that had to be posted by hand, as the workflow would now emit it. Real measured numbers; running-totals figures are illustrative placeholders (no fleet history yet).

---

## Phase 4b Approval Accounting

**Reviewed head:** `d05ff4d0` · **Final approval:** `APPROVED` as `nathanpayne-codex` (Claude→Codex) · **Automation state:** dry-run (feature disabled) · **Wall time, first 4b loop → approval:** 225 s reviewer time.

### Loop summary

| Loop | Reviewer | Adapter · direction | Verdict | Posted? | Elapsed | Tokens (source) | P0 | P1 | P2 | P3 | Nit | Outcome |
|---:|---|---|---|---|---:|---|---:|---:|---:|---:|---:|---|
| 1 | nathanpayne-codex | codex exec · claude→codex | APPROVED | direct probe | 18 s | 55,926 (codex-stderr) | 0 | 0 | 0 | 0 | 0 | clean |
| 2 | nathanpayne-codex | orchestrator dry-run · claude→codex | APPROVED | dry-run (would post) | 65 s | 113,918 (codex-stderr) | 0 | 0 | 0 | 0 | 0 | clean, posting path |
| 3 | nathanpayne-claude | claude -p · codex→claude | APPROVED + advisories | direct probe | 66 s | 7,360 (claude-json: in 1,589 / out 5,771) | 0 | 0 | 2 | 2 | 0 | 4 advisories filed |
| 4 | nathanpayne-claude | orchestrator dry-run · codex→claude | approval carried findings | not posted | 76 s | unavailable (not retained) | 0 | 0 | — | — | — | **fail-closed → manual** |

### Rigor (final posted approval, loop 2)

| Check | Result | Evidence |
|---|---|---|
| Verdict schema-conformant | ✅ | `lib.sh` jq mirror of `verdict.schema.json` |
| Reviewed current HEAD | ✅ | posted `commit_id=d05ff4d0`, created-review SHA re-verified |
| Cross-agent (reviewer ≠ author) | ✅ | author `claude` ≠ reviewer `codex` |
| Plan-only auth (no metered API) | ✅ | `auth_mode=chatgpt`; no `OPENAI_API_KEY`/`CODEX_API_KEY` in child env |
| Read-only posture | ✅ | `codex --ask-for-approval never exec --sandbox read-only` |
| Exhaustive review pass | ✅ | bounded "Exhaustive code review" prompt |
| Fail-closed rule honored | ✅ | 0 required-tier findings ⇒ approval eligible; loop 4 refused a findings-bearing approval |
| Local gates green | ✅ | `check_phase_4b_automation` 67/67 · gate (c) clear · 0 unresolved threads · CodeRabbit success · `git diff --check` clean |
| Reviewer CLI version | ✅ | `codex/0.137` (#586) |

### Findings and disposition

| Finding | Severity | Location | Summary | Scope | First loop | Last seen | Disposition | Fix commit / issue |
|---|---|---|---|---|---:|---:|---|---|
| F1 | P2 | — | Codex `--output-schema` vs jq validator drift (`line` min) | current-head | 3 | 3 | deferred-to-follow-up | #585 |
| F2 | P2 | — | Record reviewer CLI version before enablement | current-head | 3 | 3 | deferred-to-follow-up | #586 |
| F3 | P3 | — | Harden Claude JSON extraction beyond first/last brace | current-head | 3 | 3 | deferred-to-follow-up | #587 |
| F4 | P3 | — | Make local shellcheck absence more visible | current-head | 3 | 3 | deferred-to-follow-up | #588 |

Unique findings across loops: 4 — 4 on the approved head, 0 historical (earlier loops only). Repeated across loops: 0. (Scope is derived per finding: `current-head` only when it was last seen on a loop that reviewed the final head sha; a finding last seen on a prior commit — the changes-requested-then-fixed lifecycle — renders `historical`, never as residual current-head risk. Summary is the first body line truncated to 80 chars; full bodies stay in the local loop log, never in the posted block.)

### Cost and effort

| Metric | This approval |
|---|---|
| Reviewer wall-clock | **225 s** across 4 loops (18 + 65 + 66 + 76) |
| Timeout budget | 900 s configured (#589); max single loop 76 s / 900 s = 8% |
| Tokens observed | **177,204 total** (Codex 169,844 total-only; Claude 7,360 = 1,589 in / 5,771 out; loop 4 unavailable) |
| Billed cost | **$0.00** — operator subscription plan |
| Notional API-equivalent | **~$0.66** *(not billed; blended, price table `2026-07-01`)* |
| Plan-capacity throttle events | 1 (Codex plan throttle, early probe) |
| Human shuttle avoided | **~30 min – 3 h** (manual Phase 4b handoff, per `REVIEW_POLICY.md`) |

### Running totals — repo, to date *(illustrative)*

| Metric | Cumulative |
|---|---|
| Auto-approved PRs | 24 |
| Automated attempts (posted + fell-back) | 27 |
| **Auto-approval / fail-closed rate** | **24 / 27 = 89% approved · 11% fail-closed to human** |
| Cumulative wall-clock | 41 min |
| Cumulative tokens | 2.36 M |
| Cumulative notional API-equivalent | ~$9.40 *(not billed)* |
| Cumulative human time saved (est.) | ~12 – 72 h |

*Totals source: github-derived (24 `p4b-accounting:v1` records).*

> Cumulative human-time-saved rendering (#615 Codex round 7): a bound below one hour renders in minutes, never floored to `~0 h`. Both bounds ≥ 60 min keep the shared-unit `~A – B h` form shown above; a sub-hour low bound switches to per-bound units — e.g. a single prior approval (`[30, 180]`) renders `~30 min – 3 h` (the documented 30-minute floor, matching the per-loop "Human shuttle avoided" line), and `[30, 50]` renders `~30 – 50 min`.

### Safety and value notes

- Fail-closed events: **1** (loop 4, approval-carried-findings, 76 s) — prevented an unsafe auto-approval. ✅
- Required-severity (P0/P1) defects fixed before approval: 0 (none found).
- Advisory follow-ups filed: 4 (#585–#588).
- Total adapter tokens observed: 177,204. Total reviewer wall-clock: 225 s.
- Verdict: a real cross-agent review ran on the merged commit, on-plan and read-only, found nothing blocking, and displaced ~30 min–3 h of human shuttling at $0 billed / ~$0.66 notional.

```
<!-- p4b-accounting:v1
{"schema":"p4b-accounting/v1","pr":580,"final_head_sha":"d05ff4d0…","final_verdict":"APPROVED","final_reviewer":"nathanpayne-codex","final_direction":"claude->codex","automation_state":"dry-run","wall_time_first_loop_to_approval_seconds":225,
 "loops":[
  {"loop":1,"reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"direct-probe","fell_back":false,"elapsed_seconds":18,"tokens":{"total":55926,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":1,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":2,"reviewer":"nathanpayne-codex","adapter":"orchestrator-dry-run","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"dry-run","fell_back":false,"elapsed_seconds":65,"tokens":{"total":113918,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":0,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":3,"reviewer":"nathanpayne-claude","adapter":"review-via-claude.sh","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"APPROVED_WITH_ADVISORIES","posted":"direct-probe","fell_back":false,"elapsed_seconds":66,"tokens":{"total":7360,"input":1589,"output":5771,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"claude-json"},"findings":{"P0":0,"P1":0,"P2":2,"P3":2,"nitpick":0,"unknown":0},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":4,"reviewer":"nathanpayne-claude","adapter":"orchestrator-dry-run","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"CHANGES_REQUESTED","posted":"not-posted","fell_back":true,"elapsed_seconds":76,"tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"},"findings":{"P0":0,"P1":0,"P2":null,"P3":null,"nitpick":null,"unknown":null},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":true,"reason":"approval-carried-findings","duration_seconds":76}}
 ],
 "unique_findings":[
  {"id":"F1","severity":"P2","path":null,"line":null,"title":"Codex `--output-schema` vs jq validator drift (`line` min)","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":585},
  {"id":"F2","severity":"P2","path":null,"line":null,"title":"Record reviewer CLI version before enablement","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":586},
  {"id":"F3","severity":"P3","path":null,"line":null,"title":"Harden Claude JSON extraction beyond first/last brace","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":587},
  {"id":"F4","severity":"P3","path":null,"line":null,"title":"Make local shellcheck absence more visible","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":588}
 ],
 "totals":{"adapter_invocations":4,"tokens_total":177204,"tokens_by_provider":{"codex":169844,"claude":7360},"elapsed_seconds_total":225,"billed_usd":0.0,"notional_usd":0.66,"reported_cost_usd":null,"price_table_version":"2026-07-01","fail_closed_events":1,"advisory_issues_filed":[585,586,587,588]},
 "running_totals":{"source":"github-derived","records":24,"auto_approved_prs":24,"automated_attempts":27,"fail_closed_events":3,"tokens_total":2360000,"notional_usd":9.40,"human_minutes_saved_estimate":[720,4320]},
 "generated_at":"2026-07-01T16:24:01Z"}
-->
```

---

## Data-source map

| Datum | Source |
|---|---|
| verdict, summary, findings[], usage | adapter stdout (`verdict.schema.json`) |
| head SHA, reviewer, author agent, direction, posted/dry-run/fell-back | orchestrator run context |
| elapsed, timeout, effort | orchestrator bounded-exec timer + configured values (#589) |
| tokens (total/in/out) | verdict `usage`; Codex stderr `tokens used`; Claude `--output-format json` envelope |
| cache / reasoning tokens, `total_cost_usd` | Claude JSON envelope (extend `usage`) |
| plan-auth posture, throttle events | pre-run `codex login status` / `claude auth status --json`; adapter stderr classification |
| gate results | `check_phase_4b_automation`, `codex-review-check.sh`, `resolve-pr-threads.sh --list`, `coderabbit-wait.sh`, `git diff --check` exit states |
| reviewer CLI version | `codex --version` / `claude --version` pre-run (#586) |
| fix-commit / issue links | orchestrator-filed follow-ups; commit trailers referencing finding ids |
| notional $ | tokens × versioned price table |
| running totals | aggregation of prior `p4b-accounting:v1` blocks (github-derived) or ledger cache |
| human-minutes-saved | fixed cited constant (`REVIEW_POLICY.md` § Phase 4b Triggers) |

## Data-integrity and fail-closed rules

- Accounting generation never blocks or fabricates an approval; on error, post the plain summary.
- **No estimated tokens.** Missing counts render `unavailable` with source/reason.
- **No green rigor checks without a captured signal.** Unverifiable rows render `n/a`.
- A required-tier (P0/P1) finding can **never** accompany a posted `APPROVED` — assert and fail closed.
- Totals degrade to `unavailable` rather than guessing.
- Machine-readable block uses explicit `null` / `"unavailable"`, never silent omission; schema-versioned (`p4b-accounting/v1`).
- The embedded payload is HTML-comment-safe: any `-->` / `--!>` / `<!--` sequence inside a record string (e.g. a hostile finding title) is emitted with its angle bracket as a JSON unicode escape — identical parsed value, but the hidden comment can never terminate early (visible render) or truncate extraction.

## Acceptance criteria

1. A Phase 4b run with multiple adapter attempts produces a complete **per-loop** ledger; the final approval body embeds/references the accounting automatically.
2. Exact severity counts per loop **and** for the final unique-finding set; current-head unique findings distinguished from repeated/stale.
3. Token counts recorded whenever the CLI exposes them; missing token/internal-turn data represented explicitly as `unavailable` with source/reason — never estimated.
4. Cost section shows billed `$0.00` (plan) **and** labeled notional API-equivalent, plus wall-clock, throttle events, and human-time-saved.
5. Running totals computed at post time from prior `p4b-accounting:v1` records (github-derived) with ledger-cache fallback and an explicit totals-source footer; aggregation failure degrades gracefully.
6. Fail-closed loops are counted and described as positive safety evidence, not hidden.
7. Findings that become GitHub issues are linked; fixes link to commits when available.
8. Every rigor row is backed by a captured signal; unverifiable rows render `n/a`.
9. The embedded JSON validates against a committed `scripts/phase-4b/accounting.schema.json` and round-trips through the aggregator.
10. Merge gate, merge-clearance gate, and auto-clear workflow are **byte-unchanged**.
11. Ships behind `phase_4b_automation.enabled` (false) + `phase_4b_automation.accounting.enabled`; defaults leave current behavior unchanged.
12. **Tests** cover: zero-finding approval; approval with advisory findings; changes-requested-then-fixed; fail-closed invalid/findings-bearing verdict; missing token metadata; repeated finding across loops; notional-cost math incl. missing price; totals aggregation over N fixture records; report-generation-error → plain-summary fallback (never fabricates approval).
13. Docs explain how a product/finance operator interprets the block. `./scripts/ci/check_phase_4b_automation` and the new check pass; new check wired into `repo_lint.yml`; new files registered in `.mergepath-sync.yml`.

## Non-goals

- No merge-gate, branch-protection, or `gh-as-reviewer.sh` identity changes.
- No CI-runner execution mode (local-first, like the parent feature).
- No live dashboard — only the embedded machine-readable block a future dashboard could read.
- No change to reviewer selection, adapter review logic, or the verdict contract beyond the additive nullable `usage` cache/reasoning fields.

## Deliverables

- `scripts/phase-4b/accounting.sh` — the loop-ledger builder + block renderer (sourced by the orchestrator; unit-testable in isolation).
- `scripts/phase-4b/accounting.schema.json` — schema for the `p4b-accounting:v1` record.
- `scripts/phase-4b/prices.json` (or `review-policy.yml` price map) — versioned notional-cost rates.
- Additive nullable `usage` fields (`cache_creation_input_tokens`, `cache_read_input_tokens`, `reasoning_tokens`, `total_cost_usd`) in `verdict.schema.json`, CLI-sourced only.
- Orchestrator hook in `scripts/phase-4b-review.sh`: accumulate per-loop records, build the approval body via `accounting.sh`, fall back to plain summary on error.
- `phase_4b_automation.accounting` block in `.github/review-policy.yml` (documented; `enabled: true` under the disabled parent; optional `prices`).
- Tests `tests/test_phase_4b_accounting.sh` + `scripts/ci/check_phase_4b_accounting`, wired into `repo_lint.yml`; register new files in `.mergepath-sync.yml`.
- Docs: new § in `plans/automated-phase-4b-handoff.md`, plus `scripts/phase-4b/README.md` and `REVIEW_POLICY.md` § Phase 4b.

## Related

#579 · #580 (parent) · #585 #586 #587 #588 (advisory follow-ups this accounting must link) · #586 (CLI-version evidence integration) · #589 (configurable effort/timeout, closed — record configured values) · #574 (feedback policy).

---

# PART 2 — post as a comment on #602

## Reconciliation: what this spec keeps from the ticket vs. the #580 report work

I merged the original ticket with the consolidated-report spec I drafted off the #580 thread. Point-by-point:

**Adopted from the original ticket (better than the report framing):**

- **Loop-centric recording** — record every adapter attempt, not just the final approval. This is the stronger frame and it dissolves an open question the report spec had flagged: advisory findings from non-final loops (e.g. the Claude direction's P2×2/P3×2) are now captured as loop history even though the posted approval is clean, so rigor is visible *without* loosening the strict "approve only on zero findings" posting rule.
- **Findings-disposition lifecycle** — fixed / rebutted / deferred / accepted-risk / false-positive / unresolved, with fix-commit and follow-up-issue links.
- **Current-head-unique vs repeated/stale** finding distinction across loops.
- **Fail-closed events as positive safety evidence** (reason + duration), counted, not hidden.
- **Finance stakeholder** as an explicit consumer.
- **Severity superset** `{P0,P1,P2,P3,nitpick,unknown}` for the accounting layer (the verdict contract stays P0–P3; nitpick/unknown absorb CodeRabbit/Codex-bot/other sources).
- **Manual old-style handoff** coverage when data is collectable.

**Adopted from the report spec (fills gaps the ticket left open):**

- **Posting decision resolved** — the accounting *is* the `APPROVED` review body (reusing the orchestrator's HEAD-pinned pull-review POST), and generation is fail-open: on error, post the plain summary; never block or fabricate an approval. The ticket left "approval body or a PR comment" open.
- **Cost model** — the ticket asks "was it worth the cost" but doesn't address that plan-only billing makes the **billed** marginal cost `$0`. So the spec reports billed `$0.00` **plus** a clearly-labeled **notional** API-equivalent, **wall-clock** (the real scarce resource), and **plan-capacity/throttle events**, paired with **human-time-saved**. That's the actual answer for the finance stakeholder.
- **Rigor-as-proof-of-work** — for a zero-finding approval, "rigor" can't be "bugs caught," so the rigor table is proof-of-work (exhaustive pass + time + tokens + read-only + plan-auth + CLI version + gates green) to separate *reviewed hard* from *rubber-stamped*.
- **Inline running totals** computed **statelessly** from prior embedded `p4b-accounting:v1` blocks (github-derived, ledger-cache fallback) — this operationalizes the ticket's "aggregate across PRs" goal with no state file to drift.
- **Data-source map, data-integrity rules, and grounded deliverables** — exact file names, exit codes, CI wiring (`repo_lint.yml` + `check_ci_scripts_wired`), and `.mergepath-sync.yml` registration.

**One decision worth a second look:** the strict posting rule (approve only on zero findings) means a *posted* approval's Findings table is normally all-zeros, with advisories showing up only in the loop history / prior loops. If you'd rather a single approval be able to post *with* advisories attached (and auto-file them), that loosens the safety posture — I kept the strict rule and captured advisories via loop history instead. Flag if you want the looser posture.
