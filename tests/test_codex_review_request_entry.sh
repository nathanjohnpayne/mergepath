#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's Phase 4a entry
# decision (#486): codex.request_by_default + codex.enabled gating of
# whether an `@codex review` trigger is posted at all. It also locks the
# #1085 handoff contract: a real, confirmed request that reaches the ordinary
# timeout path must leave a durable exact-head terminal marker for Phase 4b.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so
# the tests exercise the production entry-gate without touching GitHub.
# The skip cases (exit 5) short-circuit BEFORE any gh call, so the stubs
# only matter on the trigger-posting cases.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-entry.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a case directory with a review-policy.yml whose codex: block is
# exactly the lines passed as $2 (a newline-joined string of "  key: val"
# entries), and stubbed gh / gh-as-author. The gh stub always reports a
# HEAD with no Codex signal so a posted trigger times out (exit 4) and a
# skip is unambiguously exit 5.
make_case() {
  local name=$1
  local codex_block=$2
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced

  {
    printf 'codex:\n'
    printf '%s\n' "$codex_block"
    # Zero review timeout so a posted trigger reaches the deadline
    # immediately and the case finishes fast (still exits 4, not 0).
    printf '  review_timeout_seconds: 0\n'
    printf '  reaction_freshness_window_seconds: 999999999\n'
    printf '  ack_wait_seconds: 0\n'
    printf '  max_ack_retries: 0\n'
  } >"$dir/.github/review-policy.yml"

  # gh-as-author records triggers and Phase 4a terminal markers separately.
  # The real wrapper receives either --body or --body-file after `--`.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
body=''
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body=${2-}; shift 2 ;;
    --body-file)
      body=$(cat "${2-}"; printf x)
      body=${body%x}
      shift 2
      ;;
    *) shift ;;
  esac
done
case "$body" in
  '@codex review') kind=trigger ;;
  '<!-- mergepath-phase-4a-terminal:'*) kind=terminal ;;
  *) echo "unexpected author comment body: $body" >&2; exit 98 ;;
esac
count=0
[ -f "$state_dir/$kind-count" ] && count=$(cat "$state_dir/$kind-count")
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/$kind-count"
printf '%s\n' "$body" >"$state_dir/$kind-body"
post_count=0
[ -f "$state_dir/post-count" ] && post_count=$(cat "$state_dir/post-count")
post_count=$((post_count + 1))
printf '%s\n' "$post_count" >"$state_dir/post-count"
comment_id=$((1000 + post_count))
jq -cn --argjson id "$comment_id" --arg body "$body" --arg created "2026-06-17T00:00:0${post_count}Z" \
  '{id:$id,user:{login:"nathanjohnpayne"},body:$body,created_at:$created}' >>"$state_dir/comments.jsonl"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$comment_id"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
now='2026-06-17T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
[ "${1:-}" = "--paginate" ] && shift
endpoint=${1:-}
case "$endpoint" in
  repos/owner/repo/pulls/999)
    if [ "${2:-}" = "--jq" ]; then
      printf '%s\n' "${CODEX_TEST_LIVE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    else
      printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
    fi ;;
  repos/owner/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) printf '%s\n' "$now" ;;
  repos/owner/repo/issues/999/timeline)      printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)        printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)       printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions)     printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    if [ -f "${CODEX_TEST_STATE_DIR:?}/comments.jsonl" ]; then
      jq -sc '.' "${CODEX_TEST_STATE_DIR:?}/comments.jsonl"
    else
      printf '[]\n'
    fi ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*)        printf '%s\n' "$now" ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

