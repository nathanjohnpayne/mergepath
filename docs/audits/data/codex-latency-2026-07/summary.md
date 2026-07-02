## 2_trigger_to_first_finding

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 209 | 4m44s | 13m51s | 19m57s | 30m39s |
| additions_bucket=additions<=50 | 17 | 2m53s | 3m39s | 4m17s | 4m17s |
| additions_bucket=additions=151-300 | 20 | 3m46s | 6m57s | 8m35s | 8m35s |
| additions_bucket=additions=301-1000 | 66 | 4m21s | 9m11s | 30m39s | 30m39s |
| additions_bucket=additions=51-150 | 15 | 4m6s | 8m48s | 10m46s | 10m46s |
| additions_bucket=additions>1000 | 91 | 6m42s | 16m14s | 21m13s | 21m13s |
| round=1 | 60 | 3m49s | 9m32s | 17m35s | 17m35s |
| round=2 | 44 | 4m19s | 10m35s | 30m39s | 30m39s |
| round=3+ | 105 | 5m28s | 15m20s | 19m57s | 21m13s |
| weekday=Fri | 9 | 4m51s | 10m28s | 10m28s | 10m28s |
| weekday=Mon | 10 | 5m11s | 8m29s | 17m35s | 17m35s |
| weekday=Sat | 11 | 4m37s | 8m12s | 8m18s | 8m18s |
| weekday=Sun | 26 | 4m11s | 7m0s | 8m35s | 8m35s |
| weekday=Thu | 56 | 10m22s | 17m50s | 21m13s | 21m13s |
| weekday=Tue | 27 | 3m42s | 5m58s | 9m0s | 9m0s |
| weekday=Wed | 70 | 4m19s | 10m6s | 30m39s | 30m39s |
| hour=00 | 12 | 4m17s | 21m13s | 30m39s | 30m39s |
| hour=01 | 8 | 3m28s | 11m53s | 11m53s | 11m53s |
| hour=02 | 9 | 4m10s | 14m5s | 14m5s | 14m5s |
| hour=03 | 11 | 4m7s | 10m46s | 16m40s | 16m40s |
| hour=04 | 18 | 4m11s | 12m53s | 15m19s | 15m19s |
| hour=05 | 17 | 6m1s | 11m27s | 17m50s | 17m50s |
| hour=06 | 4 | 10m22s | 14m55s | 14m55s | 14m55s |
| hour=07 | 3 | 13m28s | 19m57s | 19m57s | 19m57s |
| hour=08 | 3 | 12m47s | 14m34s | 14m34s | 14m34s |
| hour=09 | 3 | 17m58s | 19m18s | 19m18s | 19m18s |
| hour=10 | 2 | 16m14s | 18m54s | 18m54s | 18m54s |
| hour=12 | 2 | 13m46s | 15m46s | 15m46s | 15m46s |
| hour=14 | 6 | 3m48s | 7m24s | 7m24s | 7m24s |
| hour=15 | 12 | 3m37s | 15m8s | 17m5s | 17m5s |
| hour=16 | 17 | 3m45s | 6m25s | 15m20s | 15m20s |
| hour=17 | 6 | 4m36s | 15m12s | 15m12s | 15m12s |
| hour=18 | 16 | 4m6s | 7m15s | 8m12s | 8m12s |
| hour=19 | 13 | 6m7s | 9m5s | 9m32s | 9m32s |
| hour=20 | 4 | 6m9s | 9m13s | 9m13s | 9m13s |
| hour=21 | 13 | 5m1s | 7m54s | 17m35s | 17m35s |
| hour=22 | 19 | 4m42s | 10m28s | 11m7s | 11m7s |
| hour=23 | 11 | 4m8s | 5m36s | 10m6s | 10m6s |
| rate_limited=false | 202 | 4m42s | 13m51s | 19m57s | 30m39s |
| rate_limited=true | 7 | 7m54s | 8m29s | 8m29s | 8m29s |

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
| ALL | 104 | 4m5s | 8m34s | 32m56s | 33m1s |
| additions_bucket=additions<=50 | 13 | 3m15s | 6m14s | 7m59s | 7m59s |
| additions_bucket=additions=151-300 | 14 | 4m9s | 7m17s | 9m40s | 9m40s |
| additions_bucket=additions=301-1000 | 35 | 4m35s | 29m20s | 33m1s | 33m1s |
| additions_bucket=additions=51-150 | 24 | 3m10s | 4m45s | 7m21s | 7m21s |
| additions_bucket=additions>1000 | 18 | 4m13s | 11m22s | 22m13s | 22m13s |
| weekday=Fri | 18 | 4m34s | 32m40s | 33m1s | 33m1s |
| weekday=Mon | 3 | 3m50s | 11m22s | 11m22s | 11m22s |
| weekday=Sat | 14 | 3m52s | 7m13s | 7m17s | 7m17s |
| weekday=Sun | 16 | 3m23s | 5m21s | 8m15s | 8m15s |
| weekday=Thu | 8 | 3m19s | 6m51s | 6m51s | 6m51s |
| weekday=Tue | 12 | 3m41s | 6m14s | 7m59s | 7m59s |
| weekday=Wed | 33 | 4m35s | 9m53s | 32m56s | 32m56s |
| hour=00 | 6 | 4m12s | 7m17s | 7m17s | 7m17s |
| hour=01 | 7 | 3m56s | 5m21s | 5m21s | 5m21s |
| hour=02 | 7 | 3m52s | 6m12s | 6m12s | 6m12s |
| hour=03 | 8 | 5m41s | 7m40s | 7m40s | 7m40s |
| hour=04 | 10 | 4m5s | 5m17s | 5m46s | 5m46s |
| hour=05 | 5 | 4m40s | 9m40s | 9m40s | 9m40s |
| hour=06 | 1 | 3m25s | 3m25s | 3m25s | 3m25s |
| hour=12 | 1 | 5m0s | 5m0s | 5m0s | 5m0s |
| hour=14 | 2 | 3m15s | 5m16s | 5m16s | 5m16s |
| hour=15 | 8 | 3m7s | 6m51s | 6m51s | 6m51s |
| hour=16 | 7 | 4m5s | 9m53s | 9m53s | 9m53s |
| hour=17 | 11 | 5m26s | 32m40s | 33m1s | 33m1s |
| hour=18 | 7 | 6m32s | 32m56s | 32m56s | 32m56s |
| hour=19 | 2 | 3m30s | 3m50s | 3m50s | 3m50s |
| hour=20 | 4 | 2m18s | 11m22s | 11m22s | 11m22s |
| hour=21 | 6 | 3m0s | 6m27s | 6m27s | 6m27s |
| hour=22 | 5 | 4m16s | 5m13s | 5m13s | 5m13s |
| hour=23 | 7 | 3m54s | 7m59s | 7m59s | 7m59s |
| rate_limited=false | 103 | 4m6s | 8m34s | 32m56s | 33m1s |
| rate_limited=true | 1 | 3m29s | 3m29s | 3m29s | 3m29s |

