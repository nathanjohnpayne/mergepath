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
#              affirmative verdict +9m → 👍 clearance +10m
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
[ "$n_triggers" = "3" ] && pass "classifies 3 triggers" || fail "triggers: got $n_triggers, want 3"

n_verdicts=$(jq -s '[ .[] | select(.kind == "verdict") ] | length' "$EVENTS")
[ "$n_verdicts" = "4" ] && pass "classifies 4 verdicts (incl. sha extraction)" || fail "verdicts: got $n_verdicts, want 4"

n_rl=$(jq -s '[ .[] | select(.kind == "rate_limit") ] | length' "$EVENTS")
[ "$n_rl" = "1" ] && pass "classifies the rate-limit marker comment" || fail "rate_limit: got $n_rl, want 1"

aff=$(jq -s '[ .[] | select(.kind == "verdict" and .pr == 11) ] | .[0].affirmative' "$EVENTS")
[ "$aff" = "false" ] && pass "findings verdict is non-affirmative" || fail "PR 11 verdict affirmative: got $aff"

# --- event pairs -------------------------------------------------------------

expect_pair "pair 1: trigger→👀 ack = 30s, round 1" \
  '.pair == "1_trigger_to_ack"' \
  '.seconds == 30 and .round == 1 and .pr == 10'

expect_pair "pair 2: trigger→first inline finding = 300s" \
  '.pair == "2_trigger_to_first_finding" and .pr == 10' \
  '.seconds == 300 and .round == 1'

expect_pair "pair 3 round 1: trigger→verdict = 540s, not rate-limited" \
  '.pair == "3_trigger_to_verdict" and .round == 1 and .pr == 10' \
  '.seconds == 540 and .rate_limited == false'

expect_pair "pair 3 round 2: trigger→verdict = 1800s, rate-limited segment" \
  '.pair == "3_trigger_to_verdict" and .round == 2' \
  '.seconds == 1800 and .rate_limited == true'

expect_pair "pair 4: trigger→👍 clearance = 600s" \
  '.pair == "4_trigger_to_thumbs_clearance"' \
  '.seconds == 600'

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
  '.pair == "6_clearance_to_merge"' \
  '.seconds == 1200 and .pr == 10'

expect_pair "pair 6: clearance→next merge-clearance-gate run = 300s" \
  '.pair == "6_clearance_to_gate:merge-clearance-gate.yml"' \
  '.seconds == 300 and .gate_event == "schedule"'

expect_pair "pair 6: gate queue delay = 420s (the #613 class of dead time)" \
  '.pair == "6_gate_queue:merge-clearance-gate.yml"' \
  '.seconds == 420'

expect_pair "pair 6: gate run duration = 90s" \
  '.pair == "6_gate_run:merge-clearance-gate.yml"' \
  '.seconds == 90'

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

grep -q '| rate_limited=true | 1 | 30m0s |' "$WORKDIR/summary.md" \
  && pass "summary.md segments rate-limited rounds (n/p50 rendered)" \
  || fail "summary.md missing rate_limited=true row with 30m0s p50"

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
