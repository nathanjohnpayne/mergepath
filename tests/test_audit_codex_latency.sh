#!/usr/bin/env bash
# tests/test_audit_codex_latency.sh
#
# Fixture tests for scripts/audit-codex-latency.sh's normalize + analysis
# phases (--analyze-only), which are the load-bearing part of the #623
# latency study: comment classification (trigger / verdict / rate-limit
# marker), event pairing for the six #623 event pairs, segmentation, the
# run-retention guard, and the percentile summary.
#
# The fetch phase is a thin `gh api --paginate` GET loop and is exercised
# against the live API, not here — these tests run fully offline over the
# committed fixture extract in tests/fixtures/audit-codex-latency/raw/.
# The fixture is synthetic TEST data for the pairing logic; the published
# #623 findings come only from real mined records (see the script header's
# method-constraint note).
#
# Fixture shape (2 PRs):
#   PR #10 (merged, 120 additions):
#     round 1: trigger @10:10 → 👀 ack +30s → inline finding +5m →
#              affirmative verdict +9m → 👍 clearance +10m (a PR-ISSUE
#              reaction, #645; a trigger-comment +1 distractor at +5m is
#              ignored — the gate reads 👍 from the PR issue, not the trigger)
#     round 2: trigger @12:10 → bot rate-limit marker +1m →
#              affirmative verdict +30m (round is rate-limited)
#     clearance @12:40 → merge-clearance-gate run created @12:45
#              (queued 7m, ran 1m30s) → merged @13:00
#     auto-clear-blocking-labels history starts @12:42 (> clearance) —
#              the retention guard must EXCLUDE that workflow's pairing.
#   PR #11 (open, 40 additions):
#     auto-review: reviewed-commit push @09:05 → verdict @09:30, no
#              trigger → pair 5, and a non-affirmative verdict must NOT
#              become a clearance.
#   PR #12 (open, 800 additions):
#     review-object-only auto-review (no trigger, no verdict comment).
#   PR #13 (open, 30 additions) — the owning-trigger regression case:
#     trigger @09:00 consumed by a verdict @09:05; a LATER push @09:30
#     answered by a review-only auto-review @09:40 with no fresh trigger
#     must still count as pair 5 (a prior-but-already-answered trigger
#     does not disqualify it).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-codex-latency.sh"
FIXTURE="$ROOT/tests/fixtures/audit-codex-latency"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (audit-codex-latency.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-codex-latency-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

cp -R "$FIXTURE/raw" "$WORKDIR/raw"

if ! bash "$SCRIPT" --analyze-only --out-dir "$WORKDIR" >/dev/null 2>"$WORKDIR/err.log"; then
  echo "FATAL: --analyze-only exited non-zero; stderr:" >&2
  cat "$WORKDIR/err.log" >&2
  exit 1
fi
pass "--analyze-only runs offline over the fixture extract"

PAIRS="$WORKDIR/pairs.jsonl"
EVENTS="$WORKDIR/events.jsonl"

# one_pair <test-label> <jq-filter over the single matching pair record>
expect_pair() {
  local label="$1" match="$2" check="$3" got
  got=$(jq -cs "[ .[] | select($match) ]" "$PAIRS")
  if [ "$(echo "$got" | jq 'length')" != "1" ]; then
    fail "$label: expected exactly 1 matching pair, got $(echo "$got" | jq length): $got"
    return
  fi
  if [ "$(echo "$got" | jq ".[0] | $check")" = "true" ]; then
    pass "$label"
  else
    fail "$label: check '$check' false for $(echo "$got" | jq -c '.[0]')"
  fi
}

# --- classification ----------------------------------------------------------

n_triggers=$(jq -s '[ .[] | select(.kind == "trigger") ] | length' "$EVENTS")
[ "$n_triggers" = "8" ] && pass "classifies 8 triggers" || fail "triggers: got $n_triggers, want 8"

n_verdicts=$(jq -s '[ .[] | select(.kind == "verdict") ] | length' "$EVENTS")
[ "$n_verdicts" = "7" ] && pass "classifies 7 verdicts (incl. sha extraction)" || fail "verdicts: got $n_verdicts, want 7"

n_rl=$(jq -s '[ .[] | select(.kind == "rate_limit") ] | length' "$EVENTS")
[ "$n_rl" = "2" ] && pass "classifies the rate-limit marker comments" || fail "rate_limit: got $n_rl, want 2"

aff=$(jq -s '[ .[] | select(.kind == "verdict" and .pr == 11) ] | .[0].affirmative' "$EVENTS")
[ "$aff" = "false" ] && pass "findings verdict is non-affirmative" || fail "PR 11 verdict affirmative: got $aff"

# --- event pairs -------------------------------------------------------------

expect_pair "pair 1: trigger→👀 ack = 30s, round 1" \
  '.pair == "1_trigger_to_ack"' \
  '.seconds == 30 and .round == 1 and .pr == 10'

expect_pair "pair 2: trigger→first inline finding = 300s" \
  '.pair == "2_trigger_to_first_finding" and .pr == 10' \
  '.seconds == 300 and .round == 1'

# PR 15's review is CLEAN (no inline comments): it must not register as a
# pair-2 finding (Codex P2 on #629) — only as the pair-2b first-response
# proxy.
n_pr15_p2=$(jq -s '[ .[] | select(.pair == "2_trigger_to_first_finding" and .pr == 15) ] | length' "$PAIRS")
[ "$n_pr15_p2" = "0" ] && pass "pair 2: clean (inline-less) review is not a finding" \
  || fail "PR 15 pair-2 records: got $n_pr15_p2, want 0"

expect_pair "pair 2b: clean review still counts as first review response = 300s" \
  '.pair == "2b_trigger_to_first_review_response" and .pr == 15' \
  '.seconds == 300'

# Round 2's rate-limit marker (12:06) falls INSIDE round 1's 2h window but
# AFTER round 2's trigger (12:05): the round-bounded rule must keep round 1
# clean (Codex P2 on #629).
expect_pair "pair 3 round 1: trigger→verdict = 540s, NOT tainted by round 2's marker" \
  '.pair == "3_trigger_to_verdict" and .round == 1 and .pr == 10' \
  '.seconds == 540 and .rate_limited == false'

# ...and the same marker CONSUMES round 2's trigger: the 12:40 verdict is
# not that trigger's response — it re-classifies as an auto-review
# anchored on the reviewed commit's push time (Codex P2 round 3 on #629).
n_r2_p3=$(jq -s '[ .[] | select(.pair == "3_trigger_to_verdict" and .pr == 10 and .round == 2) ] | length' "$PAIRS")
[ "$n_r2_p3" = "0" ] && pass "pair 3: failure marker consumes the trigger (no round-2 pairing)" \
  || fail "PR 10 round-2 pair-3 records: got $n_r2_p3, want 0"

expect_pair "pair 5: post-marker verdict re-classifies as auto-review (9900s from push)" \
  '.pair == "5_push_to_auto_review" and .pr == 10' \
  '.seconds == 9900'

# PR 16: a marker AFTER the verdict does not consume the round — the pair-3
# record survives and carries the rate_limited segment tag.
expect_pair "pair 3: post-verdict marker tags the segment without consuming the round" \
  '.pair == "3_trigger_to_verdict" and .pr == 16' \
  '.seconds == 600 and .rate_limited == true'

expect_pair "pair 4: trigger→👍 clearance = 600s" \
  '.pair == "4_trigger_to_thumbs_clearance" and .pr == 10' \
  '.seconds == 600'

# #645: the clearance 👍 is read from the PR ISSUE (pr_reactions.jsonl, +1
# @10:20 → 600s), NOT the trigger comment. reactions.jsonl carries a distractor
# +1 on the trigger comment @10:15; the OLD trigger-comment logic would have
# paired that (300s), so PR 10 must have exactly ONE pair-4 record at 600s.
n_pr10_p4=$(jq -s '[ .[] | select(.pair == "4_trigger_to_thumbs_clearance" and .pr == 10) ] | length' "$PAIRS")
[ "$n_pr10_p4" = "1" ] && pass "pair 4: trigger-comment +1 is ignored; only the PR-issue 👍 clears (#645)" \
  || fail "PR 10 pair-4 records: got $n_pr10_p4, want 1 (trigger-comment +1 must not count)"

expect_pair "pair 5: push→auto-review = 1500s (verdict with no owning trigger)" \
  '.pair == "5_push_to_auto_review" and .pr == 11' \
  '.seconds == 1500 and .additions_bucket == "additions<=50"'

# PR 12 has ONLY a review object (no verdict comment, no trigger): must
# still register as an auto-review. PR 11's review object 60s after its
# verdict comment is the same round and must NOT double-count (the
# expect_pair above already asserts exactly one PR-11 record).
expect_pair "pair 5: trigger-less review object counts as auto-review" \
  '.pair == "5_push_to_auto_review" and .pr == 12' \
  '.seconds == 1200'

# PR 13: the owning-trigger rule. Its 09:00 trigger was already answered
# by the 09:05 verdict, so the later review-only response to the 09:30
# push is an auto-review — a prior-but-consumed trigger must not
# disqualify it (CodeRabbit finding on #629).
expect_pair "pair 5: review-only round after an already-answered trigger counts" \
  '.pair == "5_push_to_auto_review" and .pr == 13' \
  '.seconds == 600'

expect_pair "pair 6: clearance→merge dead time = 1200s" \
  '.pair == "6_clearance_to_merge" and .pr == 10' \
  '.seconds == 1200'

# The 12:42:30 FAILED schedule run sits between PR 10's clearance (12:40)
# and the paired run: a non-success run cannot clear labels or satisfy the
# required check, so pairing must skip it (Codex P2 on #629).
expect_pair "pair 6: clearance→next SUCCESSFUL merge-clearance-gate run = 300s" \
  '.pair == "6_clearance_to_gate:merge-clearance-gate.yml"' \
  '.seconds == 300 and .gate_event == "schedule"'

expect_pair "pair 6: gate queue delay = 420s (the #613 class of dead time)" \
  '.pair == "6_gate_queue:merge-clearance-gate.yml"' \
  '.seconds == 420'

expect_pair "pair 6: gate run duration = 90s" \
  '.pair == "6_gate_run:merge-clearance-gate.yml"' \
  '.seconds == 90'

# PR 13's later review (09:40) came after the round was already closed by
# the 09:05 verdict: it must NOT be attributed as this trigger's first
# finding (Codex P2 on #629 — pair-2 windows stop at the verdict).
n_pr13_p2=$(jq -s '[ .[] | select(.pair == "2_trigger_to_first_finding" and .pr == 13) ] | length' "$PAIRS")
[ "$n_pr13_p2" = "0" ] && pass "pair 2: window stops at the round-closing verdict" \
  || fail "PR 13 pair-2 records: got $n_pr13_p2, want 0"

# PR 14: clearance @12:35, merged @12:40, first eligible success run @12:45
# postdates the merge — the gate leg is censored (skipped), never paired
# with a post-merge run (Codex P2 on #629); clearance→merge still measures.
expect_pair "pair 6: clearance→merge for PR 14 = 300s" \
  '.pair == "6_clearance_to_merge" and .pr == 14' \
  '.seconds == 300'
n_pr14_gate=$(jq -s '[ .[] | select((.pair | startswith("6_clearance_to_gate")) and .pr == 14) ] | length' "$PAIRS")
[ "$n_pr14_gate" = "0" ] && pass "pair 6: post-merge-only gate runs are censored, not paired" \
  || fail "PR 14 gate pairings: got $n_pr14_gate, want 0"

# PR 17 merged with an affirmative verdict whose reviewed sha does NOT
# prefix the merge head: the merge gate treats that verdict as stale, so
# it is not the operative clearance — no pair-6 records (Codex P2 round 3).
n_pr17_p6=$(jq -s '[ .[] | select((.pair | startswith("6_")) and .pr == 17) ] | length' "$PAIRS")
[ "$n_pr17_p6" = "0" ] && pass "pair 6: stale (non-head) affirmative verdict is not a clearance" \
  || fail "PR 17 pair-6 records: got $n_pr17_p6, want 0"

# PR 18: the trigger draws a not-connected marker (09:11) before the later
# review (09:40): the marker consumes the trigger for pair 2/2b exactly as
# it does for verdict pairing (4b P1 on #629) — no trigger-attributed
# rows; the review re-classifies as a push-anchored auto-review.
n_pr18_p2=$(jq -s '[ .[] | select((.pair == "2_trigger_to_first_finding"
  or .pair == "2b_trigger_to_first_review_response") and .pr == 18) ] | length' "$PAIRS")
