#!/usr/bin/env bash
# tests/test_audit_review_latency.sh
#
# Fixture tests for scripts/audit-review-latency.sh's normalize + analysis
# (--analyze-only), the load-bearing part of the #623 CodeRabbit + phase-4b
# latency retune: the CodeRabbit review-object dedup (first REAL review per
# commit, empties dropped), the rate-limited interval segmentation, and the
# phase-4b adapter review-vs-abort split.
#
# The fetch phase is a thin `gh api --paginate` GET loop exercised against the
# live API, not here — these tests run fully offline by replaying a synthetic
# events.jsonl. The fixture is TEST data for the pairing logic; the published
# #623 findings come only from real mined records (see the script header's
# method-constraint note).
#
# Fixture (repo o/r):
#   PR 100 (merged, 200 add), commit aaaa1111 @10:00:00 on 06-01:
#     - real review @10:11:29 (+689s)  <- earliest real, the kept sample
#     - real review @10:15:00 (+900s)  <- later real on same commit, deduped out
#     - empty review @10:22:00         <- body-less (thread resolution), dropped
#   PR 101 (open, 500 add), commit bbbb2222 @10:00:00 on 06-02:
#     - rate-limit notice @10:02:00, then real review @10:20:00 (+1200s) —
#       the notice is INSIDE [commit, review] so rate_limited=true (segments
#       out of the normal-latency basis).
#   PR 102 (open, 80 add), commit cccc3333 @10:00:00 on 06-03:
#     - real review @10:05:00 (+300s), then a rate-limit notice @10:10:00
#       AFTER the review — the notice is OUTSIDE [commit, review] so the round
#       is rate_limited=false (interval bound, not just "any notice in the PR").
#   phase-4b: one UNAVAILABLE abort (elapsed 8s) + one CHANGES_REQUESTED
#     review (elapsed 600s) — split into distinct pairs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-review-latency.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (audit-review-latency.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-review-latency-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Synthetic normalized event stream (body-free, exactly what normalize emits).
cat >"$WORKDIR/events.jsonl" <<'EOF'
{"kind":"pr","repo":"o/r","pr":100,"additions":200,"merged_at":"2026-06-01T11:00:00Z","state":"closed"}
{"kind":"pr","repo":"o/r","pr":101,"additions":500,"merged_at":null,"state":"open"}
{"kind":"pr","repo":"o/r","pr":102,"additions":80,"merged_at":null,"state":"open"}
{"kind":"commit","repo":"o/r","sha":"aaaa1111","committer_date":"2026-06-01T10:00:00Z"}
{"kind":"commit","repo":"o/r","sha":"bbbb2222","committer_date":"2026-06-02T10:00:00Z"}
{"kind":"commit","repo":"o/r","sha":"cccc3333","committer_date":"2026-06-03T10:00:00Z"}
{"kind":"cr_review","repo":"o/r","pr":100,"review_id":1,"submitted_at":"2026-06-01T10:11:29Z","commit_id":"aaaa1111","state":"COMMENTED","real_review":true}
{"kind":"cr_review","repo":"o/r","pr":100,"review_id":2,"submitted_at":"2026-06-01T10:15:00Z","commit_id":"aaaa1111","state":"COMMENTED","real_review":true}
{"kind":"cr_review","repo":"o/r","pr":100,"review_id":3,"submitted_at":"2026-06-01T10:22:00Z","commit_id":"aaaa1111","state":"COMMENTED","real_review":false}
{"kind":"cr_ratelimit","repo":"o/r","pr":101,"comment_id":9,"created_at":"2026-06-02T10:02:00Z"}
{"kind":"cr_review","repo":"o/r","pr":101,"review_id":4,"submitted_at":"2026-06-02T10:20:00Z","commit_id":"bbbb2222","state":"COMMENTED","real_review":true}
{"kind":"cr_review","repo":"o/r","pr":102,"review_id":5,"submitted_at":"2026-06-03T10:05:00Z","commit_id":"cccc3333","state":"COMMENTED","real_review":true}
{"kind":"cr_ratelimit","repo":"o/r","pr":102,"comment_id":12,"created_at":"2026-06-03T10:10:00Z"}
{"kind":"pr","repo":"o/r","pr":104,"additions":100,"merged_at":null,"state":"open"}
{"kind":"pr","repo":"o/r","pr":105,"additions":100,"merged_at":null,"state":"open"}
{"kind":"commit","repo":"o/r","sha":"eeee5555","committer_date":"2026-06-04T10:00:00Z"}
{"kind":"cr_review","repo":"o/r","pr":104,"review_id":6,"submitted_at":"2026-06-04T10:10:00Z","commit_id":"eeee5555","state":"COMMENTED","real_review":true}
{"kind":"cr_review","repo":"o/r","pr":105,"review_id":7,"submitted_at":"2026-06-04T10:12:00Z","commit_id":"eeee5555","state":"COMMENTED","real_review":true}
{"kind":"p4b_round","reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","loop":1,"verdict":"UNAVAILABLE","fell_back":true,"elapsed_seconds":8,"timeout_seconds":900,"effort":"high"}
{"kind":"p4b_round","reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","loop":2,"verdict":"CHANGES_REQUESTED","fell_back":false,"elapsed_seconds":600,"timeout_seconds":900,"effort":"high"}
EOF

if ! bash "$SCRIPT" --analyze-only --out-dir "$WORKDIR" >/dev/null 2>"$WORKDIR/err.log"; then
  echo "FATAL: --analyze-only exited non-zero; stderr:" >&2
  cat "$WORKDIR/err.log" >&2
  exit 1
