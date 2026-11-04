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

The round cap runs after the provider barrier. The blocking-review budget and every Codex human stop (runaway, disagreement, untested rebuttal) keep precedence. A tiebreak never grants a further round; only a scoped owner authorization does, once (below). The existing independent-review, feedback-accounting and human-hold gates are unchanged. A cap stop never exits `4`, which `scripts/wave-audit.sh` reads as "may proceed". Unreadable or malformed evidence of any kind (policy, ledger ref, ledger commit, reviews) exits `10`.

## Scope and residuals

Enforcement covers only publishers that reserve through the ledger. An older orchestrator, or another tool that posts a Phase 4b review without reserving, is outside it. Its reviews are still counted, but it can exceed the cap; since #2968 the merge gate does not count such a review as clearance and flags it (below). Fleet enforcement may be claimed only once every automated publisher participates (#2665, #2666). Codex requester count-and-post atomicity is a separate race, #1362, which this ledger does not close.

## Review provenance and the owner-authorized round (#2968)

On mergepath#2887 the orchestrator refused a fourth round at 3/3, and three more reviews carrying the Phase 4b header were then posted by hand outside the ledger, the last one `APPROVED`. The owner chose a narrow sanctioned path for that situation (#2968, decision comment 6610459491), and an enforcement point at both ends so that a review carrying the header cannot clear a gate without either a ledger reservation or a scoped owner authorization. The pure helpers live in `scripts/lib/p4b-review-provenance.sh`, shared by the orchestrator and the merge gate.

### The owner authorization

The owner types one line in a PR comment:

```text
P4B_EXTRA_ROUND_AUTHORIZED=<canonical-https-PR-URL>@<full-head-sha> reason: <why>
```

It follows the owner-marker convention of the dispute and runaway tiebreaks (`TIEBREAK_REBUTTAL_ACCEPTED`, `TIEBREAK_RUNAWAY_ACCEPTED`, REVIEW_POLICY.md § Disagreements and Tiebreaking): the comment is by the governing `author_identity` and was never edited, the PR URL compares case-insensitively, only the exact full head counts, and the comment must be newer than the event it answers. Here that event is the latest review that claims automated Phase 4b provenance, compared in whole seconds, so an authorization cannot be recorded before the round that spent the cap. Agents never write the filled-in line: the comment guard refuses it in every agent-authored body, in prose or in a code fence, and escalations name it with placeholders only. It differs from the tiebreaks in three ways. It grants something (one round beyond the cap) rather than clearing a stop. It requires a non-empty reason of at most 500 characters. It is single-use. The comment must carry exactly one `P4B_EXTRA_ROUND_AUTHORIZED` line; two lines, a line quoted in prose, an abbreviated head or a missing reason are malformed.

The binding is the comment's GitHub id, which is unique and assigned by GitHub. One comment authorizes exactly one run on one head. A new head, or another run, needs a new comment.

### Publication

`scripts/phase-4b-review.sh <PR> --repo <owner/repo> --owner-authorization <comment-id>` is the only sanctioned publisher of a round beyond the cap. It is the ordinary orchestrator run: the provider barrier, Codex human stops, tripwires, feedback accounting, immutable input, request-budget fences and every writer-boundary recheck still apply, and only the round-cap stop changes.