## 6_clearance_to_gate:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 57 | 2m18s | 49m32s | 5h10m | 5h10m |
| additions_bucket=additions<=50 | 8 | 6m43s | 5h10m | 5h10m | 5h10m |
| additions_bucket=additions=151-300 | 7 | 1m17s | 10m5s | 10m5s | 10m5s |
| additions_bucket=additions=301-1000 | 23 | 2m56s | 49m32s | 1h35m | 1h35m |
| additions_bucket=additions=51-150 | 8 | 2m11s | 2h15m | 2h15m | 2h15m |
| additions_bucket=additions>1000 | 11 | 58s | 4m48s | 11m38s | 11m38s |
| weekday=Fri | 7 | 2m18s | 2h15m | 2h15m | 2h15m |
| weekday=Mon | 1 | 1m17s | 1m17s | 1m17s | 1m17s |
| weekday=Sat | 2 | 2m4s | 5m13s | 5m13s | 5m13s |
| weekday=Sun | 5 | 2m26s | 1h22m | 1h22m | 1h22m |
| weekday=Thu | 16 | 1m16s | 14m18s | 49m32s | 49m32s |
| weekday=Tue | 9 | 10m5s | 5h10m | 5h10m | 5h10m |
| weekday=Wed | 17 | 1m3s | 28m52s | 1h10m | 1h10m |
| hour=00 | 3 | 4m48s | 1h22m | 1h22m | 1h22m |
| hour=01 | 3 | 19s | 1m9s | 1m9s | 1m9s |
| hour=02 | 5 | 54s | 17m38s | 17m38s | 17m38s |
| hour=03 | 8 | 4m2s | 2h15m | 2h15m | 2h15m |
| hour=04 | 3 | 1m4s | 49m32s | 49m32s | 49m32s |
| hour=06 | 1 | 58s | 58s | 58s | 58s |
| hour=07 | 1 | 28m52s | 28m52s | 28m52s | 28m52s |
| hour=08 | 3 | 11m38s | 1h10m | 1h10m | 1h10m |
| hour=09 | 2 | 14s | 25m22s | 25m22s | 25m22s |
| hour=14 | 1 | 9m40s | 9m40s | 9m40s | 9m40s |
| hour=15 | 2 | 4m18s | 14m18s | 14m18s | 14m18s |
| hour=17 | 2 | 1m3s | 1m16s | 1m16s | 1m16s |
| hour=18 | 6 | 2m4s | 1h35m | 1h35m | 1h35m |
| hour=19 | 5 | 1m17s | 10m3s | 10m3s | 10m3s |
| hour=21 | 1 | 2m18s | 2m18s | 2m18s | 2m18s |
| hour=22 | 5 | 27s | 44m23s | 44m23s | 44m23s |
| hour=23 | 6 | 5m13s | 5h10m | 5h10m | 5h10m |
| rate_limited=false | 57 | 2m18s | 49m32s | 5h10m | 5h10m |

