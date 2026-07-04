## 1_trigger_to_ack

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 14 | 9s | 11s | 13s | 13s |
| additions_bucket=additions=151-300 | 3 | 7s | 8s | 8s | 8s |
| additions_bucket=additions=301-1000 | 8 | 9s | 13s | 13s | 13s |
| additions_bucket=additions>1000 | 3 | 10s | 11s | 11s | 11s |
| round=1 | 2 | 8s | 10s | 10s | 10s |
| round=2 | 4 | 7s | 13s | 13s | 13s |
| round=3+ | 8 | 10s | 11s | 11s | 11s |
| rate_limited=false | 14 | 9s | 11s | 13s | 13s |

## 2_trigger_to_first_finding

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 208 | 5m16s | 13m46s | 19m57s | 30m39s |
| additions_bucket=additions<=50 | 12 | 3m15s | 3m39s | 4m17s | 4m17s |
| additions_bucket=additions=151-300 | 19 | 4m22s | 8m35s | 11m36s | 11m36s |
| additions_bucket=additions=301-1000 | 73 | 5m1s | 9m5s | 30m39s | 30m39s |
| additions_bucket=additions=51-150 | 12 | 3m30s | 8m1s | 8m48s | 8m48s |
| additions_bucket=additions>1000 | 92 | 7m46s | 15m46s | 21m13s | 21m13s |
| round=1 | 47 | 4m24s | 9m32s | 15m12s | 15m12s |
| round=2 | 44 | 4m27s | 10m35s | 30m39s | 30m39s |
| round=3+ | 117 | 6m1s | 15m19s | 19m57s | 21m13s |
| rate_limited=false | 207 | 5m20s | 13m46s | 19m57s | 30m39s |
| rate_limited=true | 1 | 3m9s | 3m9s | 3m9s | 3m9s |


> Backfill run (2026-05-01 → 2026-07-04). Only the newly-measured pairs 1 (ack) and 2 (first inline finding) are kept here — pairs 2b/3/5/6 for the original window are in `summary.md`. hour=/weekday= rows omitted; regenerate the full segmentation with `scripts/audit-codex-latency.sh --analyze-only`.
