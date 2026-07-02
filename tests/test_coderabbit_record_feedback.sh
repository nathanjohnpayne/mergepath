#!/usr/bin/env bash
# Regression coverage for scripts/coderabbit-record-feedback.sh (#584) — the
# DISPOSITION-ONLY CodeRabbit twin of tests/test_codex_record_feedback.sh.
#
# Runs the real script from a temp repo with a PATH-shimmed gh so the tests
# exercise the production verdict-mapping, coderabbit_tier_of classification,
# HEAD-pinned scan, idempotency/superseding ledger contract, and dry-run flow
# without touching GitHub.
#
# By-nature asymmetry (#574/#584): CodeRabbit does not solicit per-finding
# reactions, so there are NO reaction-posting cases here. Instead the suite
# carries a NEGATIVE guarantee: the gh stub records every invocation and the
# final test asserts the script issued ZERO write calls (no -X/--method
# anywhere) across every case.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/coderabbit-record-feedback.sh"

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (coderabbit-record-feedback.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-record-feedback.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

HEAD_SHA="head-sha-584"

# CodeRabbit finding bodies carrying the markers coderabbit_tier_of reads.
MINOR_BODY="**🟡 Minor**

Rename this local for clarity."
MAJOR_BODY="**⚠️ Potential issue** | **Major**

This pointer can be null."
PLAIN_BODY="A plain note with no severity marker."

# make_case <name> — scaffolds a temp repo with the real script + the real
# shared classifier lib, a recording gh stub, and a review-policy config.
# Echoes the case directory.
make_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts/lib" "$dir/bin" "$dir/.github" "$dir/state"

  cp "$SCRIPT" "$dir/scripts/coderabbit-record-feedback.sh"
  chmod +x "$dir/scripts/coderabbit-record-feedback.sh"
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"

  cat >"$dir/.github/review-policy.yml" <<'EOF'
coderabbit:
  bot_login: "coderabbitai[bot]"
EOF

  # Recording gh stub. Serves ONLY read endpoints; logs every argv line to
  # state/gh-calls.log; any -X/--method (a write marker) is additionally
  # logged to state/writes so the asymmetry test can assert zero writes.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${CRRF_STATE:?}
printf 'gh %s\n' "$*" >>"$state/gh-calls.log"
for a in "$@"; do
  case "$a" in
    -X|--method) printf '%s\n' "$*" >>"$state/writes" ;;
  esac
done
[ "${1:-}" = "api" ] || { echo "unexpected gh: $*" >&2; exit 9; }
shift
[ "${1:-}" = "--paginate" ] && shift
ep=${1:-}
case "$ep" in
  graphql) cat "${CRRF_FIXTURE_THREADS:?}" ;;
  repos/owner/repo/pulls/999/comments) cat "${CRRF_FIXTURE_COMMENTS:?}" ;;
  repos/owner/repo/pulls/999) cat "${CRRF_FIXTURE_PR:?}" ;;
  *) echo "unexpected gh api endpoint: $ep" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  # Default fixtures (cases override via env): PR metadata + an empty
  # threads page (every comment defaults to resolved=false).
  printf '{"number":999,"head":{"sha":"%s"}}\n' "$HEAD_SHA" >"$dir/pr.json"
  make_threads_fixture '[]' >"$dir/threads.json"

  printf '%s\n' "$dir"
}

# make_threads_fixture <nodes_expr> — GraphQL reviewThreads page (single
# page). nodes_expr is a jq expr for [{isResolved, comment_ids: [...]}].
make_threads_fixture() {
  local nodes_expr=$1
  jq -n "$nodes_expr | [ .[] | {
    id: \"T\",
    isResolved: .isResolved,
    comments: {
      pageInfo: { hasNextPage: false, endCursor: null },
      nodes: ([.comment_ids[] | {databaseId: .}])
    }
  }]" | jq '{
    data: { repository: { pullRequest: { reviewThreads: {
      pageInfo: { hasNextPage: false, endCursor: null },
      nodes: .
    } } } }
  }'
}