## 6_clearance_to_gate:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 33 | 1m16s | 42m32s | 1h29m | 1h29m |
| additions_bucket=additions<=50 | 5 | 8m15s | 1h29m | 1h29m | 1h29m |
| additions_bucket=additions=151-300 | 2 | 1m18s | 4m3s | 4m3s | 4m3s |
| additions_bucket=additions=301-1000 | 12 | 1m3s | 42m32s | 1h1m | 1h1m |
| additions_bucket=additions=51-150 | 4 | 59s | 1h23m | 1h23m | 1h23m |
| additions_bucket=additions>1000 | 10 | 54s | 4m48s | 12m1s | 12m1s |
| weekday=Mon | 1 | 1m18s | 1m18s | 1m18s | 1m18s |
| weekday=Sat | 1 | 5m13s | 5m13s | 5m13s | 5m13s |
| weekday=Sun | 1 | 1h29m | 1h29m | 1h29m | 1h29m |
| weekday=Thu | 9 | 58s | 10m58s | 10m58s | 10m58s |
| weekday=Tue | 4 | 4m18s | 1h1m | 1h1m | 1h1m |
| weekday=Wed | 17 | 1m3s | 42m32s | 1h23m | 1h23m |
| hour=00 | 3 | 4m48s | 1h29m | 1h29m | 1h29m |
| hour=01 | 1 | 19s | 19s | 19s | 19s |
| hour=03 | 3 | 4m2s | 4m3s | 4m3s | 4m3s |
| hour=04 | 1 | 1m4s | 1m4s | 1m4s | 1m4s |
| hour=06 | 1 | 58s | 58s | 58s | 58s |
| hour=07 | 1 | 1h23m | 1h23m | 1h23m | 1h23m |
| hour=08 | 3 | 12m1s | 42m32s | 42m32s | 42m32s |
| hour=09 | 2 | 13s | 25m39s | 25m39s | 25m39s |
| hour=15 | 1 | 4m18s | 4m18s | 4m18s | 4m18s |
| hour=17 | 2 | 1m3s | 1m16s | 1m16s | 1m16s |
| hour=18 | 4 | 59s | 1h1m | 1h1m | 1h1m |
| hour=19 | 4 | 1m18s | 10m58s | 10m58s | 10m58s |
| hour=22 | 5 | 28s | 8m15s | 8m15s | 8m15s |
| hour=23 | 2 | 30s | 5m13s | 5m13s | 5m13s |
| rate_limited=false | 33 | 1m16s | 42m32s | 1h29m | 1h29m |