- **Reservation.** When occupancy has reached the cap with nothing in flight, the run validates the authorization against freshly read PR comments, then appends `{run, head, state: "reserved", authorization: <comment-id>}` with the same fast-forward-only write as any reservation. That entry is the consumption record. Of several writers on one tip exactly one wins, so of several runs on one authorization exactly one consumes it; the losers re-read and hold behind the in-flight round (exit 6), and once it publishes they meet the consumed authorization.
- **Refusals.** An authorization that is consumed by any other entry (reserved or released: a run that released its slot before posting still spent it), invalid, stale or edited keeps the spent stop (exit 8, `round_cap.owner_authorization.state: "refused"` with the reason). A cap that is not spent, a policy with no cap, `--dry-run` and `--wave-scope-file` refuse the flag (exit 3) and consume nothing. Unreadable comments exit 10.
- **Binding check.** Before the POST the run's entry must still carry exactly the authorization it reserved under, and the authorization is re-read and re-validated; an edit or deletion in between refuses publication through the pre-POST cleanup (exit 10).
- **Citation.** The posted review cites the comment twice: a Review Metadata line naming its URL and the reason (every ASCII punctuation character escaped, as the #2633 admin-override quote is), and the machine record `<!-- mergepath-p4b-owner-authorization: <comment-id> -->` directly before the run marker and footer. Only that anchored record is the citation; a copy quoted elsewhere in a review is not. A quote of the owner's words inside a review, which is all #2887 had, cites nothing.
- **The comment guard.** `scripts/workflow/gh-comment-trigger-guard.py` refuses a review write (`gh pr review`, a REST `pulls/<N>/reviews` write, or a GraphQL review-body mutation: `addPullRequestReview`, `submitPullRequestReview` or `updatePullRequestReview`) whose body claims automated Phase 4b provenance: a bold `Automated` or `Direct` Phase 4b review heading at the start, a run marker, an authorization record or the orchestrator footer. It allows only the orchestrator's own write: one body, posted by the reviewer wrapper as a REST `POST repos/<o>/<r>/pulls/<N>/reviews`, with `MERGEPATH_P4B_REVIEW_WRITE=1` set. The hook role is never allowed, so an agent typing that write by hand is refused before it runs. A manual handoff review carries none of these claims and posts as before.

### The merge gate

`scripts/codex-review-check.sh` reads the PR's reviews once for gates (b) and (c). Where the governing policy sets `phase_4b_automation.max_review_rounds`, it classifies every review by an account that is not a GitHub App bot whose body claims automated provenance, before either gate counts it (bots never post a Phase 4b verdict, and their reviews quote this repository's own diffs, which carry the markers whenever the Phase 4b code changes):

1. **Ledger-reserved.** The body opens with `**Automated Phase 4b review**` and carries a run marker directly before the footer; the ledger holds exactly one entry for that run, `reserved`, for the review's commit; no other publisher-shaped review carries that run id (one that opens with the header and is by an `available_reviewers` identity, so a COMMENTED discussion or an outside account quoting the public trailer is not a second carrier); and neither the review nor the entry names an authorization.
2. **Owner-authorized.** The same, and the review's anchored authorization record equals its entry's `authorization`, no other entry consumed that comment, and the comment is a valid authorization for this PR and the review's commit, posted before the review.
3. **Manual handoff.** No claim at all. The review is not classified and keeps its documented exemption: it is human-mediated and stays outside the ledger by design.
4. **Unverified.** Any other claim-bearing review, including the #2887 shapes and a header, run marker and footer forged by a reviewer session with no ledger entry. It is never clearance. When it is `APPROVED` it is read as `DISMISSED`, so it clears neither gate and an earlier approval by the same reviewer does not stand in for it, because that reviewer's latest position cannot be trusted. Every unverified review is logged as a `FLAG: UNVERIFIED Phase 4b review provenance` line, emitted as a workflow warning, and named in the gate's failure message.

The gate reads the ledger ref with the caller's token (`contents: read` suffices) only when a claim-bearing review exists, and the PR comments only when a review cites an authorization. An unreadable or malformed ledger, or a malformed governing cap, exits 3: missing evidence is never a decision. Feedback accounting, the request-generation and owed-Codex fences, human holds, CI and every other gate are unchanged and still apply to a classified review. `scripts/merge-clearance-gate.sh` delegates its external-review decision to this checker, so the required check inherits the classification.

### Residuals