run_case() {
  # run_case <dir> -- <args...>
  local dir=$1; shift
  [ "${1:-}" = "--" ] && shift
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="test-token" \
      CRRF_STATE="$dir/state" \
      CRRF_FIXTURE_PR="${CRRF_FIXTURE_PR:-$dir/pr.json}" \
      CRRF_FIXTURE_COMMENTS="${CRRF_FIXTURE_COMMENTS:-/dev/null}" \
      CRRF_FIXTURE_THREADS="${CRRF_FIXTURE_THREADS:-$dir/threads.json}" \
      CODERABBIT_FEEDBACK_LEDGER="$dir/state/ledger.jsonl" \
      "$dir/scripts/coderabbit-record-feedback.sh" "$@" \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

ledger_file() { printf '%s\n' "$1/state/ledger.jsonl"; }
ledger_lines() {
  if [ -f "$1/state/ledger.jsonl" ]; then wc -l <"$1/state/ledger.jsonl" | tr -d ' '; else printf '0\n'; fi
}

REQUIRED_KEYS='["comment_id","pr","repo","head_sha","path","line","tier","verdict","disposition","reason","resolved","superseded_prior","recorded_at"]'

# --- tests -------------------------------------------------------------------

test_fixed_verdict_writes_ledger_row() {
  local dir rc
  dir=$(make_case "fixed-row")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "src/foo.ts", "line": 42, "comment_id": 5001,
    "body": $(jq -n --arg b "$MINOR_BODY" '$b') }
] }
EOF
  make_threads_fixture '[{isResolved: true, comment_ids: [5001]}]' >"$dir/threads.json"
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 5001=fixed)

  local row
  row=$(head -1 "$(ledger_file "$dir")" 2>/dev/null || printf '')
  if [ "$rc" != "0" ]; then
    fail "fixed row: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "fixed row: ledger has $(ledger_lines "$dir") lines, expected 1"
  elif ! printf '%s' "$row" | jq -e --argjson keys "$REQUIRED_KEYS" 'keys_unsorted as $have | $keys - $have == []' >/dev/null; then
    fail "fixed row: ledger row missing required keys; row=$row"
  elif [ "$(printf '%s' "$row" | jq -r '.disposition')" != "fixed" ]; then
    fail "fixed row: disposition was $(printf '%s' "$row" | jq -r '.disposition'), expected fixed"
  elif [ "$(printf '%s' "$row" | jq -r '.tier')" != "p2" ]; then
    fail "fixed row: tier was $(printf '%s' "$row" | jq -r '.tier'), expected p2 (🟡 Minor)"
  elif [ "$(printf '%s' "$row" | jq -r '.head_sha')" != "$HEAD_SHA" ]; then
    fail "fixed row: head_sha was $(printf '%s' "$row" | jq -r '.head_sha'), expected $HEAD_SHA"
  elif [ "$(printf '%s' "$row" | jq -r '.resolved')" != "true" ]; then
    fail "fixed row: resolved was $(printf '%s' "$row" | jq -r '.resolved'), expected true (thread isResolved)"
  elif [ "$(printf '%s' "$row" | jq -r '.superseded_prior')" != "false" ]; then
    fail "fixed row: superseded_prior was $(printf '%s' "$row" | jq -r '.superseded_prior'), expected false"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "recorded" ]; then
    fail "fixed row: summary action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected recorded"
  else
    pass "fixed verdict appends a valid ledger row (all required keys, tier p2, resolved bit, head-pinned)"
  fi
}

test_rebutted_verdict_records_reason() {
  local dir rc
  dir=$(make_case "rebutted-reason")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "src/bar.ts", "line": 7, "comment_id": 6001,
    "body": $(jq -n --arg b "$MAJOR_BODY" '$b') }
] }
EOF
  make_threads_fixture '[{isResolved: false, comment_ids: [6001]}]' >"$dir/threads.json"
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 6001=false-positive:"pointer is guarded two lines up")

  local row
  row=$(head -1 "$(ledger_file "$dir")" 2>/dev/null || printf '')
  if [ "$rc" != "0" ]; then
    fail "rebutted: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ "$(printf '%s' "$row" | jq -r '.disposition')" != "rebutted" ]; then
    fail "rebutted: disposition was $(printf '%s' "$row" | jq -r '.disposition'), expected rebutted"
  elif [ "$(printf '%s' "$row" | jq -r '.reason')" != "pointer is guarded two lines up" ]; then
    fail "rebutted: reason not recorded; row=$row"
  elif [ "$(printf '%s' "$row" | jq -r '.tier')" != "p1" ]; then
    fail "rebutted: tier was $(printf '%s' "$row" | jq -r '.tier'), expected p1 (⚠️ Potential issue)"
  elif [ "$(printf '%s' "$row" | jq -r '.resolved')" != "false" ]; then
    fail "rebutted: resolved was $(printf '%s' "$row" | jq -r '.resolved'), expected false"
  else
    pass "false-positive verdict records disposition rebutted with the rebuttal reason"
  fi
}