## 6_clearance_to_merge

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 66 | 4m56s | 7h39m | 118h50m | 118h50m |
| additions_bucket=additions<=50 | 14 | 1m41s | 7m32s | 7m59s | 7m59s |
| additions_bucket=additions=151-300 | 8 | 7m11s | 7h43m | 7h43m | 7h43m |
| additions_bucket=additions=301-1000 | 24 | 11m14s | 7h51m | 118h50m | 118h50m |
| additions_bucket=additions=51-150 | 9 | 2m49s | 39m57s | 39m57s | 39m57s |
| additions_bucket=additions>1000 | 11 | 7m44s | 16h13m | 16h24m | 16h24m |
| weekday=Fri | 7 | 19m37s | 16h13m | 16h13m | 16h13m |
| weekday=Mon | 1 | 7m11s | 7m11s | 7m11s | 7m11s |
| weekday=Sat | 5 | 3m55s | 51m26s | 51m26s | 51m26s |
| weekday=Sun | 5 | 40s | 6m10s | 6m10s | 6m10s |
| weekday=Thu | 16 | 5m14s | 4h14m | 118h50m | 118h50m |
| weekday=Tue | 9 | 7m44s | 4h37m | 4h37m | 4h37m |
| weekday=Wed | 23 | 4m0s | 7h43m | 16h24m | 16h24m |
| hour=00 | 4 | 1m24s | 17m1s | 17m1s | 17m1s |
| hour=01 | 4 | 55s | 29m36s | 29m36s | 29m36s |
| hour=02 | 7 | 3m55s | 37m12s | 37m12s | 37m12s |
| hour=03 | 8 | 4m45s | 39m10s | 39m10s | 39m10s |
| hour=04 | 4 | 7h43m | 118h50m | 118h50m | 118h50m |
| hour=05 | 1 | 27s | 27s | 27s | 27s |
| hour=06 | 1 | 1m41s | 1m41s | 1m41s | 1m41s |
| hour=07 | 1 | 39m57s | 39m57s | 39m57s | 39m57s |
| hour=08 | 3 | 7h39m | 7h51m | 7h51m | 7h51m |
| hour=09 | 2 | 1m20s | 6h46m | 6h46m | 6h46m |
| hour=14 | 1 | 4h14m | 4h14m | 4h14m | 4h14m |
| hour=15 | 2 | 13m20s | 23m29s | 23m29s | 23m29s |
| hour=17 | 3 | 7m26s | 9m26s | 9m26s | 9m26s |
| hour=18 | 8 | 4m0s | 4h37m | 4h37m | 4h37m |
| hour=19 | 5 | 6m12s | 7m59s | 7m59s | 7m59s |
| hour=21 | 1 | 4m4s | 4m4s | 4m4s | 4m4s |
| hour=22 | 5 | 2m3s | 16h24m | 16h24m | 16h24m |
| hour=23 | 6 | 7m32s | 16h13m | 16h13m | 16h13m |
| rate_limited=false | 66 | 4m56s | 7h39m | 118h50m | 118h50m |

