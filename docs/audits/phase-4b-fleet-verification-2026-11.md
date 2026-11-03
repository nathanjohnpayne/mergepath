# Automated Phase 4b fleet verification (#2666), 2026-11

This is the verification report that closes out the evidence side of epic [#2657](https://github.com/nathanjohnpayne/mergepath/issues/2657) (fleetwide automated Phase 4b with bounded reviews). It is a dated snapshot, not a policy: `REVIEW_POLICY.md`, `AGENTS.md`, `specs/phase_4b_round_cap.md` and the scripts win on any divergence.

It reuses the per-repository evidence in the [#2665 verification comment](https://github.com/nathanjohnpayne/mergepath/issues/2665#issuecomment-6596287004) and re-verifies what may have moved since. Nothing was written to any repository or ref, no live review was dispatched and no hold was bypassed to obtain evidence.

## What was verified against

| Item | Value |
| --- | --- |
| Hub `main` for the re-verification | `c6e146fe2a88080c5e835669227df79f5726bec1` (includes #2966, the CodeRabbit serialization fix) |
| Hub `main` that #2665 verified | `a98f0c90`, with the Phase 4b blobs read at `6affb8da` |
| Sync source every consumer installed | `mergepath@6affb8d` (`6affb8da`, merged 2026-11-03T00:00Z to 01:42Z) |
| Live read date | 2026-11-03 |
| Test run | the hub worktree at `c6e146fe`, no local modification of any script under test |

Hub `main` moved after the consumers synced. The nine Phase 4b files named below are byte-identical between each consumer's `main` and hub `c6e146fe` (git blob SHAs compared on all eight repositories), so the move did not change any installed Phase 4b code. Other files that changed on the hub since `6affb8da` are outside this report's scope and are not claimed installed.

## Four states, kept distinct

No row below infers one state from another. A merged source change does not prove an install, an install does not prove the configuration, and a correct configuration does not prove that the path has run.

- **Source merged**: the change is on hub `main`.
- **Consumer installed**: the consumer's `main` holds byte-identical Phase 4b files.
- **Configuration effective**: the governing `.github/review-policy.yml` on the default branch sets the values.
- **Operational acceptance**: live evidence that the installed code ran, such as ledger refs and the reviews they account for.

### Source merged

| Capability | Issue | Merged by | Evidence of source |
| --- | --- | --- | --- |
| CodeRabbit rate-limit to Codex failover acceptance cases | [#2661](https://github.com/nathanjohnpayne/mergepath/issues/2661) | #2660 | `tests/test_codex_review_request_trigger_only.sh` `test_failover_marker`, `tests/test_coderabbit_wait_codex_failover.sh` |
| Five-request Codex checkpoint | [#2662](https://github.com/nathanjohnpayne/mergepath/issues/2662) | claude/2657-codex-checkpoint | `tests/test_codex_review_request_trigger_only.sh` `test_request_checkpoint` |
| Three-round Phase 4b cap through a Git-ref round ledger | [#2663](https://github.com/nathanjohnpayne/mergepath/issues/2663) | #2713 (`b99ae012`) | `tests/test_phase_4b_round_cap.sh` |
| Codex run reporting and same-head hold, narrowed to no automatic retry | [#2664](https://github.com/nathanjohnpayne/mergepath/issues/2664) | #2779 (`76ce0509`); #2716 (`501fac13`) added a retry that #2779 then removed | `tests/test_codex_review_request_ack.sh` |
| Per-PR claim around the Codex count-and-post | [#1362](https://github.com/nathanjohnpayne/mergepath/issues/1362) | #2715 (`629df81f`) | `tests/test_gh_comment_trigger_guard.py`, `tests/test_codex_review_request_ack.sh` |
| Fleet policy values | [#2665](https://github.com/nathanjohnpayne/mergepath/issues/2665) | one config PR per repository (below) | the policies read below |

The #2664 outcome is the narrowed scope the owner recorded on 2026-10-22 and #2779 delivered. There is no automatic retry. The 300 s diagnostic and the 1800 s report are reporting only (`codex_run` in the requester JSON). An unanswered request takes the existing timeout handoff, and a polling run, including a restarted one, holds the latest strongly tied unanswered request instead of posting a second beside it. Nothing in this report claims a retry exists.

### Consumer installed

The last merged sync PR on each consumer, and a blob comparison of nine Phase 4b files against hub `c6e146fe` (read from each consumer's `main`):

`scripts/phase-4b-review.sh`, `scripts/phase-4b/lib.sh`, `scripts/post-phase-4b-handoff.sh`, `scripts/phase-4b/README.md`, `scripts/phase-4b/adapters/review-via-codex.sh`, `scripts/phase-4b/adapters/review-via-claude.sh`, `scripts/gh-as-reviewer.sh`, `scripts/codex-review-request.sh`, `tests/test_phase_4b_round_cap.sh`.

| Repository | Last merged sync PR | Source named by that PR | Blobs matching hub `c6e146fe` |
| --- | --- | --- | --- |
| mergepath | canonical | `main` | 9 of 9 |
| matchline | matchline#676 | `mergepath@6affb8d` | 9 of 9 |
| nathanpaynedotcom | nathanpaynedotcom#1533 | `mergepath@6affb8d` | 9 of 9 |
| overridebroadway | overridebroadway#276 | `mergepath@6affb8d` | 9 of 9 |
| friends-and-family-billing | friends-and-family-billing#592 | `mergepath@6affb8d` | 9 of 9 |
| swipewatch | swipewatch#223 | `mergepath@6affb8d` | 9 of 9 |
| tadlockpsychiatry | tadlockpsychiatry#210 | `mergepath@6affb8d` | 9 of 9 |
| fiveacross | fiveacross#2007 | `mergepath@6affb8d` | 9 of 9 |

`specs/phase_4b_round_cap.md` is hub-only and is not synced. Checkouts on other machines and in cloud sessions cannot be verified from here; the installed column describes each repository's `main`, not every checkout a session might run from.

### Configuration effective

Values read from each default-branch `.github/review-policy.yml` on 2026-11-03 and parsed as YAML. All eight repositories are identical on these keys.

| Key | Value in all eight |
| --- | --- |
| `codex.max_review_rounds` (the per-PR request ceiling) | 10 |
| `codex.max_blocking_reviews` (the blocking-review budget) | 10 |
| `codex.review_timeout_seconds` | 1800 |
| `phase_4b_automation.enabled` | true |
| `phase_4b_automation.max_review_rounds` (the completed-round cap) | 3 |
| `phase_4b_automation.mode` | local |

The config PRs, from #2665: mergepath #2702, matchline#605, nathanpaynedotcom#1450, overridebroadway#252, friends-and-family-billing#574, swipewatch#204, tadlockpsychiatry#199, fiveacross#1980. No config PR changed the external-review threshold, protected paths or routing. The `fail_closed: true` key added on overridebroadway and swipewatch is not read by the orchestrator.

### Operational acceptance

Ledger refs under `refs/mergepath/p4b-rounds/` on 2026-11-03, read separately from the #2665 reading and unchanged in count:

| Repository | Ledger refs | Operational acceptance |
| --- | ---: | --- |
| mergepath | 35 | Observed. PRs #2660 to #2933; 32 tips written by nathanpayne-codex and 3 by nathanpayne-claude (from #2665). |
| swipewatch | 8 | Observed (pr-154 to pr-223). |
| nathanpaynedotcom | 2 | Observed (pr-1450, pr-1538). |
| fiveacross | 2 | Observed (pr-1980 with three entries, pr-1996). |
| matchline | 0 | Configured and installed, not yet observed. |
| overridebroadway | 0 | Configured and installed, not yet observed. |
| friends-and-family-billing | 0 | Configured and installed, not yet observed. |
| tadlockpsychiatry | 0 | Configured and installed, not yet observed. |

"Observed" means a ledger write by the existing reviewer-wrapper path exists. It does not mean every Phase 4b review in that repository went through the ledger (see the disclosures). On the four zero-ref repositories no automated round has run since the cap took effect, so a ledger write there is untested; it was not forced, by design. #2665 found both reviewer identities hold `push` in all eight repositories and no rulesets, so no permission is missing.

## Verification matrix for the #2663 and #2664 boundaries

Run on hub `c6e146fe`. Every suite below passed with no failure (totals in [Test runs](#test-runs)). The "expected" and "observed" columns are the same fact checked two ways: the expectation is what `REVIEW_POLICY.md` § Disagreements and Tiebreaking states, the observation is what the named test asserts and recorded on this run. A case marked "gap" has no dedicated test, and this report says so instead of inferring coverage.

| # | Boundary | Expected stop or routing | Observed on this run | Test file and case |
| --- | --- | --- | --- | --- |
| 1 | Request ceiling, 9 of 10 counted requests | One more request is permitted (exit 0, one post) | Pass | `tests/test_codex_review_request_trigger_only.sh`, `test_request_attempt_cap`, scenario `cap_below_limit` |
| 2 | Request ceiling, 10 of 10 | Request refused, exit 7, `cap_exhausted.kind: "request-ceiling"`, no post | Pass | same, scenario `cap_at_limit` |
| 3 | Request ceiling, 11 | Refused like 10 | Gap: no 11-request fixture. `cap_duplicate_ids` seeds 12 comments with 9 distinct ids and permits the request, which proves duplicates do not consume slots, not an over-limit refusal | same, `cap_duplicate_ids`; malformed record fails closed in `cap_bad_id` (exit 3) |
| 4 | Blocking budget 9 of 10 | One more request permitted | Pass | same file, `test_blocking_budget_boundary` (n = 9) |
| 5 | Blocking budget 10 and 11 | Refused, exit 7, `kind: "blocking-reviews"`, no post | Pass | same, `test_blocking_budget_boundary` (n = 10, 11) |
| 6 | Counting rule | Unsolicited, discretionary, clean, no-findings and provider-block responses do not count; unknown-tier and conflicting responses do | Pass | same, `test_blocking_budget_counting_rule` |
| 7 | Simultaneous exhaustion (both budgets spent) | The blocking-budget stop names the stop, and the spent ceiling is also reported | Pass | same, `test_blocking_budget_wins_simultaneous_exhaustion` |
| 8 | Request ceiling spent, blocking budget not spent | Cost exhaustion, not runaway: `kind: "request-ceiling"`, routed through the Phase 4b barrier | Pass | same, `test_blocking_budget_wins_simultaneous_exhaustion` (ceiling-only half); `tests/test_phase_4b_automation.sh` section "#1560 slice 3, S3-4" (label "ceiling-clear-not-waived"): a spent ceiling with no human stop opens the barrier with `codex: "waived"` |
| 9 | True runaway | At a spent ceiling, every allowed request drew a blocking review that was not all fixed, blocking count below budget: `runaway` stop, exit 8 (human tiebreaker), no adapter dispatch | Pass | `tests/test_codex_review_ledger.sh` check "stops: two blocking reviews at a request ceiling of 2 under a budget of 10 are a runaway"; `tests/test_phase_4b_automation.sh` label "runaway-at-ceiling-waived" |
| 10 | Proven-fixed history | A round whose blocking findings were all proven fixed leaves the runaway count only; the spent ceiling then waives the Codex arm | Pass | `tests/test_codex_review_ledger.sh` check "fixed: a fixed, unre-raised finding is no runaway window"; `tests/test_phase_4b_automation.sh` label "runaway-with-fixed-round-not-waived" |
| 11 | Proven-fixed still spends the blocking budget | The fixed response still counts toward `max_blocking_reviews` | Pass | `tests/test_codex_review_ledger.sh` check "fixed: the blocking budget still counts the fixed response" |
| 12 | Malformed or unreadable fixed evidence | Counts as not fixed (keeps the runaway); unreadable stop evidence exits 10 | Pass | `tests/test_codex_review_ledger.sh` checks "fixed: an unreadable round time proves nothing" and "fixed: a ledger without fixed-finding evidence counts every round"; `tests/test_phase_4b_automation.sh` section S3-4, modes `fail`, `garbage`, `other-head` |
| 13 | Valid exact-head owner runaway tiebreak | Clears only the runaway, only on that head; approves nothing, refunds nothing; the head still goes to the Phase 4b adapter | Pass | `tests/test_codex_review_ledger.sh` check "runaway tiebreak: an owner runaway marker clears the runaway"; `tests/test_phase_4b_automation.sh` label "runaway-owner-marker-not-waived" (inverse assertion: the marker opens the barrier with `codex: "waived"`, not an approval) |
| 14 | Tiebreak does not refund the blocking budget | A runaway marker leaves `blocking-budget` standing | Pass | `tests/test_codex_review_ledger.sh` check "runaway tiebreak: a runaway marker leaves blocking-budget standing" |
| 15 | Stale or invalid owner decision | Another account, an edited comment, a marker older than the last request or response, another head, another PR, a finding suffix, a quoted or prose marker: none clear the stop | Pass | `tests/test_codex_review_ledger.sh` cases "runaway tiebreak: ... does not clear the runaway" (twelve variants) and "tiebreak: ... does not clear the stop"; `tests/test_phase_4b_automation.sh` label "runaway-stale-owner-marker-waived"; `tests/test_gh_comment_trigger_guard.py` `test_owner_runaway_marker_is_refused_for_every_role_and_channel` and `test_owner_tiebreak_marker_is_refused_for_every_role_and_channel` (agents cannot post a filled-in marker) |
| 16 | Fourth Phase 4b round | With 3 of 3 completed rounds, refused: exit 8, `round_cap.state: "spent"`, no ledger write | Pass | `tests/test_phase_4b_round_cap.sh` P2 ("3/3 completed -> the fourth round is refused") |
| 17 | Fourth round while a slot is in flight | A competing run holds (exit 6) and takes no slot | Pass | `tests/test_phase_4b_round_cap.sh` P3 |
| 18 | A surplus publication | Two reviews under one reserved run id occupy two slots; the cap stays spent | Pass | `tests/test_phase_4b_round_cap.sh` P19 |
| 19 | Owner tiebreak against a spent round cap | The marker grants no fourth round | Gap: no test combines a valid runaway marker with a spent `max_review_rounds`. By construction the round cap counts ledger reservations and completed reviews and never reads the tiebreak, but this report does not claim a test proves it | `tests/test_phase_4b_round_cap.sh` P2 proves the refusal without a marker |
| 20 | Failover deduplication | The CodeRabbit failover trigger carries one author-owned marker, exempts at most one trigger per head from the ceiling, and a foreign, late or malformed marker leaves the trigger counted; the response still counts toward the blocking budget | Pass | `tests/test_codex_review_request_trigger_only.sh` `test_failover_marker`; `tests/test_codex_review_ledger.sh` checks "stops: a failover request is not a runaway window" and "stops: the failover response still counts toward the blocking budget"; `tests/test_phase_4b_automation.sh` labels "failover-ceiling-read" and "failover-forced-ceiling-read"; `tests/test_coderabbit_wait_codex_failover.sh` |
| 21 | Late evidence at the publication fence | A review that commits after the client times out and becomes visible late is neither double-counted nor lost; an uncertain POST stays occupied and is not reposted | Pass | `tests/test_phase_4b_round_cap.sh` P12 and P13 |
| 22 | Changed head | A head change does not reset the count; a changed or unreadable budget snapshot refuses with exit 10 | Pass | `tests/test_phase_4b_round_cap.sh` P17; `tests/test_phase_4b_automation.sh` section S3-4 mode `other-head` and the case "A base retarget/advance with an unchanged head invalidates the cap read" |
| 23 | Active or unknown Codex run | Reported only (`codex_run.diagnostic` at 300 s, `final_state` at 1800 s); an old placeholder or elapsed time never proves a run active or inactive; nothing is retried, canceled or cleared; the request takes the timeout handoff (exit 4) | Pass | `tests/test_codex_review_request_ack.sh` `test_codex_run_diagnostic_and_report` (cases `active`, `stale-placeholder`, `unknown-status`, `failed`) |
| 24 | Overlapping or superseded request | An overlap reads `ambiguous`; a request superseded by a newer one records no marker, posts nothing and exits 3 with `handoff: "superseded"` | Pass | same file, `test_overlapping_requests_are_ambiguous`, `test_newer_request_supersedes_the_waited_on_one` |
| 25 | Same-head hold and restart | A restarted polling run holds the latest strongly tied unanswered request instead of posting beside it; a weak tie mints no timeout marker; with no tie it posts a new counted request | Pass | same file, `test_weak_tie_mints_no_timeout`, `test_round4_head_tie_edges`, `test_resume_*` family (for example `test_resume_running_request_posts_nothing`, `test_expired_rerun_never_resumes`) |
| 26 | No automatic retry chain | An uncertain, already-retried or delayed-claim rerun is held; none posts a second request | Pass | same file, `test_uncertain_publication_is_held_on_rerun`, `test_already_retried_request_is_held`, `test_delayed_claim_then_rerun_holds` |

## Ledger and version evidence

The ledger is a hidden per-PR Git ref whose tip commit holds a `p4b-round-ledger/v1` document. Representative tips, read on 2026-11-03 (run ids shortened):

| Repository and PR | Tip author | Entries |
| --- | --- | --- |
| mergepath#2887 | nathanpayne-codex | `p4b-dfbe97a4` released, `p4b-5e5ab9c4` reserved, `p4b-5b1b0025` reserved, `p4b-84cd532b` reserved (3 counted rounds) |
| mergepath#2933 | nathanpayne-codex | 1 released, 1 reserved |
| mergepath#2716 | nathanpayne-codex | 2 released, 1 reserved |
| nathanpaynedotcom#1538 | nathanpayne-codex | 1 released, 1 reserved |
| nathanpaynedotcom#1450 | nathanpayne-codex | 1 reserved |
| fiveacross#1980 | nathanpayne-codex | 1 released, 2 reserved |
| fiveacross#1996 | nathanpayne-codex | 1 reserved |
| swipewatch#223 and #154 | nathanpayne-codex | 1 reserved each |

The publisher version in all eight repositories is the orchestrator block `BEGIN/END p4b_round_cap` in `scripts/phase-4b-review.sh` at the blob SHAs matched above. The cross-check in #2665 (every automated Phase 4b review posted since 2026-10-21 that carries a run marker, 394 PRs scanned) found all 72 reviews under an enforced cap in the PR's ledger, and 7 marker-bearing reviews without a ref that ran while the base policy had no 4b cap (the config PRs and friends-and-family-billing#569 and #572). That scan was not repeated here; the ref counts and tips above were.

### Initialization evidence

Existing completed rounds are counted and no fresh budget is granted. `tests/test_phase_4b_round_cap.sh` P1 starts from two legacy completed reviews and a cap of 3, and the run reserves the third slot on a newly created ref with `round_cap.occupied: 2`. Pure counting (`p4b_completed_rounds_from_reviews`) does not depend on the current `available_reviewers`, and P2 starts from 3 legacy completed reviews with no ledger and refuses. P14 refuses an ambiguous ledger and P15 fails closed on unreadable or malformed evidence.

### Publisher coverage

| Publisher | Posts a Phase 4b review | Participates in the ledger |
| --- | --- | --- |
| `scripts/phase-4b-review.sh` (orchestrator, `mode: local`), directly, through `scripts/wave-audit.sh` or through `scripts/workflow/resume-stalled-pr.sh` | yes | yes: reserves before dispatch, binds the slot before the POST |
| The #2633 admin override (a flag on the same orchestrator, #2644) | yes | yes: the round-cap call is not conditioned on it |
| Manual handoff (`scripts/post-phase-4b-handoff.sh` renders it; a human or reviewer session posts the verdict through `scripts/gh-as-reviewer.sh`) | yes, by design | no: its reviews lack the automated header, footer and run marker |
| A reviewer session running an adapter directly and posting under its own identity | yes | no (see disclosure a) |

No workflow invokes the orchestrator. Enforcement covers participating writers only. This report does not claim fleetwide enforcement, and the repository's own rule, from the adopted design, is that the hidden ref is organizational state, not an access-control boundary: anyone who can push can rewrite it, just as anyone with a reviewer credential can post a review.

### Concurrency and recovery results

Each result is linked to the test that proves it, all in `tests/test_phase_4b_round_cap.sh` against a stateful fake GitHub whose compare-and-swap is atomic:

| Result | Case |
| --- | --- |
| Competing last-slot claims: five concurrent callers, one remaining slot, exactly one wins | P8 |
| Ten concurrent callers on an empty PR with cap 3: exactly three reserve | P9 |
| Initialization race on ref creation (create-if-absent) | P1, P4 |
| Rejected stale-parent update, then a fresh read and full re-evaluation | P4, P5 |
| Delayed reads (stale ref read; a review visible only after N reads) | P5, P13 |
| Lost write response, both a write that committed after the client timed out and one that never applied | P6, P7 |
| Duplicate invocation ids refused | P14, P10 |
| Restarts and persistence across heads | P17, P3 |
| Late completion of a review POST, never reposted and never double-counted | P12, P13 |
| The owning writer's release only before any POST attempt; after an attempt the slot stays occupied | P11, P12 and the #2790 case |
| Ledger release read failing from the EXIT trap only warns | P18 |

### Permission blockers

None found. Under the merged code the ledger is written by the run's actual reviewer through `scripts/gh-as-reviewer.sh` (nathanpayne-codex by default, nathanpayne-claude when Codex authored the PR). Both identities hold `push: true` (and neither holds `admin` or `maintain`) in all eight repositories, and no ruleset exists. No permission expansion is requested.

## #1362: the Codex requester count-and-post race

**Status: remediated at one layer, with a disclosed cross-machine limit.** #1362 is closed through #2715. It is a separate fix from the Phase 4b round ledger and from #2664's single-request hold, and no result here is evidence for either of the others.

- **What is fixed.** The author wrapper's comment guard takes an exclusive per-PR claim before the authorization recount and holds it through the comment POST and the readback of the posted comment id. A second guarded requester posts nothing and exits 3 naming the request that posted first. Proven by `tests/test_gh_comment_trigger_guard.py` `test_claim_lets_exactly_one_of_two_held_wrappers_post`, `test_claim_fails_closed_before_the_recount`, `test_claim_covers_the_rest_transport`, `test_claimed_write_requires_its_confirmed_comment_id`, `test_surviving_post_child_keeps_the_claim`, and `tests/test_codex_review_request_ack.sh` `test_real_wrapper_claim_lets_one_of_two_requesters_post` (trigger-only and polling modes) and `test_real_wrapper_staggered_requester_refuses`.
- **Host-local.** The claim is a kernel lock file under `MERGEPATH_CODEX_REQUEST_CLAIM_DIR` (default `${XDG_STATE_HOME:-~/.local/state}/mergepath/codex-request-claims`). Requesters on two machines or runners are not serialized against each other. `REVIEW_POLICY.md` § Disagreements and Tiebreaking, signal 4 discloses this, and it remains a residual.
- **Out-of-band requests.** A request typed directly (for example in the GitHub web UI) takes no part in the claim and cannot be prevented. It is counted afterward, because the PR timeline is the budget store. `tests/test_gh_comment_trigger_guard.py` `test_out_of_band_request_is_counted_never_blocked` records that behavior.
- **What is not claimed.** The Phase 4b ledger does not close this race, and #2664's no-retry design does not either. This report does not claim fleetwide atomic cap enforcement.

## Explicit disclosures

**(a) A direct-adapter bypass was observed on mergepath#2887.** The orchestrator reached 3 of 3 and refused a fourth round. Its ledger holds 4 entries (1 released, 3 reserved), so the counter reads 3 rounds. After that, nathanpayne-codex posted three reviews outside the ledger:

- 5708426049 (CHANGES_REQUESTED, 2026-10-30T05:28Z): headed "Direct Phase 4b review", "one direct run of the trusted Codex reviewer adapter outside the spent automated Phase 4b round cap, at the owner's direction".
- 5708737325 (DISMISSED, 2026-10-30T06:17Z) and 5715831233 (APPROVED, 2026-10-30T17:04Z): both headed "Automated Phase 4b review ... direct adapter run", the second stating it was run directly "because the orchestrator's 3/3 Phase 4b round cap is spent".
- None carries a run marker or the orchestrator footer. The owner authorization appears only as a quotation inside the review bodies ("use an automated 4b", "go"), and #2665 found no owner comment on the PR thread recording it. A fourth, empty-bodied COMMENTED review (5708372637) also has no marker and carries no verdict.
- Nothing in the guard path prevents a reviewer session from posting that header under its own identity.

**(b) The manual handoff path posts outside the ledger by design.** It is human-mediated, its reviews lack the automated header, footer and run marker, and so they are neither counted nor capped.

**(c) #1362's claim is host-local.** Cross-machine requesters, and out-of-band web UI requests, are not serialized (see above).

**(d) Ledger writes are not yet exercised on four repositories.** matchline, overridebroadway, friends-and-family-billing and tadlockpsychiatry hold zero ledger refs (re-checked 2026-11-03). For them operational acceptance is "configured and installed, not yet observed". The write preconditions hold but a write was not forced.

**(e) Friends & Family Billing's `recordPayment` human-review requirement is preserved.** From #2665: `rules/repo_rules.md` § High-Risk Modification Zones still lists `src/lib/BillingYearService.js` `recordPayment()` and `reversePayment()` as needing explicit human review, friends-and-family-billing#538 keeps its "Merge gate (human review required)" section, and the governing policy states that an automated Phase 4b APPROVED never clears that review. The requirement is enforced by process only, not by branch protection; the `human-hold` label exists there. Enabling the path does not weaken it, and no live review was run on that repository to obtain evidence.

Two further limits, both inherited from the design: the orchestrator version in checkouts on other hosts cannot be verified from here, and a crashed run's slot stays occupied by design (the remedy is an owner decision, never reuse of the slot).

## Test runs

Run from the hub worktree at `c6e146fe`, no script modified. `tests/test_phase_4b_automation.sh` was run unmodified and only as the repository's own suite; no mutation was applied to `scripts/phase-4b/lib.sh`, per `docs/agents/operating-rules.md`.

| Suite | Result |
| --- | --- |
| `tests/test_phase_4b_round_cap.sh` | 71 passed, 0 failed |
| `tests/test_codex_review_request_trigger_only.sh` | 135 passed, 0 failed |
| `tests/test_codex_review_request_ack.sh` | 91 passed, 0 failed |
| `tests/test_codex_review_ledger.sh` | 355 passed, 0 failed |
| `tests/test_codex_request_evidence.sh` | 231 blocked/query cases and carry-forward success passed |
| `tests/test_coderabbit_wait_codex_failover.sh` | 41 passed, 0 failed |
| `tests/test_gh_comment_trigger_guard.py` | OK |
| `tests/test_phase_4b_automation.sh` | 555 passed, 0 failed (about 24 minutes) |
| `scripts/owl-rules-check.py --check` | PASS (19 seeded violations); R-155 is not encoded in `docs/ontology/mergepath-rules.ttl`, so only `rules.md` changed |

## Acceptance of #2666

- **Four states per repository, kept distinct:** met (tables above).
- **Boundary matrix with expected routing, observed result and test evidence:** met, with two named gaps (no 11-request fixture; no test combining a valid owner tiebreak with a spent `max_review_rounds`).
- **Ledger, initialization, publisher coverage, concurrency and recovery, permission blockers:** met; no permission blocker.
- **#1362 reported as remediated at the guarded-path layer, host-local, out-of-band requests only counted:** met.
- **Explicit disclosures (a) to (e):** met.
- **Contract reconciliation of `CONTEXT.md` and `docs/ontology/rules.md` R-155:** met by the same change.
- **Operational acceptance:** partial by design. It is observed in four repositories and "configured and installed, not yet observed" in four. Fleetwide enforcement is not established, because the manual handoff and the #2887 direct-adapter reviews post outside the ledger.
