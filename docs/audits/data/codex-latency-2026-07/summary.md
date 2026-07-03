## 2b_trigger_to_first_review_response

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 197 | 4m45s | 13m51s | 21m13s | 30m39s |
| additions_bucket=additions<=50 | 17 | 2m53s | 3m39s | 4m17s | 4m17s |
| additions_bucket=additions=151-300 | 17 | 4m17s | 7m0s | 8m35s | 8m35s |
| additions_bucket=additions=301-1000 | 60 | 4m24s | 9m5s | 30m39s | 30m39s |
| additions_bucket=additions=51-150 | 14 | 3m48s | 8m1s | 8m48s | 8m48s |
| additions_bucket=additions>1000 | 89 | 6m42s | 16m14s | 21m13s | 21m13s |
| round=1 | 50 | 4m6s | 8m48s | 15m12s | 15m12s |
| round=2 | 43 | 4m21s | 10m35s | 30m39s | 30m39s |
| round=3+ | 104 | 5m26s | 15m20s | 19m57s | 21m13s |
| weekday=Fri | 9 | 4m51s | 10m28s | 10m28s | 10m28s |
| weekday=Mon | 8 | 5m11s | 8m29s | 8m29s | 8m29s |
| weekday=Sat | 8 | 4m54s | 8m18s | 8m18s | 8m18s |
| weekday=Sun | 26 | 4m11s | 7m0s | 8m35s | 8m35s |
| weekday=Thu | 50 | 11m1s | 17m50s | 21m13s | 21m13s |
| weekday=Tue | 27 | 3m42s | 5m58s | 9m0s | 9m0s |
| weekday=Wed | 69 | 4m27s | 10m35s | 30m39s | 30m39s |
| hour=00 | 11 | 4m17s | 21m13s | 30m39s | 30m39s |
| hour=01 | 7 | 4m24s | 11m53s | 11m53s | 11m53s |
| hour=02 | 8 | 4m10s | 14m5s | 14m5s | 14m5s |
| hour=03 | 10 | 3m38s | 6m25s | 16m40s | 16m40s |
| hour=04 | 17 | 5m16s | 12m53s | 15m19s | 15m19s |
| hour=05 | 16 | 6m1s | 11m27s | 17m50s | 17m50s |
| hour=06 | 4 | 10m22s | 14m55s | 14m55s | 14m55s |
| hour=07 | 3 | 13m28s | 19m57s | 19m57s | 19m57s |
| hour=08 | 3 | 12m47s | 14m34s | 14m34s | 14m34s |
| hour=09 | 3 | 17m58s | 19m18s | 19m18s | 19m18s |
| hour=10 | 2 | 16m14s | 18m54s | 18m54s | 18m54s |
| hour=12 | 2 | 13m46s | 15m46s | 15m46s | 15m46s |
| hour=14 | 6 | 3m48s | 7m24s | 7m24s | 7m24s |
| hour=15 | 12 | 3m37s | 15m8s | 17m5s | 17m5s |
| hour=16 | 15 | 3m45s | 6m25s | 15m20s | 15m20s |
| hour=17 | 6 | 4m36s | 15m12s | 15m12s | 15m12s |
| hour=18 | 15 | 4m37s | 7m15s | 8m12s | 8m12s |
| hour=19 | 13 | 6m7s | 9m5s | 9m32s | 9m32s |
| hour=20 | 4 | 6m9s | 9m13s | 9m13s | 9m13s |
| hour=21 | 11 | 5m1s | 7m20s | 7m54s | 7m54s |
| hour=22 | 18 | 4m42s | 10m28s | 11m7s | 11m7s |
| hour=23 | 11 | 4m8s | 5m36s | 10m6s | 10m6s |
| rate_limited=false | 196 | 4m45s | 13m51s | 21m13s | 30m39s |
| rate_limited=true | 1 | 3m9s | 3m9s | 3m9s | 3m9s |