[ "$n_pr18_p2" = "0" ] && pass "pair 2/2b: failure marker consumes the trigger (no pairing)" \
  || fail "PR 18 pair-2/2b records: got $n_pr18_p2, want 0"
expect_pair "pair 5: post-marker review re-classifies as auto-review (2400s)" \
  '.pair == "5_push_to_auto_review" and .pr == 18' \
  '.seconds == 2400'

# PR 19: the only 👍 (08:20) predates the merge-head push (10:00) — the
# gate treats it as stale (reaction_threshold = HEAD committer date), so
# it is not the operative clearance and pair 6 must fail closed (4b P1).
n_pr19_p6=$(jq -s '[ .[] | select((.pair | startswith("6_")) and .pr == 19) ] | length' "$PAIRS")
[ "$n_pr19_p6" = "0" ] && pass "pair 6: stale (pre-head-push) 👍 reaction is not a clearance" \
  || fail "PR 19 pair-6 records: got $n_pr19_p6, want 0"

# ...and PR 20's 👍 (09:30) postdates its head push (09:00): it IS the
# clearance — the head anchor must not over-exclude fresh reactions.
expect_pair "pair 6: post-head-push 👍 is the operative clearance (9000s to merge)" \
  '.pair == "6_clearance_to_merge" and .pr == 20' \
  '.seconds == 9000'

