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

## 2b_trigger_to_first_review_response

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

## 3_trigger_to_verdict

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 97 | 3m51s | 7m47s | 13m50s | 13m50s |
| additions_bucket=additions<=50 | 12 | 2m0s | 4m25s | 7m27s | 7m27s |
| additions_bucket=additions=151-300 | 11 | 3m22s | 4m47s | 8m15s | 8m15s |
| additions_bucket=additions=301-1000 | 43 | 3m56s | 6m42s | 8m52s | 8m52s |
| additions_bucket=additions=51-150 | 12 | 2m44s | 4m58s | 8m4s | 8m4s |
| additions_bucket=additions>1000 | 19 | 5m59s | 10m30s | 13m50s | 13m50s |
| round=1 | 32 | 2m53s | 5m7s | 8m52s | 8m52s |
| round=2 | 13 | 4m39s | 8m6s | 8m15s | 8m15s |
| round=3+ | 52 | 4m6s | 8m4s | 13m50s | 13m50s |
| rate_limited=false | 97 | 3m51s | 7m47s | 13m50s | 13m50s |

## 5_push_to_auto_review

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 106 | 4m14s | 20m6s | 33m1s | 36m1s |
| additions_bucket=additions<=50 | 7 | 4m35s | 7m59s | 7m59s | 7m59s |
| additions_bucket=additions=151-300 | 12 | 3m30s | 7m17s | 9m40s | 9m40s |
| additions_bucket=additions=301-1000 | 48 | 5m17s | 29m20s | 36m1s | 36m1s |
| additions_bucket=additions=51-150 | 18 | 3m8s | 6m7s | 7m21s | 7m21s |
| additions_bucket=additions>1000 | 21 | 4m14s | 20m6s | 22m13s | 22m13s |
| rate_limited=false | 105 | 4m15s | 20m6s | 33m1s | 36m1s |
| rate_limited=true | 1 | 3m14s | 3m14s | 3m14s | 3m14s |

## 6_clearance_to_gate:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 18 | 47s | 21m9s | 28m52s | 28m52s |
| additions_bucket=additions<=50 | 2 | 19s | 4m27s | 4m27s | 4m27s |
| additions_bucket=additions=301-1000 | 8 | 27s | 21m9s | 21m9s | 21m9s |
| additions_bucket=additions=51-150 | 4 | 59s | 28m52s | 28m52s | 28m52s |
| additions_bucket=additions>1000 | 4 | 37s | 1m16s | 1m16s | 1m16s |
| rate_limited=false | 18 | 47s | 21m9s | 28m52s | 28m52s |

## 6_clearance_to_gate:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 17 | 30s | 7m53s | 12m14s | 12m14s |
| additions_bucket=additions<=50 | 2 | 19s | 7m53s | 7m53s | 7m53s |
| additions_bucket=additions=301-1000 | 8 | 13s | 1m3s | 1m3s | 1m3s |
| additions_bucket=additions=51-150 | 3 | 59s | 12m14s | 12m14s | 12m14s |
| additions_bucket=additions>1000 | 4 | 37s | 1m16s | 1m16s | 1m16s |
| rate_limited=false | 17 | 30s | 7m53s | 12m14s | 12m14s |

## 6_clearance_to_merge

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 23 | 2m3s | 38m5s | 6h41m | 6h41m |
| additions_bucket=additions<=50 | 5 | 46s | 8m18s | 8m18s | 8m18s |
| additions_bucket=additions=301-1000 | 8 | 2m3s | 38m5s | 38m5s | 38m5s |
| additions_bucket=additions=51-150 | 5 | 4m0s | 6h41m | 6h41m | 6h41m |
| additions_bucket=additions>1000 | 5 | 1m43s | 9m26s | 9m26s | 9m26s |
| rate_limited=false | 23 | 2m3s | 38m5s | 6h41m | 6h41m |

## 6_gate_queue:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 18 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 2 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 8 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 4 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 4 | 0s | 0s | 0s | 0s |
| rate_limited=false | 18 | 0s | 0s | 0s | 0s |

## 6_gate_queue:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 17 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 2 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 8 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 3 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 4 | 0s | 0s | 0s | 0s |
| rate_limited=false | 17 | 0s | 0s | 0s | 0s |

## 6_gate_run:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 18 | 14s | 25s | 26s | 26s |
| additions_bucket=additions<=50 | 2 | 10s | 14s | 14s | 14s |
| additions_bucket=additions=301-1000 | 8 | 14s | 18s | 18s | 18s |
| additions_bucket=additions=51-150 | 4 | 20s | 26s | 26s | 26s |
| additions_bucket=additions>1000 | 4 | 16s | 19s | 19s | 19s |
| rate_limited=false | 18 | 14s | 25s | 26s | 26s |

## 6_gate_run:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 17 | 13s | 17s | 19s | 19s |
| additions_bucket=additions<=50 | 2 | 11s | 13s | 13s | 13s |
| additions_bucket=additions=301-1000 | 8 | 12s | 16s | 16s | 16s |
| additions_bucket=additions=51-150 | 3 | 13s | 19s | 19s | 19s |
| additions_bucket=additions>1000 | 4 | 11s | 17s | 17s | 17s |
| rate_limited=false | 17 | 13s | 17s | 19s | 19s |

## Appendix: unclassified bot comments (top 20 shapes)

- (n=1) ### Review Result  \* Reviewed the current PR head (\`c2c2f0d\`) and found no additional follow-up code changes necessary. \* The major dev-
- (n=1) ### Summary  \* No follow-up code changes were needed: the PR branch already contains the Codex eyes-acknowledgment gate, including polling 
- (n=1) ### Summary \* I reviewed the trigger and PR context. The trigger content is a PR description/self-review, and the PR comments indicate this
- (n=1) \*\*Summary\*\* \* Added Phase 4a workflow guidance that callers must export \`MERGEPATH\_PHASE\_4A\_GATED=true\` when \`codex.request\_by\_
- (n=1) \*\*Summary\*\* \* Reviewed the PR changes and found no follow-up code changes needed. \* The docs now explicitly state that a fix push does
- (n=1) \*\*Summary\*\* \* Updated \`scripts/codex-review-request.sh\` usage docs to include \`--trigger-only\`. [scripts/codex-review-request.shL9-

> Trimmed to ALL / diff-size / round / rate-limited segments; the noisy hour= and weekday= breakdowns (many n=1-2) are omitted. Regenerate the full segmentation with `scripts/audit-codex-latency.sh --analyze-only`.