## 6_gate_queue:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 57 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 8 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=151-300 | 7 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 23 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 8 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 11 | 0s | 0s | 0s | 0s |
| weekday=Fri | 7 | 0s | 0s | 0s | 0s |
| weekday=Mon | 1 | 0s | 0s | 0s | 0s |
| weekday=Sat | 2 | 0s | 0s | 0s | 0s |
| weekday=Sun | 5 | 0s | 0s | 0s | 0s |
| weekday=Thu | 16 | 0s | 0s | 0s | 0s |
| weekday=Tue | 9 | 0s | 0s | 0s | 0s |
| weekday=Wed | 17 | 0s | 0s | 0s | 0s |
| hour=00 | 3 | 0s | 0s | 0s | 0s |
| hour=01 | 3 | 0s | 0s | 0s | 0s |
| hour=02 | 5 | 0s | 0s | 0s | 0s |
| hour=03 | 8 | 0s | 0s | 0s | 0s |
| hour=04 | 3 | 0s | 0s | 0s | 0s |
| hour=06 | 1 | 0s | 0s | 0s | 0s |
| hour=07 | 1 | 0s | 0s | 0s | 0s |
| hour=08 | 3 | 0s | 0s | 0s | 0s |
| hour=09 | 2 | 0s | 0s | 0s | 0s |
| hour=14 | 1 | 0s | 0s | 0s | 0s |
| hour=15 | 2 | 0s | 0s | 0s | 0s |
| hour=17 | 2 | 0s | 0s | 0s | 0s |
| hour=18 | 6 | 0s | 0s | 0s | 0s |
| hour=19 | 5 | 0s | 0s | 0s | 0s |
| hour=21 | 1 | 0s | 0s | 0s | 0s |
| hour=22 | 5 | 0s | 0s | 0s | 0s |
| hour=23 | 6 | 0s | 0s | 0s | 0s |
| rate_limited=false | 57 | 0s | 0s | 0s | 0s |

## 6_gate_queue:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 33 | 0s | 0s | 0s | 0s |
| additions_bucket=additions<=50 | 5 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=151-300 | 2 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=301-1000 | 12 | 0s | 0s | 0s | 0s |
| additions_bucket=additions=51-150 | 4 | 0s | 0s | 0s | 0s |
| additions_bucket=additions>1000 | 10 | 0s | 0s | 0s | 0s |
| weekday=Mon | 1 | 0s | 0s | 0s | 0s |
| weekday=Sat | 1 | 0s | 0s | 0s | 0s |
| weekday=Sun | 1 | 0s | 0s | 0s | 0s |
| weekday=Thu | 9 | 0s | 0s | 0s | 0s |
| weekday=Tue | 4 | 0s | 0s | 0s | 0s |
| weekday=Wed | 17 | 0s | 0s | 0s | 0s |
| hour=00 | 3 | 0s | 0s | 0s | 0s |
| hour=01 | 1 | 0s | 0s | 0s | 0s |
| hour=03 | 3 | 0s | 0s | 0s | 0s |
| hour=04 | 1 | 0s | 0s | 0s | 0s |
| hour=06 | 1 | 0s | 0s | 0s | 0s |
| hour=07 | 1 | 0s | 0s | 0s | 0s |
| hour=08 | 3 | 0s | 0s | 0s | 0s |
| hour=09 | 2 | 0s | 0s | 0s | 0s |
| hour=15 | 1 | 0s | 0s | 0s | 0s |
| hour=17 | 2 | 0s | 0s | 0s | 0s |
| hour=18 | 4 | 0s | 0s | 0s | 0s |
| hour=19 | 4 | 0s | 0s | 0s | 0s |
| hour=22 | 5 | 0s | 0s | 0s | 0s |
| hour=23 | 2 | 0s | 0s | 0s | 0s |
| rate_limited=false | 33 | 0s | 0s | 0s | 0s |

## 6_gate_run:auto-clear-blocking-labels.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 57 | 14s | 25s | 1m17s | 1m17s |
| additions_bucket=additions<=50 | 8 | 10s | 20s | 20s | 20s |
| additions_bucket=additions=151-300 | 7 | 12s | 19s | 19s | 19s |
| additions_bucket=additions=301-1000 | 23 | 16s | 27s | 1m17s | 1m17s |
| additions_bucket=additions=51-150 | 8 | 11s | 26s | 26s | 26s |
| additions_bucket=additions>1000 | 11 | 15s | 19s | 25s | 25s |
| weekday=Fri | 7 | 12s | 19s | 19s | 19s |
| weekday=Mon | 1 | 9s | 9s | 9s | 9s |
| weekday=Sat | 2 | 14s | 15s | 15s | 15s |
| weekday=Sun | 5 | 9s | 12s | 12s | 12s |
| weekday=Thu | 16 | 14s | 19s | 25s | 25s |
| weekday=Tue | 9 | 10s | 21s | 21s | 21s |
| weekday=Wed | 17 | 18s | 27s | 1m17s | 1m17s |
| hour=00 | 3 | 12s | 13s | 13s | 13s |
| hour=01 | 3 | 14s | 16s | 16s | 16s |
| hour=02 | 5 | 12s | 14s | 14s | 14s |
| hour=03 | 8 | 9s | 18s | 18s | 18s |
| hour=04 | 3 | 19s | 20s | 20s | 20s |
| hour=06 | 1 | 14s | 14s | 14s | 14s |
| hour=07 | 1 | 25s | 25s | 25s | 25s |
| hour=08 | 3 | 25s | 27s | 27s | 27s |
| hour=09 | 2 | 13s | 27s | 27s | 27s |
| hour=14 | 1 | 19s | 19s | 19s | 19s |
| hour=15 | 2 | 18s | 25s | 25s | 25s |
| hour=17 | 2 | 14s | 19s | 19s | 19s |
| hour=18 | 6 | 17s | 1m17s | 1m17s | 1m17s |
| hour=19 | 5 | 13s | 17s | 17s | 17s |
| hour=21 | 1 | 17s | 17s | 17s | 17s |
| hour=22 | 5 | 15s | 20s | 20s | 20s |
| hour=23 | 6 | 10s | 16s | 16s | 16s |
| rate_limited=false | 57 | 14s | 25s | 1m17s | 1m17s |

