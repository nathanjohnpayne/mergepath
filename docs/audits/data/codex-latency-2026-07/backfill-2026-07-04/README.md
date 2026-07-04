# Backfill sample — 2026-07-04

Load-bearing raw + computed samples for the ack (pair 1) backfill that drives
the `ack_wait_seconds` retune in `../../codex-latency-2026-07.md`.

- `reactions.jsonl` — every Codex reaction the pass mined (`gh api
  issues/comments/{id}/reactions`). All 14 are `eyes` (👀 ack); there are
  **zero** `+1` on trigger comments. That is the raw evidence for pair 1 AND
  for why pair 4 (👍 clearance) came up empty at this endpoint — the merge
  gate reads the clearance 👍 from the PR issue
  (`repos/$REPO/issues/$PR_NUMBER/reactions`), a different object the script
  does not yet fetch (see the doc's Follow-ups).
- `pairs-ack.jsonl` — the computed pair-1 rows (trigger → 👀 ack) the summary
  percentiles derive from: p50 9s, p99 13s, max 13s (n=14).

Regenerate the full extract (all pairs, both windows) with
`scripts/audit-codex-latency.sh --repo nathanjohnpayne/mergepath` /
`--analyze-only`.