test_no_verdict_finding_skipped() {
  local dir rc
  dir=$(make_case "no-verdict")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "a", "line": 1, "comment_id": 7001, "body": $(jq -n --arg b "$MAJOR_BODY" '$b') },
  { "path": "b", "line": 2, "comment_id": 7002, "body": $(jq -n --arg b "$PLAIN_BODY" '$b') }
] }
EOF
  make_threads_fixture '[{isResolved: false, comment_ids: [7001, 7002]}]' >"$dir/threads.json"
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 7001=fixed)

  if [ "$rc" != "0" ]; then
    fail "no-verdict: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "no-verdict: ledger has $(ledger_lines "$dir") lines, expected 1 (no blanket rows)"
  elif [ "$(jq -r '[.skipped[] | select(.comment_id==7002 and .why=="no-verdict")] | length' "$dir/out.json")" != "1" ]; then
    fail "no-verdict: 7002 not reported as a no-verdict skip; out=$(cat "$dir/out.json")"
  else
    pass "a finding with no --verdict is skipped — no blanket ledger rows"
  fi
}

test_dry_run_writes_nothing() {
  local dir rc
  dir=$(make_case "dry-run")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "comment_id": 1101, "body": $(jq -n --arg b "$MINOR_BODY" '$b') }
] }
EOF
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 1101=fixed --dry-run)

  if [ "$rc" != "0" ]; then
    fail "dry-run: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "0" ]; then
    fail "dry-run: ledger written under --dry-run ($(ledger_lines "$dir") lines)"
  elif [ "$(jq -r '.dry_run' "$dir/out.json")" != "true" ]; then
    fail "dry-run: summary dry_run flag not true"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "dry_run" ]; then
    fail "dry-run: action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected dry_run"
  else
    pass "dry-run resolves verdicts and reports them but writes no ledger row"
  fi
}

test_unknown_verdict_exits_2_pre_write() {
  local dir rc
  dir=$(make_case "bad-verdict")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "comment_id": 1201, "body": $(jq -n --arg b "$MINOR_BODY" '$b') }
] }
EOF
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 1201=maybe)

  if [ "$rc" != "2" ]; then
    fail "bad-verdict: exit $rc, expected 2; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "0" ]; then
    fail "bad-verdict: a ledger row was written despite an invalid verdict"
  elif [ -f "$dir/state/gh-calls.log" ]; then
    fail "bad-verdict: gh was called before verdict validation; calls=$(cat "$dir/state/gh-calls.log")"
  else
    pass "an unrecognized verdict exits 2 before any write AND before any GitHub call"
  fi
}

test_idempotent_rerecord_noop() {
  local dir rc rc2 rc3
  dir=$(make_case "idempotent")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "comment_id": 9001, "body": $(jq -n --arg b "$MINOR_BODY" '$b') }
] }
EOF
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 9001=fixed)
  rc2=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 9001=fixed)
  # Alias-equivalent verdict: `real` maps to the same disposition (fixed), so
  # it must also be a no-op — idempotency keys on the NORMALIZED disposition.
  rc3=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 9001=real)

  if [ "$rc" != "0" ] || [ "$rc2" != "0" ] || [ "$rc3" != "0" ]; then
    fail "idempotent: exits $rc/$rc2/$rc3, expected 0/0/0; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "idempotent: ledger has $(ledger_lines "$dir") lines after re-records, expected 1"
  elif [ "$(jq -r '[.skipped[] | select(.comment_id==9001 and .why=="already-recorded")] | length' "$dir/out.json")" != "1" ]; then
    fail "idempotent: re-record not reported as already-recorded; out=$(cat "$dir/out.json")"
  else
    pass "re-recording the same disposition (incl. alias-equivalent verdicts) is a no-op"
  fi
}