## 3_trigger_to_verdict

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 100 | 3m37s | 7m6s | 10m30s | 13m50s |
| additions_bucket=additions<=50 | 15 | 2m22s | 3m37s | 4m25s | 4m25s |
| additions_bucket=additions=151-300 | 11 | 3m22s | 4m47s | 8m15s | 8m15s |
| additions_bucket=additions=301-1000 | 41 | 3m51s | 6m42s | 8m52s | 8m52s |
| additions_bucket=additions=51-150 | 14 | 2m44s | 4m38s | 8m4s | 8m4s |
| additions_bucket=additions>1000 | 19 | 5m59s | 10m30s | 13m50s | 13m50s |
| round=1 | 33 | 3m3s | 4m54s | 8m52s | 8m52s |
| round=2 | 18 | 3m0s | 8m6s | 8m15s | 8m15s |
| round=3+ | 49 | 4m6s | 8m35s | 13m50s | 13m50s |
| weekday=Fri | 12 | 3m22s | 4m6s | 4m39s | 4m39s |
| weekday=Mon | 2 | 3m29s | 8m15s | 8m15s | 8m15s |
| weekday=Sat | 8 | 3m12s | 8m35s | 8m35s | 8m35s |
| weekday=Sun | 6 | 2m3s | 4m6s | 4m6s | 4m6s |
| weekday=Thu | 29 | 4m53s | 8m45s | 10m30s | 10m30s |
| weekday=Tue | 13 | 2m16s | 8m52s | 13m50s | 13m50s |
| weekday=Wed | 30 | 3m38s | 6m35s | 8m6s | 8m6s |
| hour=00 | 7 | 3m30s | 5m47s | 5m47s | 5m47s |
| hour=01 | 7 | 3m22s | 6m4s | 6m4s | 6m4s |
| hour=02 | 6 | 2m33s | 4m6s | 4m6s | 4m6s |
| hour=03 | 11 | 2m44s | 4m6s | 5m28s | 5m28s |
| hour=04 | 4 | 3m12s | 3m31s | 3m31s | 3m31s |
| hour=05 | 1 | 3m32s | 3m32s | 3m32s | 3m32s |
| hour=06 | 2 | 5m18s | 6m39s | 6m39s | 6m39s |
| hour=07 | 1 | 3m34s | 3m34s | 3m34s | 3m34s |
| hour=08 | 4 | 4m54s | 7m6s | 7m6s | 7m6s |
| hour=09 | 2 | 3m51s | 6m35s | 6m35s | 6m35s |
| hour=12 | 1 | 8m45s | 8m45s | 8m45s | 8m45s |
| hour=14 | 5 | 4m8s | 9m4s | 9m4s | 9m4s |
| hour=15 | 1 | 13m50s | 13m50s | 13m50s | 13m50s |
| hour=16 | 4 | 3m12s | 5m31s | 5m31s | 5m31s |
| hour=17 | 4 | 2m22s | 10m30s | 10m30s | 10m30s |
| hour=18 | 8 | 3m3s | 8m52s | 8m52s | 8m52s |
| hour=19 | 9 | 4m38s | 8m35s | 8m35s | 8m35s |
| hour=20 | 2 | 3m54s | 8m4s | 8m4s | 8m4s |
| hour=21 | 8 | 3m29s | 4m15s | 4m15s | 4m15s |
| hour=22 | 7 | 3m18s | 8m6s | 8m6s | 8m6s |
| hour=23 | 6 | 2m30s | 6m42s | 6m42s | 6m42s |
| rate_limited=false | 100 | 3m37s | 7m6s | 10m30s | 13m50s |

