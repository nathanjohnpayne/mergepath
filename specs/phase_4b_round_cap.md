# Phase 4b round cap (#2663)

`phase_4b_automation.max_review_rounds` caps the completed automated Phase 4b rounds a pull request may receive. `scripts/phase-4b-review.sh` enforces it as a hard cap among participating publishers. The protocol lives in the orchestrator block between `# BEGIN p4b_round_cap` and `# END p4b_round_cap`; its pure helpers live in `scripts/phase-4b/lib.sh`.

## Authority

The cap comes from the pull request's governing base policy (`p4b_governing_policy_json`), so a PR cannot raise its own cap. An absent key leaves the cap unenforced, as before. A present value that is not a positive integer stops the run with exit `10`.

The sole reservation and cap authority is a per-PR Git ref, `refs/mergepath/p4b-rounds/pr-<N>`. Its tip commit carries the whole ledger as one JSON line, `{"schema":"p4b-round-ledger/v1","pr":N,"entries":[{"run","head","state"}]}`, where `state` is `reserved` or `released`. PR comments and repeated API reads are evidence or a consistency check, never coordination. The ref is organizational state, not a secret or an access-control boundary: anyone who can push can rewrite it, as they can post a review.

## Transitions

Every transition creates a commit whose sole parent is the observed tip and then publishes it without force. The message carries the ledger. The tree holds one constant `README` file, because GitHub refuses an empty tree (`{"tree":[]}` is HTTP 422 `Invalid tree info`) and a repository need not hold git's well-known empty tree: `POST git/refs` creates the ref only if it is absent, and `PATCH git/refs` with `force: false` is accepted only as a fast-forward. Of two writers building on one tip, exactly one wins. A rejected update (a non-fast-forward, or a ref that already exists) requires a fresh read and a full re-evaluation of occupancy; a stale transition is never reapplied. A write with an unknown outcome is resolved by reading the tip: it applied exactly when the tip is the commit this run built. History is never reset.

## Counting

`p4b_completed_rounds_from_reviews` first requires every record to be a review object with a numeric id and a string state, so malformed history fails closed instead of reading as empty history. It then counts completed rounds from the PR's reviews: a non-author review whose body opens with `**Automated Phase 4b review**`, carries the `_Posted by scripts/phase-4b-review.sh` footer, and has a verdict state (`APPROVED`, `CHANGES_REQUESTED` or `DISMISSED`). The login is not checked against the current `available_reviewers`, so rotating or removing a reviewer never erases its history. A forged review can only inflate the count, which stops rounds early (a liveness risk), never lets one past the cap. Each round reports the run id it carries: the `<!-- mergepath-p4b-run: <id> -->` marker that sits directly before the footer, where the orchestrator writes it (`p4b_run_marker`). A marker-shaped example quoted earlier in the review text, such as a finding about this ledger, is not the run id.

`p4b_round_occupancy` combines the ledger and the rounds. A slot is occupied by every `reserved` entry, whether consumed or still in flight, and by every completed round that no reserved entry accounts for. That covers legacy reviews from before the ledger, reviews with no run id, and a review by a run whose entry reads `released`. Initializing from existing history therefore grants no fresh budget. A `released` entry frees its slot only while no review carries its run id. A reserved run occupies the larger of its entry count and the number of reviews carrying its id, so duplicate entries each keep a slot and one reservation never absorbs a surplus publication. Completed rounds and in-flight slots are reported separately (`completed`, `in_flight`, `legacy`).

The review read is taken twice and must agree. That is a consistency check against a page shifting mid-read, not a guaranteed snapshot; the cap's atomicity rests on the ledger, not on that read.

## Lifecycle of a round

1. **Reserve before dispatch.** After the provider barrier and the pre-dispatch ceiling check, the run reads the ledger and the rounds. If occupancy has reached the cap, it stops before any adapter run:
   - with exit `8` (`human_tiebreaker_required`, top-level `round_cap.state: "spent"`) when nothing is in flight;
   - with exit `6` (`round_cap.state: "held"`, `retry_after`) when a reserved round is still in flight.

   Otherwise it appends `{run: <invocation id>, head, state: "reserved"}`. The invocation id is the run's `P4B_ACCT_RUN_ID`, and the run refuses with exit `10` if that id is already in the ledger.