test_superseding_verdict_appends_flagged_row() {
  local dir rc rc2
  dir=$(make_case "superseding")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "x", "line": 1, "comment_id": 9101, "body": $(jq -n --arg b "$MAJOR_BODY" '$b') }
] }
EOF
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 9101=fixed)
  rc2=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 9101=rebutted:"turned out to be a false positive")

  local last
  last=$(tail -1 "$(ledger_file "$dir")" 2>/dev/null || printf '')
  if [ "$rc" != "0" ] || [ "$rc2" != "0" ]; then
    fail "superseding: exits $rc/$rc2, expected 0/0; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "2" ]; then
    fail "superseding: ledger has $(ledger_lines "$dir") lines, expected 2 (append-only, no rewrites)"
  elif [ "$(printf '%s' "$last" | jq -r '.superseded_prior')" != "true" ]; then
    fail "superseding: last row superseded_prior was $(printf '%s' "$last" | jq -r '.superseded_prior'), expected true"
  elif [ "$(printf '%s' "$last" | jq -r '.disposition')" != "rebutted" ]; then
    fail "superseding: last row disposition was $(printf '%s' "$last" | jq -r '.disposition'), expected rebutted"
  elif [ "$(head -1 "$(ledger_file "$dir")" | jq -r '.disposition')" != "fixed" ]; then
    fail "superseding: prior row was rewritten (disposition no longer fixed)"
  elif [ "$(jq -r '.recorded[0].action' "$dir/out.json")" != "superseded_prior" ]; then
    fail "superseding: action was $(jq -r '.recorded[0].action' "$dir/out.json"), expected superseded_prior"
  else
    pass "a different disposition appends a superseding row flagged superseded_prior (prior row untouched)"
  fi
}

test_scan_is_head_pinned() {
  local dir rc
  dir=$(make_case "scan-head-pinned")
  # Inline comments: 4001 sits on the current HEAD; 4000 is a stale finding
  # from an earlier SHA (both commit_id and original_commit_id off-HEAD) —
  # the scan must collect ONLY 4001, and the 4000 verdict reports not-found.
  jq -n --arg sha "$HEAD_SHA" --arg minor "$MINOR_BODY" --arg major "$MAJOR_BODY" '
    [
      { id: 4000, user: {login: "coderabbitai[bot]"}, body: $major,
        path: "old.ts", line: 1, commit_id: "stale-sha", original_commit_id: "stale-sha" },
      { id: 4001, user: {login: "coderabbitai[bot]"}, body: $minor,
        path: "new.ts", line: 2, commit_id: $sha, original_commit_id: $sha },
      { id: 4002, user: {login: "somebody-else"}, body: $major,
        path: "human.ts", line: 3, commit_id: $sha, original_commit_id: $sha }
    ]
  ' >"$dir/comments.json"
  make_threads_fixture '[{isResolved: false, comment_ids: [4000, 4001, 4002]}]' >"$dir/threads.json"
  rc=$(CRRF_FIXTURE_COMMENTS="$dir/comments.json" \
    run_case "$dir" -- 999 --repo owner/repo --scan --verdict 4000=fixed --verdict 4001=fixed --verdict 4002=fixed)

  if [ "$rc" != "0" ]; then
    fail "scan head-pinned: exit $rc; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "scan head-pinned: ledger has $(ledger_lines "$dir") lines, expected 1 (only the HEAD bot finding)"
  elif [ "$(head -1 "$(ledger_file "$dir")" | jq -r '.comment_id')" != "4001" ]; then
    fail "scan head-pinned: recorded $(head -1 "$(ledger_file "$dir")" | jq -r '.comment_id'), expected 4001"
  elif [ "$(jq -r '[.skipped[] | select(.comment_id==4000 and .why=="not-found")] | length' "$dir/out.json")" != "1" ]; then
    fail "scan head-pinned: stale 4000 not reported not-found; out=$(cat "$dir/out.json")"
  elif [ "$(jq -r '[.skipped[] | select(.comment_id==4002 and .why=="not-found")] | length' "$dir/out.json")" != "1" ]; then
    fail "scan head-pinned: non-bot 4002 not reported not-found; out=$(cat "$dir/out.json")"
  else
    pass "scan collects only current-HEAD bot findings (stale-SHA and non-bot comments excluded)"
  fi
}