# --- events-only replay mode (reproducibility after retention) ---------------
REPLAY="$WORKDIR/replay"
mkdir -p "$REPLAY"
cp "$EVENTS" "$REPLAY/events.jsonl"
if bash "$SCRIPT" --analyze-only --out-dir "$REPLAY" >/dev/null 2>&1 \
   && diff -q "$REPLAY/pairs.jsonl" "$PAIRS" >/dev/null 2>&1; then
  pass "replay mode: --analyze-only reproduces pairs.jsonl from events.jsonl alone (no raw/)"
else
  fail "replay mode: events-only --analyze-only failed or diverged from the raw-dir run"
fi

# --- retention guard ---------------------------------------------------------
# auto-clear-blocking-labels' oldest retained run (12:42) postdates the
# clearance (12:40), so pairing against it would be a lie — the run that
# actually swept this clearance has been aged out. Must be excluded.
n_autoclear=$(jq -s '[ .[] | select(.pair | test("auto-clear-blocking-labels")) ] | length' "$PAIRS")
if [ "$n_autoclear" = "0" ]; then
  pass "retention guard: no pairing against a workflow whose history starts after the clearance"
else
  fail "retention guard: got $n_autoclear auto-clear pairings, want 0"
fi

# --- clearance semantics -----------------------------------------------------
# PR 11 is unmerged and its only verdict is non-affirmative: no pair-6
# records may exist for it (👀 is ack-only, findings-verdict is not
# clearance).
n_pr11_p6=$(jq -s '[ .[] | select((.pair | startswith("6_")) and .pr == 11) ] | length' "$PAIRS")
[ "$n_pr11_p6" = "0" ] && pass "no clearance pairing for unmerged PR with findings-only verdict" \
  || fail "PR 11 pair-6 records: got $n_pr11_p6, want 0"

