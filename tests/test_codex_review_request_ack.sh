#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's eyes-ack gate (#419).
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# tests exercise the production trigger/reaction flow without touching GitHub.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-ack.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# #951: a diagnostic must never carry a value that could be a credential.
# The bridge assertions below read whatever OP_PREFLIGHT_AUTHOR_PAT the
# wrapper saw; on a developer or agent machine that can be a LIVE PAT, and
# these messages land in CI logs, shell scrollback and agent transcripts.
# So describe the value instead of quoting it. Two facts are enough to
# debug every case this file asserts — is it empty, and how long is it —
# plus a classification drawn from a CLOSED set of well-known GitHub token
# prefixes. The classification is a fixed constant, never a slice of the
# value, so nothing here is reversible into the credential.
describe_secret() {
  local value=${1:-}
  local kind='opaque'
  if [ -z "$value" ]; then
    printf 'empty'
    return 0
  fi
  case "$value" in
    github_pat_*) kind='fine-grained GitHub PAT' ;;
    ghp_*) kind='classic GitHub PAT' ;;
    gho_*|ghu_*|ghs_*|ghr_*) kind='GitHub token' ;;
  esac
  printf '<redacted %s, %s chars>' "$kind" "${#value}"
}

make_case() {
  local name=$1
  local ack_wait=$2
  local max_retries=$3
  local review_timeout=${4:-0}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  # #799: codex-review-request.sh HARD-sources this lib (exit 3 if absent),
  # because the read it guards anchors every freshness comparison in the poll
  # loop. Fixture trees must stage the real one.
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"
  # #1008: the array twin, hard-sourced for the same reason — every signal
  # the poll loop scans for arrives through it.
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"
  cp "$ROOT/scripts/lib/codex-request-evidence.sh" "$dir/scripts/lib/codex-request-evidence.sh"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"

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
if [ -f "$state_dir/$kind-count" ]; then
  count=$(cat "$state_dir/$kind-count")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/$kind-count"

# Record the author-PAT and author-identity env the wrapper sees, so
# the #438 inline-token bridging tests can assert what (if anything)
# was bridged in.
printf '%s\n' "${OP_PREFLIGHT_AUTHOR_PAT:-}" >>"$state_dir/author-pat-env"  # TOKEN_OUTPUT_EXEMPT: run_case unsets both PATs (#993), so this records only what the bridge injected, and the assertions compare it exactly (#996)
printf '%s\n' "${GH_AS_AUTHOR_IDENTITY:-}" >>"$state_dir/author-identity-env"

post_count=0
[ -f "$state_dir/post-count" ] && post_count=$(cat "$state_dir/post-count")
post_count=$((post_count + 1))
printf '%s\n' "$post_count" >"$state_dir/post-count"
comment_id=$((1000 + post_count))
created_at="2026-06-04T00:00:$(printf '%02d' "$((post_count - 1))")Z"
if [ "${CODEX_TEST_SCENARIO:-}" = "fresh-terminal-finding" ]; then
  created_at="2026-06-04T00:00:$(printf '%02d' "$((post_count + 9))")Z"
fi
jq -cn --argjson id "$comment_id" --arg who "${GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}" \
  --arg body "$body" --arg created "$created_at" \
  '{id:$id,user:{login:$who},body:$body,created_at:$created}' >>"$state_dir/comments.jsonl"
if [ "$kind" = trigger ]; then
  printf '%s\n' "$comment_id" >>"$state_dir/trigger-comments"
fi
if [ "$kind" = trigger ] && [ "${CODEX_TEST_SCENARIO:-}" = "no_comment_id" ]; then
  printf 'https://github.com/owner/repo/pull/999#discussion_r%s\n' "$comment_id"
  exit 0
fi
if [ "$kind" = trigger ] && [ "${CODEX_TEST_SCENARIO:-}" = "retry_no_comment_id" ] && [ "$count" -gt 1 ]; then
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
    1001)
      if [ "$scenario" = "fresh-terminal-finding" ]; then
        # The pre-existing finding is after the reused trigger but before this
        # new write, so it must not be accepted as this write's response.
        printf '2026-06-04T00:00:10Z\n'
      else
        printf '2026-06-04T00:00:00Z\n'
      fi
      ;;
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
    if [ "$scenario" = "head-drift" ]; then
      reads=0
      [ ! -f "$state_dir/head-reads" ] || reads=$(cat "$state_dir/head-reads")
      reads=$((reads + 1))
      printf '%s\n' "$reads" >"$state_dir/head-reads"
      if [ "$reads" -gt 1 ]; then
        printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        exit 0
      fi
    fi
    if [ "${2:-}" = "--jq" ]; then
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else
      printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
    fi
    ;;
  repos/owner/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
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
        printf '[{"id":77,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"review for original trigger"}]\n' "$bot"
      else
        printf '[]\n'
      fi
    elif [ "$scenario" = "reused-final-slot-arrival" ]; then
      reads=0
      if [ -f "$state_dir/review-reads" ]; then
        reads=$(cat "$state_dir/review-reads")
      fi
      reads=$((reads + 1))
      printf '%s\n' "$reads" >"$state_dir/review-reads"
      if [ "$reads" -gt 1 ]; then
        printf '[{"id":88,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"reused final-slot response"}]\n' "$bot"
      else
        printf '[]\n'
      fi
    elif [ "$scenario" = "fresh-terminal-finding" ]; then
      printf '[{"id":89,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"current finding after reused trigger"}]\n' "$bot"
    elif [ "$scenario" = "older-finding-before-final-trigger" ]; then
      reads=0
      if [ -f "$state_dir/review-reads" ]; then
        reads=$(cat "$state_dir/review-reads")
      fi
      reads=$((reads + 1))
      printf '%s\n' "$reads" >"$state_dir/review-reads"
      if [ "$reads" -gt 1 ]; then
        printf '[{"id":92,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:15Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to final trigger"}]\n' "$bot"
      else
        printf '[{"id":91,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"older finding"}]\n' "$bot"
      fi
    else
      printf '[]\n'
    fi
    ;;
  repos/owner/repo/pulls/999/comments)
    if [ "$scenario" = "fresh-terminal-finding" ]; then
      printf '[{"id":90,"user":{"login":"%s"},"pull_request_review_id":89,"path":"scripts/codex-review-request.sh","line":1,"body":"![P1 Badge] current finding"}]\n' "$bot"
    elif [ "$scenario" = "older-finding-before-final-trigger" ]; then
      printf '[{"id":93,"user":{"login":"%s"},"pull_request_review_id":91,"path":"scripts/codex-review-request.sh","line":1,"body":"![P1 Badge] older finding"}]\n' "$bot"
    else
      printf '[]\n'
    fi
    ;;
  repos/owner/repo/issues/999/reactions)
    if [ "$scenario" = "skip_reaction" ]; then
      printf '[{"user":{"login":"%s"},"content":"+1","created_at":"2999-01-01T00:00:00Z","id":44}]\n' "$bot"
    else
      printf '[]\n'
    fi
    ;;
  repos/owner/repo/issues/999/comments)
    if [ -f "$state_dir/comments.jsonl" ]; then
      jq -sc '.' "$state_dir/comments.jsonl"
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
    # #951: the fixture must not inherit the caller's credentials. An agent
    # session normally carries OP_PREFLIGHT_AUTHOR_PAT / _REVIEWER_PAT (a
    # warm `op-preflight --check` exports both), and the bridging tests
    # below assert on exactly those variables — so an ambient value both
    # broke the assertions and pulled a live PAT into the failure message.
    # The bridge is supposed to start from an empty environment; make the
    # fixture actually provide one.
    unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
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

