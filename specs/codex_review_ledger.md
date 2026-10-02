# Report-only Codex review ledger (#1560, slice 2)

`scripts/codex-review-ledger.sh <PR>` reconstructs which Codex responses a pull request's Codex requests drew, from records GitHub already holds, and prints the result. The attribution logic lives in `scripts/lib/codex-review-ledger.sh`, a pure function over evidence the command reads first. The ledger is report-only: it writes nothing to GitHub, and no requester, Phase 4b barrier or merge-gate path reads it. It exists so the counting and routing decision recorded on #1560 is made from measured evidence. Where the record cannot prove an attribution, the ledger says so and lists the candidates; it never picks one.

## Inputs and authority

The configured author, the Codex bot login (an absent or empty value defaults to `chatgpt-codex-connector[bot]`) and the required feedback tiers come from the pull request's governing base policy (`scripts/workflow/resolve_base_policy.sh`), the same authority the request cap reads. A policy that is not an object, or a malformed `author_identity` or `feedback_policy`, fails closed.

Every comment body is parsed by an existing shared helper: requests by `crqe_trigger_generation`, finding tiers by `codex_tiers_of` / `codex_tier_of`, provider blocks by `codex_failure_marker_of`, verdicts by `crqe_verdicts`, and the current Review Summary by `crqe_select_codex_review_summary`. `crqe_verdicts` uses the exact anchor and affirmative expressions `codex-review-request.sh` and `codex-review-check.sh` carry (the test pins all three copies); it differs from them only in selection, reporting every verdict instead of the latest one on the current head. A failed read, or malformed evidence anywhere (a qualifying request without a positive integer id, a review that does not parse), exits `3` and prints nothing. Repeated pagination items are de-duplicated by id.

## Requests

- **Counted requests** are the configured author's exact request comments, as `crqe_trigger_generation` defines them: the set the request cap counts.
- **Foreign requests** are every other non-bot issue comment, review-thread comment or review body that mentions the request command in any letter case. Codex answers those too, so they open windows and are attribution candidates, but they are not counted. Summaries report counted and foreign outcomes separately.

## What the record proves, and what it does not

- A request comment names no commit, so a request never gets a head from timestamps. A response's head comes only from its own anchor: a review's `commit_id` or a verdict's `Reviewed commit`. A verdict quoting heads that disagree has no anchor and is flagged `anchor_conflict`. Reactions and block notices carry none.
- Codex reacts with eyes while a review runs and usually removes the reaction when it finishes. Each counted request reports `eyes_at`, the reaction's timestamp if it is still present, and nothing else about acknowledgement.
- The pull-request thumbs-up is one reaction per user, so only its latest creation survives: earlier reaction-only clean passes leave no record, and the requests they answered may read as unanswered.
- The Review Summary is edited in place. It is reported as `current_summary` and never used as history.

Each ledger repeats these four limits in `limits`.

## Responses

Signals belong to the window of the latest request posted at or before them; signals before the first request are `unsolicited`. Within a window:

- each review (root inline findings plus top-level body findings) is its own response, including a review without a `commit_id`, so two reviews in one window are two responses (`multiple_in_window`);
- a verdict joins the latest review on the same head at or before it, else the earliest later one; a verdict with no matching review stands alone;
- signals without an anchor (reactions, block notices, verdicts without a sha) join the window's single response, or form their own when the window has none or several;
- a window whose responses sit on more than one head is `mixed_heads`; heads are the anchors that are not a prefix of another, so a short sha and its full sha are one head, but a short sha matching two different full shas leaves two;
- a response in the same second as a request is a `tie`.

Review objects whose inline comments are all thread replies are not responses. They are listed under `thread_reply_reviews` with any provider marker in the replies, because a connector reply in a review thread lands as one.

A response class says what Codex answered and nothing about merge clearance, which stays with `codex-review-check.sh`. A response with a review takes the review's grade: `blocking` (a finding in a required tier, with P0 always blocking), `discretionary` (findings, none required, including unmarked ones), or `no_findings`. Without a review, verdicts decide (`clean` when all are affirmative, otherwise `unknown_tier`), then a thumbs-up (`clean`), then a block notice (`provider_blocked`). A blocking review alongside a clean signal, or affirmative and non-affirmative verdicts together, is `conflicting`.

## Attribution

Requests are swept in order. `unresolved` holds requests not yet attributed and `debt` how many of them may still be owed a response. A window's response is **attributed** to its request only when all of these hold:

- it is the window's only response;
- its request is the only unresolved one and nothing earlier is still owed;
- it is not a same-second tie;
- it cannot be a second or late answer to an earlier request. That rules out a response on the same head as an earlier attributed response, and an anchorless response after the first window.

Otherwise every unresolved request becomes **ambiguous**, with the candidates and the reasons listed. A tie adds every other request in that second and the last request strictly before it as candidates, because the response may precede all of them. An earlier attributed request that the response may also answer is flagged `possible_second_response`. The ambiguous window pays down the debt by its number of responses, unless an earlier request competes for them, and unresolved requests stay candidates while any debt remains (`open_debt`). A request with no response and nothing resolving it is `unanswered`, or `no_response_yet` when it is the last request.

## Re-posts

A request followed by another with no response in between is `reposted_without_response`, with `repost_gap_seconds`. `eyes_before_repost` is `true` only when the eyes reaction's own timestamp precedes the next request, `false` when it follows it, and `unknown` when no eyes reaction remains. The ledger never folds requests or calls one an acknowledgement retry: whether to fold is a counting rule for #1560 to choose.

## Summary

The `summary` object reports counted and foreign request counts and outcomes, `open_debt`, eyes and re-post counts, response counts by class, `blocking_responses` and `blocking_responses_solicited` (unsolicited responses excluded), and the counts of mixed-head windows, multi-response windows, ties, conflicting responses, anchor conflicts and thread-reply wrappers. `--summary` prints the same counts and lists every request that is not cleanly attributed, was re-posted without a response, or may have received a second response.

Coverage: `tests/test_codex_review_ledger.sh`.