# --- summary -----------------------------------------------------------------

grep -q '^## 3_trigger_to_verdict' "$WORKDIR/summary.md" \
  && pass "summary.md has per-pair sections" \
  || fail "summary.md missing 3_trigger_to_verdict section"

grep -q '| rate_limited=true | 1 | 10m0s |' "$WORKDIR/summary.md" \
  && pass "summary.md segments rate-limited rounds (n/p50 rendered)" \
  || fail "summary.md missing rate_limited=true row with 10m0s p50"

grep -q '^## Appendix: unclassified bot comments' "$WORKDIR/summary.md" \
  && pass "summary.md carries the unclassified-bot-comment diagnostics appendix" \
  || fail "summary.md missing diagnostics appendix"

# --- read-only guarantee -----------------------------------------------------
# The script must never perform a GitHub write: no gh write subcommands, no
# POST/PATCH/PUT/DELETE gh api calls, no graphql mutations. (Same class of
# guard as scripts/ci/check_no_bare_gh_writes, applied to the one script.)
if grep -nE 'gh (pr|issue) +(create|comment|edit|merge|review|close)|gh (repo|label) +(create|edit|delete)|gh api [^#]*(-X *|--method[= ]*)(POST|PATCH|PUT|DELETE)|gh api +graphql' "$SCRIPT"; then
  fail "read-only guarantee: found a write-class gh invocation in the script"
else
  pass "read-only guarantee: no write-class gh invocations present"
fi

echo
echo "test_audit_codex_latency: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