seed_author_trigger() { # <fixture-dir> <comment-id> <created-at>
  local dir=$1 comment_id=$2 created_at=$3
  jq -cn --argjson id "$comment_id" --arg created "$created_at" \
    '{id:$id,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:$created}' \
    >>"$dir/state/comments.jsonl"
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

# #813: the first request may spend the final slot. A missing acknowledgement
# then suppresses the retry, but must leave the confirmed first request in the
# ordinary review poll rather than returning an infrastructure-looking refusal.
test_request_attempt_cap_suppresses_ack_retry_but_polls() {
  local dir rc count before=$FAIL
  dir=$(make_case "request-cap-blocks-retry" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" absent)
  count=$(trigger_count "$dir")
  [ "$rc" = 4 ] || fail "#813 retry cap: exit $rc, expected ordinary poll timeout 4; stderr=$(cat "$dir/err.log")"
  [ "$count" = 1 ] || fail "#813 retry cap: trigger count $count, expected original only"
  grep -q 'request-attempt cap reached.*1/1.*continuing normal review poll' "$dir/err.log" \
    || fail "#813 retry cap: no observable retry suppression"
  [ "$FAIL" -ne "$before" ] || pass "#813: request budget permits the first trigger, suppresses its retry, and preserves its poll"
}

# #813: CodeRabbit's rate-limit failover can spend the final slot through
# --trigger-only. The later normal requester must adopt that known in-flight
# command for its poll without posting or ack-retrying another request.
test_reused_final_slot_trigger_polls_arriving_response() {
  local dir rc count ack_count review_body before=$FAIL
  dir=$(make_case "reused-final-slot-arrival" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9901 "2026-06-04T00:00:00Z"
  rc=$(run_case "$dir" reused-final-slot-arrival)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")
  review_body=$(jq -r '.review.body // "null"' "$dir/out.json")

  [ "$rc" = 0 ] || fail "#813 reused final slot: exit $rc, expected 0 after the in-flight request responded; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#813 reused final slot: posted $count new trigger(s) despite the exhausted budget"
  [ "$ack_count" = 0 ] || fail "#813 reused final slot: retried acknowledgement for a trigger posted by another invocation"
  [ "$(jq -r '.trigger_posted' "$dir/out.json")" = false ] || fail "#813 reused final slot: trigger_posted must remain false for a reused command"
  [ "$review_body" = "reused final-slot response" ] || fail "#813 reused final slot: did not report the reused request response"
  [ "$FAIL" -ne "$before" ] || pass "#813: normal mode polls a final-slot trigger-only request without another write"
}

test_reused_final_slot_pending_stops_without_timeout_authority() {
  local dir rc count ack_count before=$FAIL
  dir=$(make_case "reused-final-slot-pending" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9902 "2026-06-04T00:00:00Z"
  rc=$(run_case "$dir" reused-final-slot-pending)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")

  [ "$rc" = 7 ] || fail "#813 reused pending cap: exit $rc, expected CAP_EXHAUSTED 7; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#813 reused pending cap: posted $count new trigger(s) despite the exhausted budget"
  [ "$ack_count" = 0 ] || fail "#813 reused pending cap: retried acknowledgement for a reused trigger"
  [ ! -f "$dir/state/terminal-count" ] || fail "#813 reused pending cap: wrote a timeout determination from a reused trigger"
  [ "$(jq -r '.terminal_determination // "null"' "$dir/out.json")" = null ] || fail "#813 reused pending cap: emitted timeout authority"
  [ "$(jq -r '.blocked_reason // "null"' "$dir/out.json")" = null ] || fail "#813 reused pending cap: emitted Phase 4b block authority"
  [ "$FAIL" -ne "$before" ] || pass "#813: a pending reused final slot stops at the cap without timeout authority"
}

test_reused_final_slot_preserves_recorded_timeout() {
  local dir rc marker before=$FAIL
  dir=$(make_case "reused-recorded-timeout" 0 0)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" absent)
  [ "$rc" = 4 ] || fail "#813 recorded timeout setup: exit $rc, expected 4"
  marker=$(jq -r '.terminal_determination.marker_comment_id' "$dir/out.json")
  # A resumed invocation must not spend a second response window.
  sed -i.bak 's/review_timeout_seconds: 0/review_timeout_seconds: 30/' "$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" absent 1)
  [ "$rc" = 4 ] || fail "#813 recorded timeout: exit $rc, expected preserved fallback 4; stderr=$(cat "$dir/err.log")"
  [ "$(trigger_count "$dir")" = 1 ] || fail "#813 recorded timeout: posted another trigger"
  [ "$(cat "$dir/state/terminal-count")" = 1 ] || fail "#813 recorded timeout: posted another marker"
  [ "$(jq -r '.terminal_determination.marker_comment_id' "$dir/out.json")" = "$marker" ] || fail "#813 recorded timeout: lost the existing marker"
  [ "$(jq -r '.rounds_waited_seconds' "$dir/out.json")" = 0 ] || fail "#813 recorded timeout: waited again for a terminal request"
  [ "$(jq -r '.trigger_posted' "$dir/out.json")" = false ] || fail "#813 recorded timeout: claimed a new trigger"
  [ "$FAIL" -ne "$before" ] || pass "#813: the final request's recorded timeout is preserved without a new poll or write"
}

test_reused_final_slot_timeout_marker_controls() {
  local variant dir rc body expected count before
  for variant in stale superseded uppercase-newer malformed head-drift; do
    before=$FAIL
    dir=$(make_case "reused-marker-$variant" 0 0)
    printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
    seed_author_trigger "$dir" 9901 "2026-06-04T00:00:00Z"
    body='<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=9901 -->'
    expected=7
    case "$variant" in
      stale) body=${body/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb} ;;
      malformed) body=${body/trigger_comment_id=9901/trigger_comment_id=invalid}; expected=3 ;;
      head-drift) expected=3 ;;
    esac
    jq -cn --arg body "$body" '{id:9902,user:{login:"nathanjohnpayne"},body:$body,created_at:"2026-06-04T00:00:01Z"}' >>"$dir/state/comments.jsonl"
    case "$variant" in
      superseded) seed_author_trigger "$dir" 9903 "2026-06-04T00:00:02Z" ;;
      uppercase-newer)
        jq -cn '{id:9903,user:{login:"nathanjohnpayne"},body:"@CODEX REVIEW",created_at:"2026-06-04T00:00:02Z"}' >>"$dir/state/comments.jsonl"
        ;;
    esac
    rc=$(run_case "$dir" "$variant")
    [ "$rc" = "$expected" ] || fail "#813 $variant marker: exit $rc, expected $expected; stderr=$(cat "$dir/err.log")"
    [ "$(trigger_count "$dir")" = 0 ] || fail "#813 $variant marker: posted another trigger"
    [ ! -f "$dir/state/terminal-count" ] || fail "#813 $variant marker: posted timeout authority"
    if [ "$expected" = 7 ]; then
      [ "$(jq -r '.terminal_determination // "null"' "$dir/out.json")" = null ] || fail "#813 $variant marker: reused invalid timeout authority"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#813: $variant marker cannot authorize the final request's fallback"
  done
}