# Run a case; echoes the exit code. $3 = MERGEPATH_PHASE_4A_GATED value.
run_case() {
  local dir=$1
  local gated=${2:-}
  local live_head=${3:-$TEST_HEAD}
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="test-token" \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_LIVE_HEAD="$live_head" \
      MERGEPATH_PHASE_4A_GATED="$gated" \
      ./scripts/codex-review-request.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

trigger_count() {
  local dir=$1
  [ -f "$dir/state/trigger-count" ] && cat "$dir/state/trigger-count" || printf '0\n'
}

terminal_count() {
  local dir=$1
  [ -f "$dir/state/terminal-count" ] && cat "$dir/state/terminal-count" || printf '0\n'
}

terminal_body() {
  local dir=$1
  [ -f "$dir/state/terminal-body" ] && cat "$dir/state/terminal-body" || true
}

# --- defaults: absent keys ⇒ request on every PR (backward compat) ----------
test_defaults_request_on_every_pr() {
  local dir rc count requested terminals body expected
  dir=$(make_case "defaults" "  bot_login: \"chatgpt-codex-connector[bot]\"")
  rc=$(run_case "$dir")
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  body=$(terminal_body "$dir")
  expected="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=1001 -->"
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  if [ "$rc" != "4" ]; then
    fail "defaults: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "defaults: trigger count $count, expected 1"
  elif [ "$requested" != "true" ]; then
    fail "defaults: trigger_requested=$requested, expected true"
  elif [ "$terminals" != "1" ]; then
    fail "defaults: terminal marker count $terminals, expected 1 after a confirmed ordinary timeout (#1085)"
  elif [ "$body" != "$expected" ]; then
    fail "defaults: terminal marker body '$body', expected '$expected'"
  else
    pass "absent enabled/request_by_default ⇒ trigger posted and ordinary timeout is durably head-pinned for Phase 4b (#1085)"
  fi
}

# --- request_by_default: true ⇒ under-threshold PR still triggers -----------
test_request_by_default_true_triggers_under_threshold() {
  local dir rc count
  dir=$(make_case "rbd-true" "  enabled: true"$'\n'"  request_by_default: true")
  # Not gated (under threshold).
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "rbd true: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "rbd true: trigger count $count, expected 1"
  else
    pass "request_by_default:true ⇒ under-threshold PR gets a trigger"
  fi
}

# --- single-quoted booleans ⇒ quotes stripped before the == "true" gate -----
# Valid single-quoted YAML (`request_by_default: 'true'`, `enabled: 'true'`)
# must parse as the boolean true, not the literal string "'true'". Before the
# codex_field quote-stripping fix this triggered the wrong skip (exit 5).
test_single_quoted_booleans_trigger_under_threshold() {
  local dir rc count
  dir=$(make_case "rbd-single-quoted" \
    "  enabled: 'true'"$'\n'"  request_by_default: 'true'")
  # Not gated (under threshold): only request_by_default can drive the trigger.
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "single-quoted: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "single-quoted: trigger count $count, expected 1 (quotes must be stripped before == \"true\")"
  else
    pass "single-quoted enabled/request_by_default ⇒ quotes stripped, trigger posted"
  fi
}

# --- request_by_default: false + not gated ⇒ skip (exit 5, no trigger) ------
test_request_by_default_false_skips_under_threshold() {
  local dir rc count requested head terminal_shape
  dir=$(make_case "rbd-false" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  head=$(jq -r '.head_sha' "$dir/out.json")
  terminal_shape=$(jq -r 'has("terminal_determination") and (.terminal_determination == null)' "$dir/out.json")
  if [ "$rc" != "5" ]; then
    fail "rbd false ungated: exit $rc, expected 5 (NO_TRIGGER_REQUESTED); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "rbd false ungated: trigger count $count, expected 0 (no trigger)"
  elif [ "$requested" != "false" ]; then
    fail "rbd false ungated: trigger_requested=$requested, expected false"
  elif [ "$head" != "null" ]; then
    fail "rbd false ungated: head_sha=$head, expected null (skipped before PR fetch)"
  elif [ "$terminal_shape" != "true" ]; then
    fail "rbd false ungated: terminal_determination must be present and null"
  else
    pass "request_by_default:false + under-threshold ⇒ skip with exit 5"
  fi
}

# --- request_by_default: false + gated ⇒ trigger (pre-#486 behavior) --------
test_request_by_default_false_triggers_when_gated() {
  local dir rc count
  dir=$(make_case "rbd-false-gated" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "rbd false gated: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "rbd false gated: trigger count $count, expected 1"
  else
    pass "request_by_default:false + Phase-4a-gated ⇒ trigger posted"
  fi
}

# --- enabled: false ⇒ never trigger, even with request_by_default: true -----
test_enabled_false_never_triggers() {
  local dir rc count
  dir=$(make_case "enabled-false" "  enabled: false"$'\n'"  request_by_default: true")
  # Gated AND request_by_default true — must STILL skip because Codex is off.
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" != "5" ]; then
    fail "enabled false: exit $rc, expected 5 (NO_TRIGGER_REQUESTED); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "enabled false: trigger count $count, expected 0"
  elif ! grep -q "codex.enabled is false" "$dir/err.log"; then
    fail "enabled false: missing 'codex.enabled is false' log; stderr=$(cat "$dir/err.log")"
  else
    pass "enabled:false ⇒ no trigger regardless of request_by_default (orthogonality)"
  fi
}

# --- timeout record is fenced against a push landing before the write -------
test_timeout_head_drift_fails_closed_without_marker() {
  local dir rc count terminals moved
  dir=$(make_case "timeout-head-drift" "  enabled: true"$'\n'"  request_by_default: true")
  moved=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  rc=$(run_case "$dir" false "$moved")
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  if [ "$rc" != "3" ]; then
    fail "timeout head drift: exit $rc, expected 3 (infrastructure/drift, not a timeout waiver); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "timeout head drift: trigger count $count, expected 1"
  elif [ "$terminals" != "0" ]; then
    fail "timeout head drift: terminal marker count $terminals, expected 0"
  elif ! grep -q "head moved from $TEST_HEAD to $moved" "$dir/err.log"; then
    fail "timeout head drift: missing distinct drift diagnostic; stderr=$(cat "$dir/err.log")"
  else
    pass "ordinary timeout refuses to record after head drift; no stale-head waiver is written (#1085)"
  fi
}

# --- a newer request on the same head supersedes an older timeout -----------
test_new_trigger_replaces_superseded_timeout_marker() {
  local dir rc count terminals body expected marker final_state
  dir=$(make_case "superseded-timeout" "  enabled: true"$'\n'"  request_by_default: true")
  marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=900 -->"
  jq -cn '{id:900,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-06-16T23:45:00Z"}' \
    >"$dir/state/comments.jsonl"
  jq -cn --arg body "$marker" \
    '{id:901,user:{login:"nathanjohnpayne"},body:$body,created_at:"2026-06-16T23:59:00Z"}' \
    >>"$dir/state/comments.jsonl"

  rc=$(run_case "$dir")
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  body=$(terminal_body "$dir")
  expected="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=1001 -->"
  final_state=$(jq -sc '.' "$dir/state/comments.jsonl" | \
    bash -c 'source "$1/scripts/lib/codex-failure-markers.sh"; comments=$(cat); codex_phase4a_timeout_marker_state "$2" nathanjohnpayne "$comments"' \
      _ "$dir" "$TEST_HEAD" | jq -r '.state + ":" + (.trigger_comment_id | tostring)')

  if [ "$rc" != "4" ]; then
    fail "superseded timeout: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "superseded timeout: new trigger count $count, expected 1"
  elif [ "$terminals" != "1" ]; then
    fail "superseded timeout: new terminal count $terminals, expected 1"
  elif [ "$body" != "$expected" ]; then
    fail "superseded timeout: terminal body '$body', expected '$expected'"
  elif [ "$final_state" != "current:1001" ]; then
    fail "superseded timeout: final parser state '$final_state', expected current:1001"
  else
    pass "a newer same-head request supersedes the old timeout; only its own timeout may reopen Phase 4b"
  fi
}

test_defaults_request_on_every_pr
test_request_by_default_true_triggers_under_threshold
test_single_quoted_booleans_trigger_under_threshold
test_request_by_default_false_skips_under_threshold
test_request_by_default_false_triggers_when_gated
test_enabled_false_never_triggers
test_timeout_head_drift_fails_closed_without_marker
test_new_trigger_replaces_superseded_timeout_marker

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