2. **Binding check before the POST.** At the writer boundary, the run's entry must still be present exactly once and still `reserved`. A missing, duplicated or edited entry, or an unreadable ledger, stops with exit `10`, and nothing is published. Like every other pre-POST refusal, that stop first undoes the pre-POST side effects: the provisional loop accounting and any approval follow-up issues.
3. **Publish.** The posted review carries `<!-- mergepath-p4b-run: <invocation id> -->` on its own line directly before the footer. From the moment the POST is attempted, the slot stays occupied whatever the outcome.
4. **Reconcile an uncertain POST.** If the POST call fails, `p4b_reconcile_posted_review` adopts a landed review only when exactly one review by the actual reviewer, on the exact head, carries this run's id. If none or several match, nothing is adopted and nothing is reposted, and the slot stays occupied.

The writer runs the unchanged strict comment-payload guard locally before marking transport attempted (#2790). A definitive local refusal performs the usual pre-POST cleanup and exits, so only that writer may release its unspent reservation. Invoking the reviewer wrapper crosses the uncertainty boundary: even a wrapper failure keeps the slot occupied, and an empty reconciliation read never authorizes release.

## Release

Only the owning writer releases its entry, only before any review POST attempt, and then it exits (`release_round_reservation`, run from `_p4b_on_exit`). Release runs after the result is out, so it never exits or prints a result: a ledger it cannot read or update only produces a warning, and the slot stays occupied. There is no owner release and no time-based reclamation: a POST can start before any deadline and land after it, so no client-side check proves that a potentially publishing run will not publish. A crashed or killed run's slot therefore stays occupied. The remedy is an owner decision, such as a higher governing cap or a reduced scope, never reuse of the slot.

## Precedence and exits

The round cap runs after the provider barrier. The blocking-review budget and every Codex human stop (runaway, disagreement, untested rebuttal) keep precedence. A tiebreak never grants a further round, and the existing independent-review, feedback-accounting and human-hold gates are unchanged. A cap stop never exits `4`, which `scripts/wave-audit.sh` reads as "may proceed". Unreadable or malformed evidence of any kind (policy, ledger ref, ledger commit, reviews) exits `10`.

## Scope and residuals

Enforcement covers only publishers that reserve through the ledger. An older orchestrator, or another tool that posts a Phase 4b review without reserving, is outside it. Its reviews are still counted, but it can exceed the cap. Fleet enforcement may be claimed only once every automated publisher participates (#2665, #2666). Codex requester count-and-post atomicity is a separate race, #1362, which this ledger does not close.

## Tests

`tests/test_phase_4b_round_cap.sh` covers both layers.

The pure helpers: counting, the cap value, ledger parse and message, occupancy, and reconciliation.

The protocol: the extracted production block runs against a stateful fake GitHub whose compare-and-swap is atomic under a lock and which honors `force`. The cases are:

- the 3/3 refusal;
- a held in-flight slot;
- a competitor winning between read and write;
- a stale ref read;
- a ref write that commits after the client times out;
- a write that never applied;
- five and ten real concurrent callers;
- the binding check against edited, duplicated and removed entries;
- writer release and no release after a POST attempt;
- a review that lands late and becomes visible late;
- duplicate invocation ids;
- unreadable or malformed evidence, including malformed review records;
- a surplus review carrying a reserved run id;
- a marker-shaped example quoted in a review body;
- the production exit-`8` helper's output shape;
- a release that cannot read the ledger;
- a fake that refuses an empty tree, as GitHub does;
- the absent cap;
- head changes.

Mutation checks confirm that each of these fails the suite: forcing the update, releasing after a POST attempt, skipping the binding check, treating a conflict as success, dropping the parent, posting an empty tree, letting one reservation absorb surplus reviews, skipping the pre-POST cleanup, an exiting release, skipping review-record validation, parsing an unanchored marker and nesting the spent `round_cap` under `barrier` only.

## Unpublished validated verdicts (#2790)

Before presentation normalization or later publication fences, the orchestrator saves the exact validated, input-bound adapter JSON separately. Adapter-authored strings in the presentation insert a zero-width break after the leading `@` in each case-insensitive reserved Codex command, including quotes in code fences; the strict guard and writer-owned markers remain unchanged. Ordinary text is preserved. Accounting and the posted review consume the same normalized presentation.

A run that cannot publish reports the raw result as `validated_verdict` in terminal JSON and retains its private file under the accounting state directory's `unposted-verdicts/`; `validated_verdict_path` and stderr name that file. Late structured refusals retain their existing status and reason while carrying the same evidence fields. If the file cannot be retained, the path is null and `validated_verdict_retention_error` plus stderr report that failure; terminal JSON still includes the raw verdict. Successful publication removes the local copy. Retained verdicts are evidence for disposition, never permission to retry an uncertain POST or bypass a fence.
