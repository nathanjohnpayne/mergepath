#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's eyes-ack gate (#419).
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# tests exercise the production trigger/reaction flow without touching GitHub.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-ack.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local ack_wait=$2
  local max_retries=$3
  local review_timeout=${4:-0}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"

  cat >"$dir/.github/review-policy.yml" <<EOF
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  review_timeout_seconds: $review_timeout
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: $ack_wait
  max_ack_retries: $max_retries
EOF

  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODEX_TEST_STATE_DIR:?}

if [ "${1:-}" != "--" ] || [ "${2:-}" != "gh" ] || [ "${3:-}" != "pr" ] || [ "${4:-}" != "comment" ]; then
  echo "unexpected gh-as-author invocation: $*" >&2
  exit 97
fi
if [ "${8:-}" != "--body" ] || [ "${9:-}" != "@codex review" ]; then
  echo "trigger body was not exact '@codex review': $*" >&2
  exit 98
fi

count=0
if [ -f "$state_dir/trigger-count" ]; then
  count=$(cat "$state_dir/trigger-count")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/trigger-count"

# Record the author-PAT and author-identity env the wrapper sees, so
# the #438 inline-token bridging tests can assert what (if anything)
# was bridged in.
printf '%s\n' "${OP_PREFLIGHT_AUTHOR_PAT:-}" >>"$state_dir/author-pat-env"
printf '%s\n' "${GH_AS_AUTHOR_IDENTITY:-}" >>"$state_dir/author-identity-env"

comment_id=$((1000 + count))
printf '%s\n' "$comment_id" >>"$state_dir/trigger-comments"
if [ "${CODEX_TEST_SCENARIO:-}" = "no_comment_id" ]; then
  printf 'https://github.com/owner/repo/pull/999#discussion_r%s\n' "$comment_id"
  exit 0
fi
if [ "${CODEX_TEST_SCENARIO:-}" = "retry_no_comment_id" ] && [ "$count" -gt 1 ]; then
  printf 'https://github.com/owner/repo/pull/999#discussion_r%s\n' "$comment_id"
  exit 0
fi
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$comment_id"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODEX_TEST_STATE_DIR:?}
scenario=${CODEX_TEST_SCENARIO:?}
bot='chatgpt-codex-connector[bot]'
now='2026-06-04T00:00:00Z'

comment_time() {
  case "$1" in
    1001) printf '2026-06-04T00:00:00Z\n' ;;
    1002) printf '2026-06-04T00:00:10Z\n' ;;
    *) printf '%s\n' "$now" ;;
  esac
}

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 99
fi
shift

if [ "${1:-}" = "--paginate" ]; then
  shift
fi

endpoint=${1:-}