## 5_push_to_auto_review

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 128 | 4m12s | 11m10s | 33m1s | 36m1s |
| additions_bucket=additions<=50 | 13 | 3m15s | 6m14s | 7m59s | 7m59s |
| additions_bucket=additions=151-300 | 17 | 4m4s | 7m17s | 9m40s | 9m40s |
| additions_bucket=additions=301-1000 | 51 | 5m17s | 28m48s | 36m1s | 36m1s |
| additions_bucket=additions=51-150 | 25 | 3m17s | 5m21s | 7m21s | 7m21s |
| additions_bucket=additions>1000 | 22 | 4m14s | 12m54s | 22m13s | 22m13s |
| weekday=Fri | 19 | 4m45s | 32m40s | 33m1s | 33m1s |
| weekday=Mon | 5 | 6m44s | 20m6s | 20m6s | 20m6s |
| weekday=Sat | 17 | 3m52s | 7m13s | 7m17s | 7m17s |
| weekday=Sun | 16 | 3m23s | 5m21s | 8m15s | 8m15s |
| weekday=Thu | 18 | 4m6s | 8m1s | 11m10s | 11m10s |
| weekday=Tue | 15 | 4m9s | 20m10s | 23m30s | 23m30s |
| weekday=Wed | 38 | 4m35s | 28m48s | 36m1s | 36m1s |
| hour=00 | 6 | 4m12s | 7m17s | 7m17s | 7m17s |
| hour=01 | 9 | 3m57s | 5m21s | 5m21s | 5m21s |
| hour=02 | 8 | 3m52s | 6m12s | 6m12s | 6m12s |
| hour=03 | 11 | 5m47s | 7m40s | 8m1s | 8m1s |
| hour=04 | 12 | 4m5s | 5m46s | 6m11s | 6m11s |
| hour=05 | 7 | 4m40s | 9m40s | 9m40s | 9m40s |
| hour=06 | 1 | 3m25s | 3m25s | 3m25s | 3m25s |
| hour=12 | 1 | 5m0s | 5m0s | 5m0s | 5m0s |
| hour=14 | 3 | 5m16s | 12m54s | 12m54s | 12m54s |
| hour=15 | 8 | 3m7s | 6m51s | 6m51s | 6m51s |
| hour=16 | 9 | 5m41s | 11m10s | 11m10s | 11m10s |
| hour=17 | 12 | 5m26s | 33m1s | 36m1s | 36m1s |
| hour=18 | 11 | 5m3s | 29m20s | 32m56s | 32m56s |
| hour=19 | 2 | 3m30s | 3m50s | 3m50s | 3m50s |
| hour=20 | 4 | 2m18s | 11m22s | 11m22s | 11m22s |
| hour=21 | 8 | 3m3s | 20m6s | 20m6s | 20m6s |
| hour=22 | 9 | 4m26s | 23m30s | 23m30s | 23m30s |
| hour=23 | 7 | 3m54s | 7m59s | 7m59s | 7m59s |
| rate_limited=false | 127 | 4m13s | 11m10s | 33m1s | 36m1s |
| rate_limited=true | 1 | 3m14s | 3m14s | 3m14s | 3m14s |

## 6_clearance_to_gate:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 14 | 30s | 1m16s | 28m52s | 28m52s |
| additions_bucket=additions<=50 | 1 | 19s | 19s | 19s | 19s |
| additions_bucket=additions=301-1000 | 6 | 21s | 1m3s | 1m3s | 1m3s |
| additions_bucket=additions=51-150 | 3 | 59s | 28m52s | 28m52s | 28m52s |
| additions_bucket=additions>1000 | 4 | 37s | 1m16s | 1m16s | 1m16s |
| weekday=Thu | 5 | 37s | 1m16s | 1m16s | 1m16s |
| weekday=Wed | 9 | 30s | 28m52s | 28m52s | 28m52s |
| hour=01 | 1 | 19s | 19s | 19s | 19s |
| hour=06 | 1 | 58s | 58s | 58s | 58s |
| hour=07 | 1 | 28m52s | 28m52s | 28m52s | 28m52s |
| hour=08 | 1 | 37s | 37s | 37s | 37s |
| hour=09 | 1 | 14s | 14s | 14s | 14s |
| hour=17 | 2 | 1m3s | 1m16s | 1m16s | 1m16s |
| hour=18 | 2 | 27s | 59s | 59s | 59s |
| hour=19 | 1 | 47s | 47s | 47s | 47s |
| hour=22 | 3 | 21s | 27s | 27s | 27s |
| hour=23 | 1 | 30s | 30s | 30s | 30s |
| rate_limited=false | 14 | 30s | 1m16s | 28m52s | 28m52s |