test_string_id_findings_json_matches_consistently() {
  # Regression for #617 (finding 3511089558): when --findings-json supplies the
  # comment_id as a STRING ("8001"), all three id-matching sites must agree.
  #
  # PRE-FIX this case FAILS: normalize_findings preserved the string, so the
  # main loop's lookup_verdict string-matched and recorded ONE row, while the
  # final not-found pass (numeric index($c)) missed it and ALSO reported the
  # same id as skipped:not-found — one adjudicated finding written resolved
  # AND reported not-found at once. The fix coerces the id to a number during
  # normalization, so exactly one row is written and zero not-found skips fire.
  local dir rc
  dir=$(make_case "string-id")
  cat >"$dir/findings.json" <<EOF
{ "findings": [
  { "path": "src/str.ts", "line": 12, "comment_id": "8001",
    "body": $(jq -n --arg b "$MINOR_BODY" '$b') }
] }
EOF
  make_threads_fixture '[{isResolved: true, comment_ids: [8001]}]' >"$dir/threads.json"
  rc=$(run_case "$dir" -- 999 --repo owner/repo --findings-json findings.json --verdict 8001=fixed)

  local row notfound
  row=$(head -1 "$(ledger_file "$dir")" 2>/dev/null || printf '')
  notfound=$(jq -r '[.skipped[] | select((.comment_id|tostring)=="8001" and .why=="not-found")] | length' "$dir/out.json")
  if [ "$rc" != "0" ]; then
    fail "string-id: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$(ledger_lines "$dir")" != "1" ]; then
    fail "string-id: ledger has $(ledger_lines "$dir") lines, expected 1"
  elif [ "$notfound" != "0" ]; then
    fail "string-id: id 8001 reported not-found $notfound time(s) despite being recorded; out=$(cat "$dir/out.json")"
  elif [ "$(printf '%s' "$row" | jq -r '.comment_id')" != "8001" ]; then
    fail "string-id: recorded comment_id was $(printf '%s' "$row" | jq -r '.comment_id'), expected 8001 (coerced to number)"
  elif [ "$(printf '%s' "$row" | jq -r '.comment_id|type')" != "number" ]; then
    fail "string-id: comment_id type was $(printf '%s' "$row" | jq -r '.comment_id|type'), expected number (coerced)"
  elif [ "$(printf '%s' "$row" | jq -r '.resolved')" != "true" ]; then
    fail "string-id: resolved was $(printf '%s' "$row" | jq -r '.resolved'), expected true (thread map matched by coerced id)"
  else
    pass "a string comment_id in --findings-json matches consistently (recorded once, no phantom not-found, resolved bit honored)"
  fi
}

test_never_posts_any_write() {
  # Asymmetry guarantee (#574/#584): across EVERY case above, the gh stub
  # must never have seen a write marker (-X / --method) — the recorder is
  # GETs only, and no reaction endpoint is ever touched.
  local writes_seen=0 d
  for d in "$WORKDIR"/*/; do
    [ -d "$d/state" ] || continue
    if [ -f "$d/state/writes" ]; then
      writes_seen=1
      fail "never-posts: gh write call recorded in ${d}state/writes: $(cat "$d/state/writes")"
    fi
    if [ -f "$d/state/gh-calls.log" ] && grep -qE 'reactions' "$d/state/gh-calls.log"; then
      writes_seen=1
      fail "never-posts: a reactions endpoint was touched: $(grep reactions "$d/state/gh-calls.log")"
    fi
  done
  if [ "$writes_seen" -eq 0 ]; then
    pass "the recorder never issues a gh write (zero -X/--method calls, zero reactions endpoints) across all cases"
  fi
}

test_fixed_verdict_writes_ledger_row
test_rebutted_verdict_records_reason
test_no_verdict_finding_skipped
test_dry_run_writes_nothing
test_unknown_verdict_exits_2_pre_write
test_idempotent_rerecord_noop
test_superseding_verdict_appends_flagged_row
test_scan_is_head_pinned
test_string_id_findings_json_matches_consistently
test_never_posts_any_write

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