## 6_gate_run:merge-clearance-gate.yml

| segment | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| ALL | 33 | 13s | 30s | 43s | 43s |
| additions_bucket=additions<=50 | 5 | 13s | 27s | 27s | 27s |
| additions_bucket=additions=151-300 | 2 | 9s | 13s | 13s | 13s |
| additions_bucket=additions=301-1000 | 12 | 12s | 30s | 43s | 43s |
| additions_bucket=additions=51-150 | 4 | 12s | 30s | 30s | 30s |
| additions_bucket=additions>1000 | 10 | 14s | 18s | 42s | 42s |
| weekday=Mon | 1 | 9s | 9s | 9s | 9s |
| weekday=Sat | 1 | 12s | 12s | 12s | 12s |
| weekday=Sun | 1 | 9s | 9s | 9s | 9s |
| weekday=Thu | 9 | 13s | 17s | 17s | 17s |
| weekday=Tue | 4 | 27s | 43s | 43s | 43s |
| weekday=Wed | 17 | 13s | 30s | 30s | 30s |
| hour=00 | 3 | 14s | 15s | 15s | 15s |
| hour=01 | 1 | 13s | 13s | 13s | 13s |
| hour=03 | 3 | 13s | 18s | 18s | 18s |
| hour=04 | 1 | 11s | 11s | 11s | 11s |
| hour=06 | 1 | 11s | 11s | 11s | 11s |
| hour=07 | 1 | 30s | 30s | 30s | 30s |
| hour=08 | 3 | 12s | 30s | 30s | 30s |
| hour=09 | 2 | 16s | 16s | 16s | 16s |
| hour=15 | 1 | 42s | 42s | 42s | 42s |
| hour=17 | 2 | 14s | 17s | 17s | 17s |
| hour=18 | 4 | 18s | 43s | 43s | 43s |
| hour=19 | 4 | 12s | 13s | 13s | 13s |
| hour=22 | 5 | 12s | 27s | 27s | 27s |
| hour=23 | 2 | 10s | 12s | 12s | 12s |
| rate_limited=false | 33 | 13s | 30s | 43s | 43s |

## Appendix: unclassified bot comments (top 20 shapes)

- (n=1) ### Review Result  * Reviewed the current PR head (`c2c2f0d`) and found no additional follow-up code changes necessary. * The major dev-grou
- (n=1) ### Summary  * No follow-up code changes were needed: the PR branch already contains the Codex eyes-acknowledgment gate, including polling t
- (n=1) ### Summary * I reviewed the trigger and PR context. The trigger content is a PR description/self-review, and the PR comments indicate this 
- (n=1) **Summary** * Added Phase 4a workflow guidance that callers must export `MERGEPATH_PHASE_4A_GATED=true` when `codex.request_by_default: fals
- (n=1) **Summary** * Updated `scripts/codex-review-request.sh` usage docs to include `--trigger-only`. [scripts/codex-review-request.shL9-L17](http