- **The owner's account is not the owner.** A comment posted by `author_identity` does not prove the owner typed it: agents hold the same credential (the accepted shared-token residual, #928/#2129, and [Admin automated 4b override](phase_4b_escalation.md)). The authorization preserves who posted what and when, and the guard keeps agents' own tooling from writing it, but nothing here authenticates a person.
- **The guard is discipline, not a boundary.** `MERGEPATH_P4B_REVIEW_WRITE` is an environment flag, and a direct API call outside the wrappers never meets the guard. The merge gate is the enforcement point that does not depend on the publisher.
- **The ledger is organizational state.** Anyone who can push can write the ref, so a session that forges a reservation as well as a review would classify as ledger-reserved. The forgery would then be in the ledger's history, attributable to the account that pushed it.
- **Scope.** The gate evaluates open PRs; merged PRs, #2887 among them, are not re-evaluated. A policy with no round cap keeps the earlier reading of header-bearing reviews, because no ledger exists there. Under-threshold PRs, where any reviewer approval is the documented clearance, and the Dependabot lane do not consult the classification.
- **Pre-ledger approvals.** An automated approval posted before its repository had a ledger, still sitting on an open PR's current head, now reads as unverified and needs a rerun.
- **Dispatch time is not visible to the gate.** The gate checks that the authorization predates the review; that it predates dispatch and postdates the spent cap is enforced by the orchestrator.

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
- head changes;
- the #2968 owner-authorized round: no authorization at a spent cap (exit 8, the placeholder line named), a valid one reserving exactly one slot beyond the cap with its comment id recorded, a second run on it, a head change, an older, edited or foreign authorization, a cap that is not spent and no cap (exit 3), unreadable comments (exit 10), an edit after dispatch and a reservation stripped of its authorization at the binding check, a released authorized run, five concurrent runs on one authorization, and the production writer publishing an authorized and an ordinary round that the gate classifier then reads as owner-authorized and ledger.

The #2968 pure helpers have their own cases in the same suite: parity of the run-marker, ledger and cap readers with the round counter's; every authorization refusal; the four gate classes, including the #2887 shapes, a forged header, run marker and footer, a quoted authorization line or record, surplus run ids and authorizations, and the manual exemption; and neutralization. `tests/test_codex_request_evidence.sh` runs the real `codex-review-check.sh` against a fake ledger ref for the gate cases, and `tests/test_gh_comment_trigger_guard.py` covers the guard's refusals and the orchestrator's sole write context.

Mutation checks confirm that each of these fails the suite: forcing the update, releasing after a POST attempt, skipping the binding check, treating a conflict as success, dropping the parent, posting an empty tree, letting one reservation absorb surplus reviews, skipping the pre-POST cleanup, an exiting release, skipping review-record validation, parsing an unanchored marker and nesting the spent `round_cap` under `barrier` only. For #2968 the same holds for skipping neutralization or the cap check at the gate, dropping the ledger-entry, surplus-run, authorization-validity, edit or head checks in the classifier, skipping the consumption check, the authorization record, the newer-than floor or the binding recheck in the orchestrator, dropping its guard write context, and letting the guard pass a provenance claim, admit the hook role or accept the owner line.

## Unpublished validated verdicts (#2790)

Before presentation normalization or later publication fences, the orchestrator saves the exact validated, input-bound adapter JSON separately. Adapter-authored strings in the presentation insert a zero-width break after the leading `@` in each case-insensitive reserved Codex command, including quotes in code fences; the strict guard and writer-owned markers remain unchanged. Ordinary text is preserved. Accounting and the posted review consume the same normalized presentation.

A run that cannot publish reports the raw result as `validated_verdict` in terminal JSON and retains its private file under the accounting state directory's `unposted-verdicts/`; `validated_verdict_path` and stderr name that file. Late structured refusals retain their existing status and reason while carrying the same evidence fields. If the file cannot be retained, the path is null and `validated_verdict_retention_error` plus stderr report that failure; terminal JSON still includes the raw verdict. Successful publication removes the local copy. Retained verdicts are evidence for disposition, never permission to retry an uncertain POST or bypass a fence.