## 6_clearance_to_gate:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 13 | 30s | 1m3s | 1m16s | 1m16s |
| additions_bucket=additions<=50 | 1 | 19s | 19s | 19s | 19s |
| additions_bucket=additions=301-1000 | 6 | 21s | 1m3s | 1m3s | 1m3s |
| additions_bucket=additions=51-150 | 2 | 47s | 59s | 59s | 59s |
| additions_bucket=additions>1000 | 4 | 37s | 1m16s | 1m16s | 1m16s |
| weekday=Thu | 5 | 37s | 1m16s | 1m16s | 1m16s |
| weekday=Wed | 8 | 28s | 1m3s | 1m3s | 1m3s |
| hour=01 | 1 | 19s | 19s | 19s | 19s |
| hour=06 | 1 | 58s | 58s | 58s | 58s |
| hour=08 | 1 | 37s | 37s | 37s | 37s |
| hour=09 | 1 | 13s | 13s | 13s | 13s |
| hour=17 | 2 | 1m3s | 1m16s | 1m16s | 1m16s |
| hour=18 | 2 | 27s | 59s | 59s | 59s |
| hour=19 | 1 | 47s | 47s | 47s | 47s |
| hour=22 | 3 | 21s | 28s | 28s | 28s |
| hour=23 | 1 | 30s | 30s | 30s | 30s |
| rate_limited=false | 13 | 30s | 1m3s | 1m16s | 1m16s |

## 6_clearance_to_merge

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 17 | 1m43s | 9m26s | 39m57s | 39m57s |
| additions_bucket=additions<=50 | 3 | 46s | 2m29s | 2m29s | 2m29s |
| additions_bucket=additions=301-1000 | 6 | 1m25s | 7m26s | 7m26s | 7m26s |
| additions_bucket=additions=51-150 | 3 | 4m0s | 39m57s | 39m57s | 39m57s |
| additions_bucket=additions>1000 | 5 | 1m43s | 9m26s | 9m26s | 9m26s |
| weekday=Sun | 1 | 39s | 39s | 39s | 39s |
| weekday=Thu | 7 | 1m43s | 9m26s | 9m26s | 9m26s |
| weekday=Wed | 9 | 2m3s | 39m57s | 39m57s | 39m57s |
| hour=00 | 2 | 39s | 5m14s | 5m14s | 5m14s |
| hour=01 | 1 | 46s | 46s | 46s | 46s |
| hour=06 | 1 | 1m41s | 1m41s | 1m41s | 1m41s |
| hour=07 | 1 | 39m57s | 39m57s | 39m57s | 39m57s |
| hour=08 | 1 | 1m26s | 1m26s | 1m26s | 1m26s |
| hour=09 | 1 | 1m20s | 1m20s | 1m20s | 1m20s |
| hour=17 | 2 | 7m26s | 9m26s | 9m26s | 9m26s |
| hour=18 | 2 | 1m43s | 4m0s | 4m0s | 4m0s |
| hour=19 | 2 | 1m42s | 2m29s | 2m29s | 2m29s |
| hour=22 | 3 | 2m3s | 2m27s | 2m27s | 2m27s |
| hour=23 | 1 | 1m25s | 1m25s | 1m25s | 1m25s |
| rate_limited=false | 17 | 1m43s | 9m26s | 39m57s | 39m57s |

## 6_gate_queue:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 14 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 1 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 6 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 3 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 4 | 0s | 0s | 0s | 0s |
| weekday=Thu | 5 | 0s | 0s | 0s | 0s |
| weekday=Wed | 9 | 0s | 0s | 0s | 0s |
| hour=01 | 1 | 0s | 0s | 0s | 0s |
| hour=06 | 1 | 0s | 0s | 0s | 0s |
| hour=07 | 1 | 0s | 0s | 0s | 0s |
| hour=08 | 1 | 0s | 0s | 0s | 0s |
| hour=09 | 1 | 0s | 0s | 0s | 0s |
| hour=17 | 2 | 0s | 0s | 0s | 0s |
| hour=18 | 2 | 0s | 0s | 0s | 0s |
| hour=19 | 1 | 0s | 0s | 0s | 0s |
| hour=22 | 3 | 0s | 0s | 0s | 0s |
| hour=23 | 1 | 0s | 0s | 0s | 0s |
| rate_limited=false | 14 | 0s | 0s | 0s | 0s |