case "$endpoint" in
  repos/owner/repo/pulls/999)
    printf '{"head":{"sha":"head-sha"}}\n'
    ;;
  repos/owner/repo/commits/head-sha)
    printf '%s\n' "$now"
    ;;
  repos/owner/repo/issues/999/timeline)
    printf '[]\n'
    ;;
  repos/owner/repo/pulls/999/reviews)
    if [ "$scenario" = "review_after_retry" ]; then
      count=0
      if [ -f "$state_dir/trigger-count" ]; then
        count=$(cat "$state_dir/trigger-count")
      fi
      if [ "$count" -ge 2 ]; then
        printf '[{"id":77,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"head-sha","body":"review for original trigger"}]\n' "$bot"
      else
        printf '[]\n'
      fi
    else
      printf '[]\n'
    fi
    ;;
  repos/owner/repo/pulls/999/comments)
    printf '[]\n'
    ;;
  repos/owner/repo/issues/999/reactions)
    if [ "$scenario" = "skip_reaction" ]; then
      printf '[{"user":{"login":"%s"},"content":"+1","created_at":"2999-01-01T00:00:00Z","id":44}]\n' "$bot"
    else
      printf '[]\n'
    fi
    ;;
  repos/owner/repo/issues/comments/*/reactions)
    printf '%s\n' "$endpoint" >>"$state_dir/ack-endpoints"
    comment_id=${endpoint#repos/owner/repo/issues/comments/}
    comment_id=${comment_id%/reactions}
    if [ "$scenario" = "eyes_present" ]; then
      printf '[{"user":{"login":"%s"},"content":"eyes","created_at":"%s","id":55}]\n' "$bot" "$now"
    else
      printf '[]\n'
    fi
    printf '%s\n' "$comment_id" >>"$state_dir/ack-comments"
    ;;
  repos/owner/repo/issues/comments/*)
    comment_id=${endpoint#repos/owner/repo/issues/comments/}
    comment_time "$comment_id"
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  cat >"$dir/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${CODEX_TEST_FAKE_CLOCK:-0}" != "1" ]; then
  exec /bin/date "$@"
fi

state_dir=${CODEX_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi

if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  cat "$clock_file"
  exit 0
fi

exec /bin/date "$@"
EOF
  chmod +x "$dir/bin/date"

  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${CODEX_TEST_FAKE_CLOCK:-0}" != "1" ]; then
  exec /bin/sleep "$@"
fi

state_dir=${CODEX_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi

duration=${1:-0}
case "$duration" in
  *.*) duration=${duration%%.*} ;;
esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1
  local scenario=$2
  local fake_clock=${3:-0}
  local gh_token=${4:-test-token}
  local rc=0

  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="$gh_token" \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_FAKE_CLOCK="$fake_clock" \
      CODEX_TEST_SCENARIO="$scenario" \
      ./scripts/codex-review-request.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?

  printf '%s\n' "$rc"
}

trigger_count() {
  local dir=$1
  if [ -f "$dir/state/trigger-count" ]; then
    cat "$dir/state/trigger-count"
  else
    printf '0\n'
  fi
}

ack_endpoint_count() {
  local dir=$1
  if [ -f "$dir/state/ack-endpoints" ]; then
    wc -l <"$dir/state/ack-endpoints" | tr -d ' '
  else
    printf '0\n'
  fi
}

test_eyes_ack_does_not_retrigger_or_clear() {
  local dir rc count reaction
  dir=$(make_case "eyes-no-retrigger" 0 1)
  rc=$(run_case "$dir" eyes_present)
  count=$(trigger_count "$dir")
  reaction=$(jq -r '.reaction // "null"' "$dir/out.json")

  if [ "$rc" != "4" ]; then
    fail "eyes ack: exit $rc, expected 4 because eyes is not clearance; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "eyes ack: trigger count $count, expected 1; stderr=$(cat "$dir/err.log")"
  elif [ "$reaction" != "null" ]; then
    fail "eyes ack: JSON reaction was $reaction, expected null (+1-only contract)"
  else
    pass "eyes ack present: no re-trigger and eyes-only state does not clear"
  fi
}

test_missing_ack_retriggers_once() {
  local dir rc count
  dir=$(make_case "missing-one-retry" 0 1)
  rc=$(run_case "$dir" absent)
  count=$(trigger_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "missing ack one retry: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "missing ack one retry: trigger count $count, expected original + one retry"
  elif ! grep -q "re-posting '@codex review'" "$dir/err.log"; then
    fail "missing ack one retry: missing re-trigger log; stderr=$(cat "$dir/err.log")"
  else
    pass "missing eyes ack: exactly one re-trigger with max_ack_retries=1"
  fi
}

test_retry_cap_respected() {
  local dir rc count
  dir=$(make_case "missing-two-retries" 0 2)
  rc=$(run_case "$dir" absent)
  count=$(trigger_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "retry cap: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "3" ]; then
    fail "retry cap: trigger count $count, expected original + two retries"
  else
    pass "missing eyes ack: retry cap respected"
  fi
}

test_skip_path_posts_no_trigger_or_ack_check() {
  local dir rc count ack_count reaction_content
  dir=$(make_case "skip-path" 0 1)
  rc=$(run_case "$dir" skip_reaction)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")
  reaction_content=$(jq -r '.reaction.content' "$dir/out.json")

  if [ "$rc" != "0" ]; then
    fail "skip path: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "skip path: trigger count $count, expected 0"
  elif [ "$ack_count" != "0" ]; then
    fail "skip path: ack endpoint called $ack_count times, expected 0"
  elif [ "$reaction_content" != "+1" ]; then
    fail "skip path: reaction content $reaction_content, expected +1"
  else
    pass "cleared pre-flight skip path: no trigger and no ack check"
  fi
}

test_missing_comment_id_does_not_retrigger() {
  local dir rc count ack_count
  dir=$(make_case "missing-comment-id" 0 1)
  rc=$(run_case "$dir" no_comment_id)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "missing comment id: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "missing comment id: trigger count $count, expected no retry without a pollable id"
  elif [ "$ack_count" != "0" ]; then
    fail "missing comment id: ack endpoint called $ack_count times, expected 0"
  else
    pass "missing trigger comment id: ack gate skipped without re-trigger"
  fi
}

test_retry_missing_comment_id_stops_without_extra_retry() {
  local dir rc count ack_count
  dir=$(make_case "retry-missing-comment-id" 0 2)
  rc=$(run_case "$dir" retry_no_comment_id)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "retry missing comment id: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "retry missing comment id: trigger count $count, expected original + one retry only"
  elif [ "$ack_count" != "1" ]; then
    fail "retry missing comment id: ack endpoint called $ack_count times, expected only the first pollable trigger"
  else
    pass "retry with missing trigger comment id: gate stops without extra retry"
  fi
}

test_retry_resets_review_deadline() {
  local dir rc count elapsed
  dir=$(make_case "retry-resets-review-deadline" 5 1 12)
  rc=$(run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  elapsed=$(jq -r '.rounds_waited_seconds' "$dir/out.json")

  if [ "$rc" != "4" ]; then
    fail "retry deadline reset: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "retry deadline reset: trigger count $count, expected original + one retry"
  elif [ "$elapsed" != "20" ]; then
    fail "retry deadline reset: rounds_waited_seconds=$elapsed, expected 20 from latest trigger clock"
  else
    pass "retry re-post resets review timeout clock"
  fi
}

test_retry_preserves_original_trigger_response() {
  local dir rc count review_body review_time
  dir=$(make_case "retry-preserves-original-response" 0 1)
  rc=$(run_case "$dir" review_after_retry)
  count=$(trigger_count "$dir")
  review_body=$(jq -r '.review.body // "null"' "$dir/out.json")
  review_time=$(jq -r '.review.submitted_at // "null"' "$dir/out.json")

  if [ "$rc" != "0" ]; then
    fail "retry preserves original response: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "retry preserves original response: trigger count $count, expected original + one retry"
  elif [ "$review_body" != "review for original trigger" ]; then
    fail "retry preserves original response: review body=$review_body"
  elif [ "$review_time" != "2026-06-04T00:00:05Z" ]; then
    fail "retry preserves original response: review time=$review_time"
  else
    pass "retry preserves terminal response to original trigger"
  fi
}

test_ack_wait_window_is_bounded() {
  local dir rc count start end elapsed
  dir=$(make_case "bounded-wait" 1 0 1)
  start=$(date +%s)
  rc=$(run_case "$dir" absent)
  end=$(date +%s)
  elapsed=$((end - start))
  count=$(trigger_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "bounded wait: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "bounded wait: trigger count $count, expected no retry with max_ack_retries=0"
  elif [ "$elapsed" -lt 1 ]; then
    fail "bounded wait: elapsed ${elapsed}s, expected at least 1s ack window"
  elif ! grep -q "within 1s" "$dir/err.log"; then
    fail "bounded wait: missing bounded-window log; stderr=$(cat "$dir/err.log")"
  else
    pass "ack wait window is bounded and honored"
  fi
}

# --- inline author-PAT bridging (#438) --------------------------------

# identity-check stub used by the bridging tests: succeeds iff the
# ambient GH_TOKEN is the known author PAT and the expected identity
# is nathanjohnpayne (the policy default).
write_identity_check_stub() {
  local dir=$1
  cat >"$dir/scripts/identity-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--expect-token-identity" ] || exit 2
[ "${2:-}" = "nathanjohnpayne" ] || exit 1
[ "${GH_TOKEN:-}" = "author-pat-123" ] || exit 1
exit 0
EOF
  chmod +x "$dir/scripts/identity-check.sh"
}

bridged_pat() {
  local dir=$1
  if [ -f "$dir/state/author-pat-env" ]; then
    head -1 "$dir/state/author-pat-env"
  else
    printf ''
  fi
}

test_inline_author_pat_bridged_into_wrapper() {
  local dir rc pat
  dir=$(make_case "author-pat-bridged" 0 0)
  write_identity_check_stub "$dir"
  rc=$(run_case "$dir" absent 0 author-pat-123)
  pat=$(bridged_pat "$dir")

  if [ "$(trigger_count "$dir")" -lt 1 ]; then
    fail "author-pat bridge: no trigger was posted; stderr=$(cat "$dir/err.log")"
  elif [ "$pat" != "author-pat-123" ]; then
    fail "author-pat bridge: wrapper saw OP_PREFLIGHT_AUTHOR_PAT='$pat', expected the verified inline token; stderr=$(cat "$dir/err.log")"
  elif ! grep -q "bridging it into gh-as-author.sh" "$dir/err.log"; then
    fail "author-pat bridge: missing bridging log line; stderr=$(cat "$dir/err.log")"
  else
    pass "verified inline author PAT is bridged into gh-as-author.sh (rc=$rc)"
  fi
}

test_bridge_passes_configured_author_identity() {
  local dir rc pat identity
  dir=$(make_case "custom-author-bridge" 0 0)
  # Custom author_identity repo (Codex P2 on PR #442): the wrapper must
  # be told to verify the configured login, not its stock default.
  printf 'author_identity: custom-owner\n' >>"$dir/.github/review-policy.yml"
  cat >"$dir/scripts/identity-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--expect-token-identity" ] || exit 2
[ "${2:-}" = "custom-owner" ] || exit 1
[ "${GH_TOKEN:-}" = "author-pat-123" ] || exit 1
exit 0
EOF
  chmod +x "$dir/scripts/identity-check.sh"
  rc=$(run_case "$dir" absent 0 author-pat-123)
  pat=$(bridged_pat "$dir")
  identity=$(head -1 "$dir/state/author-identity-env" 2>/dev/null || printf '')

  if [ "$pat" != "author-pat-123" ]; then
    fail "custom-author bridge: wrapper saw OP_PREFLIGHT_AUTHOR_PAT='$pat', expected the verified inline token; stderr=$(cat "$dir/err.log")"
  elif [ "$identity" != "custom-owner" ]; then
    fail "custom-author bridge: wrapper saw GH_AS_AUTHOR_IDENTITY='$identity', expected 'custom-owner'; stderr=$(cat "$dir/err.log")"
  else
    pass "bridge passes the configured author_identity to the wrapper (rc=$rc)"
  fi
}

test_non_author_token_is_not_bridged() {
  local dir rc pat
  dir=$(make_case "reviewer-pat-not-bridged" 0 0)
  write_identity_check_stub "$dir"
  rc=$(run_case "$dir" absent 0 reviewer-pat-456)
  pat=$(bridged_pat "$dir")

  if [ "$(trigger_count "$dir")" -lt 1 ]; then
    fail "non-author token: no trigger was posted; stderr=$(cat "$dir/err.log")"
  elif [ -n "$pat" ]; then
    fail "non-author token: wrapper saw OP_PREFLIGHT_AUTHOR_PAT='$pat', expected empty (no bridge)"
  elif grep -q "bridging it into gh-as-author.sh" "$dir/err.log"; then
    fail "non-author token: bridging log line present for a non-author token"
  else
    pass "non-author inline token is NOT bridged; wrapper resolution unchanged (rc=$rc)"
  fi
}

test_non_bridge_path_passes_configured_identity() {
  local dir rc identity
  dir=$(make_case "custom-author-no-bridge" 0 0)
  # Custom author_identity, NO bridging (token does not verify) — the
  # wrapper must still be told the configured login (Codex P2 r5).
  # Single-quoted on purpose: the parser must strip both YAML quote
  # styles (Codex P2 r9).
  printf "author_identity: 'custom-owner'\n" >>"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" absent 0 reviewer-pat-456)
  identity=$(head -1 "$dir/state/author-identity-env" 2>/dev/null || printf '')

  if [ "$(trigger_count "$dir")" -lt 1 ]; then
    fail "non-bridge identity: no trigger was posted; stderr=$(cat "$dir/err.log")"
  elif [ "$identity" != "custom-owner" ]; then
    fail "non-bridge identity: wrapper saw GH_AS_AUTHOR_IDENTITY='$identity', expected 'custom-owner'; stderr=$(cat "$dir/err.log")"
  else
    pass "non-bridged invocation passes the configured author_identity (rc=$rc)"
  fi
}

test_missing_identity_checker_skips_bridge() {
  local dir rc pat
  dir=$(make_case "no-checker-no-bridge" 0 0)
  rc=$(run_case "$dir" absent 0 author-pat-123)
  pat=$(bridged_pat "$dir")

  if [ "$(trigger_count "$dir")" -lt 1 ]; then
    fail "missing checker: no trigger was posted; stderr=$(cat "$dir/err.log")"
  elif [ -n "$pat" ]; then
    fail "missing checker: wrapper saw OP_PREFLIGHT_AUTHOR_PAT='$pat', expected empty (bridge requires verification)"
  else
    pass "without identity-check.sh the bridge is skipped (verification-gated) (rc=$rc)"
  fi
}

test_eyes_ack_does_not_retrigger_or_clear
test_missing_ack_retriggers_once
test_retry_cap_respected
test_skip_path_posts_no_trigger_or_ack_check
test_missing_comment_id_does_not_retrigger
test_retry_missing_comment_id_stops_without_extra_retry
test_retry_resets_review_deadline
test_retry_preserves_original_trigger_response
test_ack_wait_window_is_bounded
test_inline_author_pat_bridged_into_wrapper
test_bridge_passes_configured_author_identity
test_non_author_token_is_not_bridged
test_non_bridge_path_passes_configured_identity
test_missing_identity_checker_skips_bridge

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