test_stale_trigger_is_not_reused_as_pending() {
  local dir rc count before=$FAIL
  dir=$(make_case "stale-trigger-control" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9903 "2026-06-03T00:00:00Z"
  rc=$(run_case "$dir" stale-trigger-control)
  count=$(trigger_count "$dir")

  [ "$rc" = 7 ] || fail "#813 stale trigger control: exit $rc, expected cap stop 7; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#813 stale trigger control: posted $count request(s) with the budget exhausted"
  ! grep -q 'polling the existing final request' "$dir/err.log" \
    || fail "#813 stale trigger control: treated a prior-head trigger as a reusable final request"
  [ "$FAIL" -ne "$before" ] || pass "#813: a prior-head trigger is not reused when normal mode reaches the cap"
}

test_current_terminal_finding_is_not_reused_as_pending() {
  local dir rc count before=$FAIL
  dir=$(make_case "fresh-terminal-finding" 0 0)
  printf '  max_review_rounds: 2\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9904 "2026-06-04T00:00:00Z"
  rc=$(run_case "$dir" fresh-terminal-finding)
  count=$(trigger_count "$dir")

  [ "$rc" = 4 ] || fail "#813 terminal finding control: exit $rc, expected a new normal request timeout; stderr=$(cat "$dir/err.log")"
  [ "$count" = 1 ] || fail "#813 terminal finding control: expected one fresh request after a current finding, got $count"
  [ "$FAIL" -ne "$before" ] || pass "#813: a current terminal finding is never reused as a pending request"
}

test_current_terminal_finding_at_cap_does_not_claim_reuse() {
  local dir rc count before=$FAIL
  dir=$(make_case "fresh-terminal-finding-at-cap" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9907 "2026-06-04T00:00:00Z"
  rc=$(run_case "$dir" fresh-terminal-finding)
  count=$(trigger_count "$dir")

  [ "$rc" = 7 ] || fail "#813 terminal finding at cap: exit $rc, expected cap stop 7; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#813 terminal finding at cap: posted $count request(s) with the budget exhausted"
  ! grep -q 'polling the existing final request' "$dir/err.log" \
    || fail "#813 terminal finding at cap: treated a terminal finding as a reusable final request"
  [ "$FAIL" -ne "$before" ] || pass "#813: a terminal finding does not claim final-trigger reuse at the cap"
}

test_older_finding_before_final_trigger_does_not_block_reuse() {
  local dir rc count ack_count review_body before=$FAIL
  dir=$(make_case "older-finding-before-final-trigger" 0 0)
  printf '  max_review_rounds: 2\n' >>"$dir/.github/review-policy.yml"
  seed_author_trigger "$dir" 9905 "2026-06-04T00:00:00Z"
  seed_author_trigger "$dir" 9906 "2026-06-04T00:00:10Z"
  rc=$(run_case "$dir" older-finding-before-final-trigger)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")
  review_body=$(jq -r '.review.body // "null"' "$dir/out.json")

  [ "$rc" = 0 ] || fail "#813 older finding control: exit $rc, expected the final in-flight trigger response; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#813 older finding control: posted $count new trigger(s) instead of reusing the later final trigger"
  [ "$ack_count" = 0 ] || fail "#813 older finding control: ack-retried the later trigger"
  [ "$review_body" = "response to final trigger" ] || fail "#813 older finding control: did not report the later final-trigger response"
  [ "$FAIL" -ne "$before" ] || pass "#813: an older same-head finding does not discard a later in-flight final trigger"
}

# A malformed cap is a new-write concern, not a reason to perturb an already
# cleared no-spend path.
test_malformed_request_cap_does_not_change_clearance_skip() {
  local dir rc before=$FAIL
  dir=$(make_case "malformed-cap-cleared" 0 1)
  printf '  max_review_rounds: 999999999999999999999999\n' >>"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" skip_reaction)
  [ "$rc" = 0 ] || fail "#813 malformed cap: cleared skip exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  [ "$(trigger_count "$dir")" = 0 ] || fail "#813 malformed cap: cleared skip posted a trigger"
  [ "$FAIL" -ne "$before" ] || pass "#813: malformed cap leaves an already-cleared no-spend path unchanged"
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

test_missing_comment_id_fails_closed_without_timeout_marker() {
  local dir rc count ack_count
  dir=$(make_case "missing-comment-id" 0 1)
  rc=$(run_case "$dir" no_comment_id)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")

  if [ "$rc" != "3" ]; then
    fail "missing comment id: exit $rc, expected 3 because no confirmed trigger can anchor the durable timeout; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "missing comment id: trigger count $count, expected no retry without a pollable id"
  elif [ "$ack_count" != "0" ]; then
    fail "missing comment id: ack endpoint called $ack_count times, expected 0"
  elif [ -f "$dir/state/terminal-count" ]; then
    fail "missing comment id: terminal marker was posted without a confirmed trigger id"
  else
    pass "missing trigger comment id: timeout persistence fails closed without fabricating a terminal marker (#1085)"
  fi
}

test_retry_missing_comment_id_stops_without_extra_retry() {
  local dir rc count ack_count
  dir=$(make_case "retry-missing-comment-id" 0 2)
  rc=$(run_case "$dir" retry_no_comment_id)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")

  if [ "$rc" != "3" ]; then
    fail "retry missing comment id: exit $rc, expected fail-closed 3; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "retry missing comment id: trigger count $count, expected original + one retry only"
  elif [ "$ack_count" != "1" ]; then
    fail "retry missing comment id: ack endpoint called $ack_count times, expected only the first pollable trigger"
  elif [ -f "$dir/state/terminal-count" ]; then
    fail "retry missing comment id: old confirmed trigger received a timeout after the unconfirmed retry landed"
  else
    pass "retry with missing trigger comment id: gate stops without extra retry or an obsolete timeout marker"
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
    fail "author-pat bridge: wrapper saw OP_PREFLIGHT_AUTHOR_PAT=$(describe_secret "$pat"), expected the verified inline token; stderr=$(cat "$dir/err.log")"
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
    fail "custom-author bridge: wrapper saw OP_PREFLIGHT_AUTHOR_PAT=$(describe_secret "$pat"), expected the verified inline token; stderr=$(cat "$dir/err.log")"
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
    fail "non-author token: wrapper saw OP_PREFLIGHT_AUTHOR_PAT=$(describe_secret "$pat"), expected empty (no bridge)"
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
    fail "missing checker: wrapper saw OP_PREFLIGHT_AUTHOR_PAT=$(describe_secret "$pat"), expected empty (bridge requires verification)"
  else
    pass "without identity-check.sh the bridge is skipped (verification-gated) (rc=$rc)"
  fi
}

# --- #951: credential material never reaches the output ---------------
#
# The four bridging cases above assert on OP_PREFLIGHT_AUTHOR_PAT, and
# they used to print the value they read. Run from an agent session with
# a warm op-preflight cache, the fixture inherited the caller's real
# author PAT, so those cases both failed spuriously AND printed a live
# credential into the transcript. Two things have to hold, and each gets
# its own case: the fixture must not inherit an ambient credential, and
# no message may quote one even when it is present.
#
# Obviously-fake sentinel. Never substitute a real token here, or
# anywhere else in this file --- the point of the case is that whatever
# is in this variable gets printed if the redaction regresses.
# Assembled from two pieces so the literal token shape never appears in a
# tracked line. This is NOT obfuscation of a real credential -- the value is
# a deliberate fake, and the point of the case is that it gets printed if
# redaction regresses. It is split because this file is a canonical manifest
# path: it propagates into consumer repos, several of which run their own
# tracked-file secret scanner over `git ls-files`
# (/\bgh[pousr]_[A-Za-z0-9]{20,255}\b/, no allowlist mechanism), and a
# contiguous `ghp_...` here reds their CI on content they did not write.
# Measured on the wave-0 fan-out: device-source-of-truth#167 and
# friends-and-family-billing#416 both failed on exactly this line, and it was
# the ONLY finding in the whole hub tree.
#
# The runtime VALUE is unchanged, so every assertion below still sees the
# same string -- including `${CREDENTIAL_SENTINEL#ghp_}`, which needs the
# real `ghp_` prefix, and `${#CREDENTIAL_SENTINEL}`, which needs the length.
# Never inline this back into one literal, and never substitute a real token
# here or anywhere else in this file.
CREDENTIAL_SENTINEL_TAIL='FAKEFAKEFAKE951NOTAREALTOKEN'
CREDENTIAL_SENTINEL="ghp_${CREDENTIAL_SENTINEL_TAIL}"

test_ambient_author_pat_is_not_inherited_or_echoed() {
  local dir rc pat leaked
  dir=$(make_case "ambient-pat-not-echoed" 0 0)
  # Exported, not merely assigned: the leak path runs through the real
  # script's process environment, so the sentinel has to be there too.
  rc=$(
    export OP_PREFLIGHT_AUTHOR_PAT="$CREDENTIAL_SENTINEL"
    export OP_PREFLIGHT_REVIEWER_PAT="$CREDENTIAL_SENTINEL"
    run_case "$dir" absent 0 reviewer-pat-456
  )
  pat=$(bridged_pat "$dir")
  leaked=no
  if grep -qF "$CREDENTIAL_SENTINEL" "$dir/out.json" "$dir/err.log" 2>/dev/null; then
    leaked=yes
  fi

  if [ "$pat" = "$CREDENTIAL_SENTINEL" ]; then
    fail "ambient credential: the fixture inherited the caller's OP_PREFLIGHT_AUTHOR_PAT; the bridge must start from an empty environment"
  elif [ -n "$pat" ]; then
    fail "ambient credential: wrapper saw OP_PREFLIGHT_AUTHOR_PAT=$(describe_secret "$pat"), expected empty"
  elif [ "$leaked" = "yes" ]; then
    fail "ambient credential: the sentinel reached the script's stdout or stderr"
  else
    pass "an ambient author PAT is neither inherited by the fixture nor echoed by the script (rc=$rc)"
  fi
}

test_secret_descriptor_never_reveals_the_value() {
  local rendered empty_rendered secret_tail window i chunk
  rendered=$(describe_secret "$CREDENTIAL_SENTINEL")
  empty_rendered=$(describe_secret "")
  # `ghp_` is a fixed, publicly-known constant; everything after it is
  # the entropy, and none of THAT may survive into a message. A
  # fixed-prefix classification is fine, a prefix of the secret is not,
  # so slide a short window over the tail rather than only checking for
  # the tail whole: an eight-character "just enough to identify it"
  # excerpt is exactly the regression this has to catch.
  secret_tail=${CREDENTIAL_SENTINEL#ghp_}
  window=""
  i=0
  while [ $((i + 4)) -le ${#secret_tail} ]; do
    chunk=${secret_tail:$i:4}
    if printf '%s' "$rendered" | grep -qF "$chunk"; then
      window=$chunk
      break
    fi
    i=$((i + 1))
  done

  if printf '%s' "$rendered" | grep -qF "$CREDENTIAL_SENTINEL"; then
    fail "secret descriptor: the rendering still contains the whole value"
  elif [ -n "$window" ]; then
    fail "secret descriptor: the rendering leaks a 4-char run of the value's entropy (found '$window' in '$rendered')"
  elif [ "$rendered" = "$empty_rendered" ]; then
    fail "secret descriptor: set and unset render identically ('$rendered'), so no message can tell them apart"
  elif ! printf '%s' "$rendered" | grep -qF "${#CREDENTIAL_SENTINEL} chars"; then
    fail "secret descriptor: the rendering omits the length that makes it debuggable (got '$rendered')"
  else
    pass "describe_secret reports class and length only, never the value ($rendered)"
  fi
}

test_eyes_ack_does_not_retrigger_or_clear
test_missing_ack_retriggers_once
test_retry_cap_respected
test_request_attempt_cap_suppresses_ack_retry_but_polls
test_reused_final_slot_trigger_polls_arriving_response
test_reused_final_slot_pending_stops_without_timeout_authority
test_reused_final_slot_preserves_recorded_timeout
test_reused_final_slot_timeout_marker_controls
test_stale_trigger_is_not_reused_as_pending
test_current_terminal_finding_is_not_reused_as_pending
test_current_terminal_finding_at_cap_does_not_claim_reuse
test_older_finding_before_final_trigger_does_not_block_reuse
test_malformed_request_cap_does_not_change_clearance_skip
test_skip_path_posts_no_trigger_or_ack_check
test_missing_comment_id_fails_closed_without_timeout_marker
test_retry_missing_comment_id_stops_without_extra_retry
test_retry_resets_review_deadline
test_retry_preserves_original_trigger_response
test_ack_wait_window_is_bounded
test_inline_author_pat_bridged_into_wrapper
test_bridge_passes_configured_author_identity
test_non_author_token_is_not_bridged
test_non_bridge_path_passes_configured_identity
test_missing_identity_checker_skips_bridge
test_ambient_author_pat_is_not_inherited_or_echoed
test_secret_descriptor_never_reveals_the_value

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