## 6_gate_queue:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 13 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 1 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 6 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 2 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 4 | 0s | 0s | 0s | 0s |
| weekday=Thu | 5 | 0s | 0s | 0s | 0s |
| weekday=Wed | 8 | 0s | 0s | 0s | 0s |
| hour=01 | 1 | 0s | 0s | 0s | 0s |
| hour=06 | 1 | 0s | 0s | 0s | 0s |
| hour=08 | 1 | 0s | 0s | 0s | 0s |
| hour=09 | 1 | 0s | 0s | 0s | 0s |
| hour=17 | 2 | 0s | 0s | 0s | 0s |
| hour=18 | 2 | 0s | 0s | 0s | 0s |
| hour=19 | 1 | 0s | 0s | 0s | 0s |
| hour=22 | 3 | 0s | 0s | 0s | 0s |
| hour=23 | 1 | 0s | 0s | 0s | 0s |
| rate_limited=false | 13 | 0s | 0s | 0s | 0s |

## 6_gate_run:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 14 | 15s | 25s | 26s | 26s |
| additions_bucket=additions<=50 | 1 | 14s | 14s | 14s | 14s |
| additions_bucket=additions=301-1000 | 6 | 14s | 18s | 18s | 18s |
| additions_bucket=additions=51-150 | 3 | 25s | 26s | 26s | 26s |
| additions_bucket=additions>1000 | 4 | 16s | 19s | 19s | 19s |
| weekday=Thu | 5 | 16s | 19s | 19s | 19s |
| weekday=Wed | 9 | 15s | 26s | 26s | 26s |
| hour=01 | 1 | 14s | 14s | 14s | 14s |
| hour=06 | 1 | 14s | 14s | 14s | 14s |
| hour=07 | 1 | 25s | 25s | 25s | 25s |
| hour=08 | 1 | 16s | 16s | 16s | 16s |
| hour=09 | 1 | 13s | 13s | 13s | 13s |
| hour=17 | 2 | 14s | 19s | 19s | 19s |
| hour=18 | 2 | 16s | 26s | 26s | 26s |
| hour=19 | 1 | 15s | 15s | 15s | 15s |
| hour=22 | 3 | 14s | 18s | 18s | 18s |
| hour=23 | 1 | 16s | 16s | 16s | 16s |
| rate_limited=false | 14 | 15s | 25s | 26s | 26s |

## 6_gate_run:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 13 | 12s | 17s | 19s | 19s |
| additions_bucket=additions<=50 | 1 | 13s | 13s | 13s | 13s |
| additions_bucket=additions=301-1000 | 6 | 11s | 16s | 16s | 16s |
| additions_bucket=additions=51-150 | 2 | 12s | 19s | 19s | 19s |
| additions_bucket=additions>1000 | 4 | 11s | 17s | 17s | 17s |
| weekday=Thu | 5 | 13s | 17s | 17s | 17s |
| weekday=Wed | 8 | 12s | 19s | 19s | 19s |
| hour=01 | 1 | 13s | 13s | 13s | 13s |
| hour=06 | 1 | 11s | 11s | 11s | 11s |
| hour=08 | 1 | 11s | 11s | 11s | 11s |
| hour=09 | 1 | 16s | 16s | 16s | 16s |
| hour=17 | 2 | 14s | 17s | 17s | 17s |
| hour=18 | 2 | 17s | 19s | 19s | 19s |
| hour=19 | 1 | 12s | 12s | 12s | 12s |
| hour=22 | 3 | 11s | 12s | 12s | 12s |
| hour=23 | 1 | 10s | 10s | 10s | 10s |
| rate_limited=false | 13 | 12s | 17s | 19s | 19s |

## Appendix: unclassified bot comments (top 20 shapes)

- (n=1) ### Review Result  \* Reviewed the current PR head (\`c2c2f0d\`) and found no additional follow-up code changes necessary. \* The major dev-
- (n=1) ### Summary  \* No follow-up code changes were needed: the PR branch already contains the Codex eyes-acknowledgment gate, including polling 
- (n=1) ### Summary \* I reviewed the trigger and PR context. The trigger content is a PR description/self-review, and the PR comments indicate this
- (n=1) \*\*Summary\*\* \* Added Phase 4a workflow guidance that callers must export \`MERGEPATH\_PHASE\_4A\_GATED=true\` when \`codex.request\_by\_
- (n=1) \*\*Summary\*\* \* Updated \`scripts/codex-review-request.sh\` usage docs to include \`--trigger-only\`. [scripts/codex-review-request.shL9-
