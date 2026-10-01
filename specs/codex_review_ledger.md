# Report-only Codex review ledger (#1560, slice 2)

`scripts/codex-review-ledger.sh <PR>` reconstructs which Codex responses a pull request's configured-author requests drew, from records GitHub already holds, and prints the result. The attribution logic lives in `scripts/lib/codex-review-ledger.sh`, a pure function over evidence the command reads first. The ledger is report-only: it writes nothing to GitHub, and no requester, Phase 4b barrier or merge-gate path reads it. It exists so the counting and routing decision recorded on #1560 is made from measured evidence.

## Inputs and authority

The configured author, the Codex bot login and the required feedback tiers come from the pull request's governing base policy (`scripts/workflow/resolve_base_policy.sh`), the same authority the request cap reads. Requests are the configured author's exact request comments as `crqe_trigger_generation` defines them, so the ledger counts what the cap counts; a qualifying comment without a positive integer id fails closed. Finding tiers come from `codex_tiers_of` / `codex_tier_of`, provider blocks from `codex_failure_marker_of`, verdicts from `crqe_verdicts`, and the current Review Summary from `crqe_select_codex_review_summary`. A failed read or malformed evidence exits `3` and prints nothing.

## What the record proves, and what it does not

- A request comment names no commit, so a request is never given a head from timestamps. A response's head comes only from its own anchor: a review's `commit_id` or a verdict's `Reviewed commit`. Reactions and block notices carry none.
- Codex removes its eyes reaction when a review finishes, so `eyes_now` is the reaction as it stands now. `false` does not prove a request was never acknowledged.
- The Review Summary is edited in place, so only its current state is visible. It is reported as `current_summary` and never used as history.

## Responses

A response is the group of Codex signals in one request window that share a head anchor: a review with its root inline findings and top-level body findings, a verdict comment, a thumbs-up reaction on the pull request, or a provider block notice. Signals without an anchor join the window's single anchored group; when a window holds groups on different heads, each is its own response and the window is marked `mixed_heads`. A verdict whose short sha prefixes a review's head joins that review's response.

A response class says what Codex answered and nothing about merge clearance, which stays with `codex-review-check.sh`. In decreasing severity: `blocking` (a finding in a required tier, with P0 always blocking), `unknown_tier` (a non-affirmative verdict with no review to grade), `discretionary` (findings, none required), `no_findings`, `clean` (an affirmative verdict or a thumbs-up), and `provider_blocked`. A response containing both a blocking review and a clean signal keeps `blocking` and is marked `conflicting`. Review objects whose inline comments are all thread replies are not responses; they are listed under `thread_reply_reviews`, because a connector reply in a review thread lands as one.

## Attribution

Signals belong to the window of the latest request posted at or before them; a signal in the same second as a later request belongs to the later window. Signals before the first request are `unsolicited` responses. Requests are swept in order with a list of outstanding requests:

- a window with one response while exactly one request is outstanding attributes that response to it;
- a window with a response while two or more requests are outstanding, or with responses on different heads, makes every outstanding request `ambiguous`, lists the candidates, and states the reason;
- a request still outstanding at the end is `unanswered`, or `no_response_yet` when it is the last request.

Two request-level flags are reported and never applied: `possible_ack_retry_of` (the previous request shows no eyes, nothing answered it, and this one followed within `--retry-window`, default 300 seconds), and `reposted_while_eyes_present` (another request followed while this one still showed eyes and had no response, the #1550 re-post shape). Folding retries into one request is a counting rule for #1560 to choose, so the ledger never folds.

## Summary

The `summary` object reports request and outcome counts, response counts by class, `blocking_responses` and `blocking_responses_solicited` (unsolicited responses excluded), mixed-head windows, conflicting responses and thread-reply wrappers. `--summary` prints the same counts and lists every ambiguous, unanswered, possible-retry and re-posted request.

Coverage: `tests/test_codex_review_ledger.sh`.