fi
pass "--analyze-only replays a committed events.jsonl offline"

PAIRS="$WORKDIR/pairs.jsonl"

# expect_pair <label> <select-filter> <check-filter>
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

# --- CodeRabbit review-object dedup -----------------------------------------
n_review=$(jq -s '[ .[] | select(.pair == "d_cr_review_latency") ] | length' "$PAIRS")
[ "$n_review" = "5" ] && pass "review dedup: 5 review pairs (PR100 3->1, PR101->1, PR102->1, PR104->1, PR105->1)" \
  || fail "d_cr_review_latency count: got $n_review, want 5 (empty + later-real drop; shared SHA keeps both PRs)"

# Dedup key is (repo, PR, commit): a commit SHA reviewed in TWO PRs must yield
# TWO samples (coderabbit-wait waits per PR), not one — the #688 P2 fix.
n_shared=$(jq -s '[ .[] | select(.pair == "d_cr_review_latency" and (.pr == 104 or .pr == 105)) ] | length' "$PAIRS")
[ "$n_shared" = "2" ] && pass "review dedup: shared SHA across PR104+PR105 keeps BOTH PR samples" \
  || fail "shared-SHA pairs: got $n_shared, want 2 (must not merge across PRs)"

expect_pair "review: PR100 keeps earliest REAL review (+689s), not the +900s or empty one" \
  '.pair == "d_cr_review_latency" and .pr == 100' \
  '.seconds == 689 and .rate_limited == false'

expect_pair "review: PR101 round with a rate-limit notice INSIDE [commit,review] is rate_limited=true" \
  '.pair == "d_cr_review_latency" and .pr == 101' \
  '.seconds == 1200 and .rate_limited == true'

expect_pair "review: PR102 rate-limit notice AFTER the review does NOT taint the round (interval bound)" \
  '.pair == "d_cr_review_latency" and .pr == 102' \
  '.seconds == 300 and .rate_limited == false'

# --- phase-4b adapter split -------------------------------------------------
expect_pair "phase-4b: UNAVAILABLE abort is a distinct pair (8s), not a review" \
  '.pair == "a_p4b_adapter_abort"' \
  '.seconds == 8'

expect_pair "phase-4b: verdict-producing round is the adapter review latency (600s)" \
  '.pair == "a_p4b_adapter_review"' \
  '.seconds == 600'

# --- summary.md renders ------------------------------------------------------
if grep -q '## d_cr_review_latency' "$WORKDIR/summary.md" 2>/dev/null; then
  pass "summary.md renders the per-pair percentile tables"
else
  fail "summary.md missing d_cr_review_latency section"
fi

# --- regression: the audit script must be plain text, not binary -------------
# A NUL byte in a jq key separator (Codex P3 on #688) turned the script into a
# binary file: `file` reported "binary data" and rg/grep silently skipped it,
# hiding line-level matches from review and search tooling. Keep it greppable.
if [ "$(LC_ALL=C tr -cd '\000' < "$SCRIPT" | wc -c | tr -d ' ')" = "0" ]; then
  pass "audit script is NUL-free (plain text, greppable)"
else
  fail "audit script contains NUL byte(s) — jq key separators must be printable"
fi

# --- regression: archived phase-4b loop logs are scanned (#688 P2) -----------
# read_phase4b_rounds must glob *.jsonl.archive too — the Phase-4b accounting
# hook rotates completed rounds out of the live *.jsonl into a .archive sibling
# once an approval/fallback posts, so a live-only scan drops every approved
# round. Run the full normalize path (raw/ present, so it is not the replay
# branch) over a loops dir holding one live + one archived round; assert BOTH
# are emitted.
ARCH_OUT="$WORKDIR/arch"
ARCH_LOOPS="$WORKDIR/loops"
mkdir -p "$ARCH_OUT/raw" "$ARCH_LOOPS"
: > "$ARCH_OUT/raw/pr_meta.jsonl"
: > "$ARCH_OUT/raw/commits.jsonl"
: > "$ARCH_OUT/raw/reviews.jsonl"
: > "$ARCH_OUT/raw/issue_comments.jsonl"
printf '%s\n' '{"schema":"p4b-loop-log/v1","started_at_epoch":1,"loop":{"reviewer":"r","adapter":"a","direction":"d","loop":1,"verdict":"CHANGES_REQUESTED","fell_back":false,"elapsed_seconds":500,"timeout_seconds":900,"effort":"high"},"details":[]}' > "$ARCH_LOOPS/live.jsonl"
printf '%s\n' '{"schema":"p4b-loop-log/v1","started_at_epoch":2,"loop":{"reviewer":"r","adapter":"a","direction":"d","loop":2,"verdict":"APPROVED","fell_back":false,"elapsed_seconds":700,"timeout_seconds":900,"effort":"high"},"details":[]}' > "$ARCH_LOOPS/done.jsonl.archive"
if bash "$SCRIPT" --analyze-only --loops-dir "$ARCH_LOOPS" --out-dir "$ARCH_OUT" >/dev/null 2>"$ARCH_OUT/err.log"; then
  n_p4b=$(jq -s '[ .[] | select(.kind == "p4b_round") ] | length' "$ARCH_OUT/events.jsonl")
  [ "$n_p4b" = "2" ] && pass "phase-4b: both live *.jsonl and *.jsonl.archive rounds are scanned" \
    || fail "p4b_round events: got $n_p4b, want 2 (archive glob missing?)"
else
  fail "archive-glob scenario: --analyze-only exited non-zero: $(cat "$ARCH_OUT/err.log" 2>/dev/null)"
fi

echo
echo "audit-review-latency: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
