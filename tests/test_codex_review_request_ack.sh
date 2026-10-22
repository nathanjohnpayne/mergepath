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
# The requester counts solicited blocking reviews from the Codex review ledger
# before every new request (#1560 slice 3). This stub reports a ledger with no
# responses for whatever head the requester expects, so the blocking-review
# budget never stops these cases; test_codex_review_request_trigger_only.sh
# covers the budget itself.
LEDGER_STUB="$WORKDIR/codex-ledger-stub.sh"
cat >"$LEDGER_STUB" <<'LEDGER_EOF'
#!/usr/bin/env bash
[ -z "${CODEX_LEDGER_STUB_LOG:-}" ] || printf '%s\n' "$*" >>"$CODEX_LEDGER_STUB_LOG"
# Simulates an unreadable ledger.
[ -z "${CODEX_LEDGER_STUB_FAIL:-}" ] || exit 3
# Simulates the governed budget turning malformed after the initial request.
[ -z "${CODEX_LEDGER_STUB_BREAK_POLICY:-}" ] \
  || printf '  max_blocking_reviews: false\n' >>"$CODEX_LEDGER_STUB_BREAK_POLICY"
# Simulates the governed blocking-review budget being spent after the first
# request (#2664): later reads govern, and report, a budget of zero.
budget=10
if [ -n "${CODEX_LEDGER_STUB_SPEND_POLICY:-}" ]; then
  if grep -q 'max_blocking_reviews' "$CODEX_LEDGER_STUB_SPEND_POLICY"; then
    budget=0
  else
    printf '  max_blocking_reviews: 0\n' >>"$CODEX_LEDGER_STUB_SPEND_POLICY"
  fi
fi
head=""
while [ $# -gt 0 ]; do
  case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac
done
jq -nc --arg h "$head" --arg fp "${fp:-}" --arg a "${CODEX_LEDGER_STUB_AUTHOR:-nathanjohnpayne}" --argjson budget "$budget" \
  '{head_sha: $h, author: $a, max_blocking_reviews: $budget, policy_fingerprint: $fp, responses: []}'
LEDGER_EOF
chmod +x "$LEDGER_STUB"
export MERGEPATH_CODEX_LEDGER_CMD="$LEDGER_STUB"

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

  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/scripts/workflow" "$dir/.github" "$dir/bin" "$dir/state"
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
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$dir/scripts/workflow/resolve-codex-verdict-anchors.py"
  # #1550: classifier for retrying transient poll reads (existence-guarded in
  # the script; without it every failure is permanent, the pre-#1550 shape).
  cp "$ROOT/scripts/lib/gh-retry-helpers.sh" "$dir/scripts/lib/gh-retry-helpers.sh"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$dir/scripts/workflow/resolve_base_policy.sh"
  chmod +x "$dir/scripts/workflow/resolve_base_policy.sh"

  # request_min_head_age_seconds: 0 -- these cases model acknowledgement,
  # resume and expiry mechanics under a FAKE clock that places "now" seconds
  # after the stubbed head date, so every head here reads as just pushed.
  # The moving-head guard (#2166) is not under test in this suite; it is
  # covered by tests/test_codex_review_request_trigger_only.sh (MH1-MH10).
  cat >"$dir/.github/review-policy.yml" <<EOF
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  request_by_default: true  # #2240: absent now means false; these cases exercise the request itself
  review_timeout_seconds: $review_timeout
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: $ack_wait
  max_ack_retries: $max_retries
  request_min_head_age_seconds: 0
EOF
  cp "$dir/.github/review-policy.yml" "$dir/state/base-review-policy.yml"

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
  '<!-- mergepath-codex-retry:v1 '*) kind=retry-marker ;;
  *) echo "unexpected author comment body: $body" >&2; exit 98 ;;
esac
# #2664: the fake time of every trigger, for the retry backoff assertions.
if [ "$kind" = trigger ] && [ -f "$state_dir/fake-time" ]; then
  cat "$state_dir/fake-time" >>"$state_dir/trigger-times"
fi

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
    # The initial HEAD fetch and the governing-policy resolver both need full
    # PR metadata. Only preserve_final_request_timeout's explicit scalar read
    # proves the live head immediately before it reuses a timeout marker.
    if [ "$scenario" = "head-drift" ] && [ "${2:-}" = "--jq" ] && [ "${3:-}" = ".head.sha" ]; then
      reads=0
      [ ! -f "$state_dir/head-reads" ] || reads=$(cat "$state_dir/head-reads")
      reads=$((reads + 1))
      printf '%s\n' "$reads" >"$state_dir/head-reads"
      if [ "$reads" -eq 1 ]; then
        printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        exit 0
      fi
    fi
    # #2664: the automatic retry's head fence is the first scalar head read
    # after a trigger was posted.
    if [ "${2:-}" = "--jq" ] && [ -f "$state_dir/trigger-count" ]; then
      case "$scenario" in
        retry-head-changed) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'; exit 0 ;;
        retry-late-at-fence) touch "$state_dir/late-result" ;;
      esac
    fi
    if [ "${2:-}" = "--jq" ]; then
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else
      printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"ref":"main","sha":"base-sha","repo":{"default_branch":"main"}}}\n'
    fi
    ;;
  'repos/owner/repo/contents/.github/review-policy.yml?ref=base-sha')
    cat "$state_dir/base-review-policy.yml"
    ;;
  repos/owner/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
    printf '%s\n' "${CODEX_TEST_COMMIT_DATE:-$now}"
    ;;
  repos/owner/repo/issues/999/timeline)
    printf '[]\n'
    ;;
  repos/owner/repo/pulls/999/reviews)
    # #1550 scenarios count review reads: read 1 is the pre-flight scan.
    case "$scenario" in
      resume-running|poll-502-once|poll-502-always|poll-404|resume-blocked|resume-read-502-once)
        reads=0
        [ ! -f "$state_dir/review-reads" ] || reads=$(cat "$state_dir/review-reads")
        reads=$((reads + 1))
        printf '%s\n' "$reads" >"$state_dir/review-reads"
        ;;
    esac
    if [ "$scenario" = "skip_review" ]; then
      printf '[{"id":101,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"exact current-head clean review"}]\n' "$bot"
    elif [ "$scenario" = "resume-read-502-once" ] && [ "$reads" -gt 1 ]; then
      printf '[{"id":94,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:01:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to the resumed request"}]\n' "$bot"
    elif [ "$scenario" = "resume-blocked" ]; then
      # An older P1 review on HEAD that the pending request asked Codex to
      # reconsider; it predates the request, so it is not its answer.
      printf '[{"id":98,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-03T23:59:30Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"older findings"}]\n' "$bot"
    elif [ "$scenario" = "answered-running" ]; then
      printf '[{"id":96,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:20Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"findings on the pending request"}]\n' "$bot"
    elif [ "$scenario" = "resume-running" ] && [ "$reads" -gt 1 ]; then
      printf '[{"id":94,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:01:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to the resumed request"}]\n' "$bot"
    elif { [ "$scenario" = "poll-502-once" ] && [ "$reads" -eq 2 ]; } \
         || { [ "$scenario" = "poll-502-always" ] && [ "$reads" -gt 1 ]; }; then
      printf '{"message":"Bad Gateway"}\n'
      echo "gh: HTTP 502 Server Error" >&2
      exit 1
    elif [ "$scenario" = "poll-404" ] && [ "$reads" -gt 1 ]; then
      printf '{"message":"Not Found"}\n'
      echo "gh: HTTP 404 Not Found" >&2
      exit 1
    elif [ "$scenario" = "poll-502-once" ] && [ "$reads" -gt 2 ]; then
      printf '[{"id":95,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response after a transient read failure"}]\n' "$bot"
    elif [ "$scenario" = "wrapper-slow-ack" ] && [ -f "$state_dir/authorization-refused" ]; then
      printf '[{"id":77,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:00:05Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"delayed response to original request"}]\n' "$bot"
    elif [ "$scenario" = "retry-late-at-fence" ] && [ -f "$state_dir/late-result" ]; then
      printf '[{"id":78,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:01:30Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"late response to the original request"}]\n' "$bot"
    elif [ "$scenario" = "retry-concurrent" ] && [ -f "$state_dir/trigger-count" ]; then
      printf '[{"id":79,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:05:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to the retry"}]\n' "$bot"
    elif [ "$scenario" = "retry-completes" ] && [ "$(cat "$state_dir/trigger-count" 2>/dev/null || echo 0)" -ge 2 ]; then
      printf '[{"id":80,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:05:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to the retry"}]\n' "$bot"
    elif [ "$scenario" = "retry-window-late" ] && [ "$(cat "$state_dir/trigger-count" 2>/dev/null || echo 0)" -ge 2 ]; then
      printf '[{"id":81,"user":{"login":"%s"},"state":"COMMENTED","submitted_at":"2026-06-04T00:05:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"response to the retry"}]\n' "$bot"
    elif [ "$scenario" = "review_after_retry" ]; then
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
    if [ "$scenario" = "resume-blocked" ]; then
      printf '[{"id":99,"user":{"login":"%s"},"pull_request_review_id":98,"path":"scripts/codex-review-request.sh","line":1,"body":"![P1 Badge] older finding"}]\n' "$bot"
    elif [ "$scenario" = "answered-running" ]; then
      printf '[{"id":97,"user":{"login":"%s"},"pull_request_review_id":96,"path":"scripts/codex-review-request.sh","line":1,"body":"![P1 Badge] answered finding"}]\n' "$bot"
    elif [ "$scenario" = "fresh-terminal-finding" ]; then
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
    case "$scenario" in
      resume-read-502-once|resume-read-502-always)
        rreads=0
        [ ! -f "$state_dir/resume-reads" ] || rreads=$(cat "$state_dir/resume-reads")
        rreads=$((rreads + 1))
        printf '%s\n' "$rreads" >"$state_dir/resume-reads"
        # Read 1 is the pre-flight scan; read 2 is the resume check.
        if { [ "$scenario" = resume-read-502-once ] && [ "$rreads" -eq 2 ]; } \
           || { [ "$scenario" = resume-read-502-always ] && [ "$rreads" -ge 2 ]; }; then
          printf '{"message":"Bad Gateway"}\n'
          echo "gh: HTTP 502 Server Error" >&2
          exit 1
        fi
        ;;
    esac
    # #2664: the posted request's run is seen Running, then Completed with
    # no result, on the third comments read after the trigger.
    if [ "$scenario" = "retry-completes" ] && [ -f "$state_dir/trigger-count" ]; then
      pt=0; [ ! -f "$state_dir/post-trigger-reads" ] || pt=$(cat "$state_dir/post-trigger-reads")
      pt=$((pt + 1)); printf '%s\n' "$pt" >"$state_dir/post-trigger-reads"
      if [ "$pt" -eq 3 ]; then
        body=$(printf '<!-- codex-pull-request-review-summary -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `aaaaaaa` | Manual request |\n')
        jq -cn --arg body "$body" '{id:3004,user:{login:"chatgpt-codex-connector[bot]"},body:$body,created_at:"2026-06-04T00:00:30Z",updated_at:"2026-06-04T00:00:30Z"}' >>"$state_dir/comments.jsonl"
      fi
    fi
    # #2664: the provider adds a three-minute window to the failed run while
    # the retry waits (the second comments read after the trigger).
    if [ "$scenario" = "retry-window-late" ] && [ -f "$state_dir/trigger-count" ]; then
      pt=0; [ ! -f "$state_dir/post-trigger-reads" ] || pt=$(cat "$state_dir/post-trigger-reads")
      pt=$((pt + 1)); printf '%s\n' "$pt" >"$state_dir/post-trigger-reads"
      if [ "$pt" -eq 2 ]; then
        body=$(printf '<!-- codex-pull-request-review-summary -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ❌ **Failed** | `aaaaaaa` | Manual request |\n\nPlease try again in 3 minutes.\n')
        jq -cn --arg body "$body" '{id:3005,user:{login:"chatgpt-codex-connector[bot]"},body:$body,created_at:"2026-06-04T00:00:20Z",updated_at:"2026-06-04T00:00:20Z"}' >>"$state_dir/comments.jsonl"
      fi
    fi
    # #2664: the resumed request's run fails a minute after it was posted.
    if [ "$scenario" = "retry-concurrent" ] && [ ! -f "$state_dir/run-failed" ] \
       && [ "$(cat "$state_dir/fake-time")" -ge "$(( $(jq -rn '"2026-06-04T00:00:00Z" | fromdateiso8601') + ${CODEX_TEST_FAIL_AT:-60} ))" ]; then
      touch "$state_dir/run-failed"
      body=$(printf '<!-- codex-pull-request-review-summary -->\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ❌ **Failed** | `aaaaaaa` | Manual request |\n')
      jq -cn --arg body "$body" '{id:3003,user:{login:"chatgpt-codex-connector[bot]"},body:$body,created_at:"2026-06-04T00:01:00Z",updated_at:"2026-06-04T00:01:00Z"}' >>"$state_dir/comments.jsonl"
    fi
    if [ "$scenario" = "resume-blocked" ]; then
      # Reads 1-2 are the pre-flight scan and the resume check; the account
      # block lands while the resumed request is being polled.
      creads=0
      [ ! -f "$state_dir/comment-reads" ] || creads=$(cat "$state_dir/comment-reads")
      creads=$((creads + 1))
      printf '%s\n' "$creads" >"$state_dir/comment-reads"
      if [ "$creads" -eq 3 ]; then
        jq -cn --arg bot "$bot" '{id:3002,user:{login:$bot},body:"You have reached your Codex usage limits for code reviews.",created_at:"2026-06-04T00:00:40Z",updated_at:"2026-06-04T00:00:40Z"}' >>"$state_dir/comments.jsonl"
      fi
    fi
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
    if [ "$scenario" = "eyes_present" ] || [ "${CODEX_TEST_EYES:-0}" = 1 ]; then
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

# #1560 slice 3 (Codex P2 on #1576): an acknowledgement retry does not re-check
# the blocking-review budget, so a governed max_blocking_reviews that turns
# malformed after the initial request must not fail the retry.
test_ack_retry_ignores_blocking_budget_value() {
  local dir rc count
  dir=$(make_case "retry-blocking-malformed" 0 1)
  rc=$(CODEX_LEDGER_STUB_BREAK_POLICY="$dir/state/base-review-policy.yml" run_case "$dir" absent)
  count=$(trigger_count "$dir")
  if ! grep -q 'max_blocking_reviews: false' "$dir/state/base-review-policy.yml"; then
    fail "ack retry blocking budget: the stub did not break the governed value"
  elif [ "$rc" != "4" ] || [ "$count" != "2" ]; then
    fail "ack retry blocking budget: exit $rc with $count triggers, expected 4 with the retry posted; stderr=$(cat "$dir/err.log")"
  else
    pass "ack retry: a governed blocking budget that turns malformed after the initial request does not fail the retry"
  fi
}

test_missing_ack_retriggers_once() {
  local dir rc count
  dir=$(make_case "missing-one-retry" 0 1)
  rc=$(CODEX_LEDGER_STUB_LOG="$dir/ledger-calls" run_case "$dir" absent)
  count=$(trigger_count "$dir")

  if [ "$rc" != "4" ]; then
    fail "missing ack one retry: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "2" ]; then
    fail "missing ack one retry: trigger count $count, expected original + one retry"
  elif [ "$(wc -l <"$dir/ledger-calls" | tr -d ' ')" != 1 ]; then
    # #1560 slice 3: the blocking-review budget gates the new request only;
    # the acknowledgement retry re-asks for that same request.
    fail "missing ack one retry: blocking-review ledger ran $(wc -l <"$dir/ledger-calls" | tr -d ' ') times, expected once (initial request only)"
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
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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

# #2253: the moving-head guard (#2166) protects a NEW write only. Reusing the
# final pending request writes nothing, so a head that reads as young (here,
# every head does: the age floor is raised far past any stub date) must still
# be polled, not refused with exit 8.
test_reused_final_slot_polls_on_a_young_head() {
  local dir rc count before=$FAIL
  dir=$(make_case "reused-final-slot-young" 0 1)
  sed -i.bak 's/^  request_min_head_age_seconds: 0$/  request_min_head_age_seconds: 999999999/' "$dir/.github/review-policy.yml"
  grep -q '^  request_min_head_age_seconds: 999999999$' "$dir/.github/review-policy.yml" \
    || fail "#2253 young-head reuse: fixture did not raise the age floor"
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
  seed_author_trigger "$dir" 9901 "2026-06-04T00:00:00Z"
  rc=$(run_case "$dir" reused-final-slot-arrival)
  count=$(trigger_count "$dir")
  [ "$rc" = 0 ] || fail "#2253 young-head reuse: exit $rc, expected 0 (the reused request was polled); stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#2253 young-head reuse: posted $count trigger(s)"
  grep -q 'polling the existing final request without a new trigger' "$dir/err.log" \
    || fail "#2253 young-head reuse: did not take the cap-reuse poll"
  grep -q 'moving-head guard' "$dir/err.log" && fail "#2253 young-head reuse: the guard ran on a path that writes nothing"
  [ "$FAIL" -ne "$before" ] || pass "#2253: the cap-reuse poll is not refused by the moving-head guard on a young head"
}

# #1560 canary (finding 4): reusing the final pending request posts nothing,
# so the blocking-review check does not run there, and an unreadable ledger
# cannot turn that poll into an exit 3.
test_reused_final_slot_polls_despite_unreadable_ledger() {
  local dir rc count before=$FAIL
  dir=$(make_case "reused-final-slot-ledger-down" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
  seed_author_trigger "$dir" 9901 "2026-06-04T00:00:00Z"
  rc=$(CODEX_LEDGER_STUB_FAIL=1 CODEX_LEDGER_STUB_LOG="$dir/ledger-calls" run_case "$dir" reused-final-slot-arrival)
  count=$(trigger_count "$dir")
  [ "$rc" = 0 ] || fail "reuse with ledger down: exit $rc, expected 0 (the in-flight request responded); stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "reuse with ledger down: posted $count trigger(s)"
  [ ! -s "$dir/ledger-calls" ] || fail "reuse with ledger down: ran the ledger on the reuse path"
  [ "$FAIL" -ne "$before" ] || pass "#1560 canary: the reused final request is polled without a blocking-review read, even with the ledger unreadable"
}

test_reused_final_slot_pending_stops_without_timeout_authority() {
  local dir rc count ack_count before=$FAIL
  dir=$(make_case "reused-final-slot-pending" 0 1)
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
    printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
    if [ "$variant" = head-drift ]; then
      grep -q 'cannot reuse Phase 4a timeout: PR head moved' "$dir/err.log" \
        || fail "#813 head-drift marker: exit 3 did not come from the live-head refusal; stderr=$(cat "$dir/err.log")"
    fi
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
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 2\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 1\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 2\n' >>"$dir/state/base-review-policy.yml"
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
  printf '  max_review_rounds: 999999999999999999999999\n' >>"$dir/state/base-review-policy.yml"
  rc=$(run_case "$dir" skip_review)
  [ "$rc" = 0 ] || fail "#813 malformed cap: cleared skip exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  [ "$(trigger_count "$dir")" = 0 ] || fail "#813 malformed cap: cleared skip posted a trigger"
  [ "$FAIL" -ne "$before" ] || pass "#813: malformed cap leaves an already-cleared no-spend path unchanged"
}

test_skip_path_posts_no_trigger_or_ack_check() {
  local dir rc count ack_count reaction_content
  dir=$(make_case "skip-path" 0 1)
  rc=$(run_case "$dir" skip_review)
  count=$(trigger_count "$dir")
  ack_count=$(ack_endpoint_count "$dir")
  reaction_content=$(jq -r '.reaction // "null"' "$dir/out.json")

  if [ "$rc" != "0" ]; then
    fail "skip path: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "skip path: trigger count $count, expected 0"
  elif [ "$ack_count" != "0" ]; then
    fail "skip path: ack endpoint called $ack_count times, expected 0"
  elif [ "$reaction_content" != "null" ]; then
    fail "skip path: reaction content $reaction_content, expected null"
  else
    pass "cleared pre-flight skip path: no trigger and no ack check"
  fi
}


test_prior_reaction_cannot_clear_backdated_ordinary_push() {
  local dir rc before=$FAIL
  dir=$(make_case "prior-reaction-backdated-push" 0 0 1)
  rc=$(CODEX_TEST_COMMIT_DATE=2026-05-01T00:00:00Z run_case "$dir" skip_reaction)
  [ "$rc" = 4 ] || fail "#1751: prior-head reaction exit $rc, expected bounded fallback; stderr=$(cat "$dir/err.log")"
  [ "$(trigger_count "$dir")" = 1 ] || fail "#1751: prior-head reaction suppressed the new-head review request"
  [ "$(jq -r '.reaction // "null"' "$dir/out.json")" = null ] || fail "#1751: unanchored reaction leaked into authoritative signal output"
  [ "$FAIL" -ne "$before" ] || pass "#1751: a future-dated prior reaction cannot clear an ordinary push with an old committer date"
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
[ "${1:-}" = "--expect-write-identity" ] || exit 2
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
  printf 'author_identity: custom-owner\n' >>"$dir/state/base-review-policy.yml"
  cat >"$dir/scripts/identity-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--expect-write-identity" ] || exit 2
[ "${2:-}" = "custom-owner" ] || exit 1
[ "${GH_TOKEN:-}" = "author-pat-123" ] || exit 1
exit 0
EOF
  chmod +x "$dir/scripts/identity-check.sh"
  rc=$(CODEX_LEDGER_STUB_AUTHOR=custom-owner run_case "$dir" absent 0 author-pat-123)
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

test_candidate_author_cannot_reset_governing_request_cap() {
  local dir rc before=$FAIL i
  dir=$(make_case "candidate-author-cap-reset" 0 0)
  # The governing author has already consumed every request slot. Before the
  # write-boundary identity check, selecting a different candidate identity
  # omitted those requests and let a verified token post another command.
  printf '  max_review_rounds: 10\n' >>"$dir/state/base-review-policy.yml"
  i=1
  while [ "$i" -le 10 ]; do
    seed_author_trigger "$dir" "$((9000 + i))" "2026-06-03T00:00:00Z"
    i=$((i + 1))
  done
  printf 'author_identity: custom-owner\n' >>"$dir/.github/review-policy.yml"
  cat >"$dir/scripts/identity-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--expect-write-identity" ] || exit 2
[ "${2:-}" = "custom-owner" ] || exit 1
[ "${GH_TOKEN:-}" = "author-pat-123" ] || exit 1
exit 0
EOF
  chmod +x "$dir/scripts/identity-check.sh"

  rc=$(run_case "$dir" absent 0 author-pat-123)
  [ "$rc" = 3 ] || fail "#813 governing author mismatch: expected infrastructure exit 3, got $rc; stderr=$(cat "$dir/err.log")"
  [ "$(trigger_count "$dir")" = 0 ] || fail "#813 governing author mismatch: candidate identity posted beyond the governing author's cap"
  grep -q 'candidate author_identity.*governing base policy' "$dir/err.log" \
    || fail "#813 governing author mismatch: refusal did not identify the policy mismatch"
  [ "$FAIL" -ne "$before" ] || pass "#813: candidate author_identity cannot reset the governing request-attempt count"
}

test_invalid_governing_author_refuses_new_write() {
  local value dir rc before
  for value in false null '[]'; do
    before=$FAIL
    dir=$(make_case "governing-author-$value" 0 0)
    printf 'author_identity: %s\n' "$value" >>"$dir/state/base-review-policy.yml"
    rc=$(run_case "$dir" absent)
    [ "$rc" = 3 ] || fail "#813 malformed governing author $value: expected infrastructure exit 3, got $rc; stderr=$(cat "$dir/err.log")"
    [ "$(trigger_count "$dir")" = 0 ] || fail "#813 malformed governing author $value: posted despite invalid governed identity"
    [ "$FAIL" -ne "$before" ] || pass "#813: present malformed governing author_identity $value refuses a new request write"
  done
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
  printf "author_identity: 'custom-owner'\n" >>"$dir/state/base-review-policy.yml"
  rc=$(CODEX_LEDGER_STUB_AUTHOR=custom-owner run_case "$dir" absent 0 reviewer-pat-456)
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
    if grep -qF "$chunk" <<<"$rendered"; then
      window=$chunk
      break
    fi
    i=$((i + 1))
  done

  if grep -qF "$CREDENTIAL_SENTINEL" <<<"$rendered"; then
    fail "secret descriptor: the rendering still contains the whole value"
  elif [ -n "$window" ]; then
    fail "secret descriptor: the rendering leaks a 4-char run of the value's entropy (found '$window' in '$rendered')"
  elif [ "$rendered" = "$empty_rendered" ]; then
    fail "secret descriptor: set and unset render identically ('$rendered'), so no message can tell them apart"
  elif ! grep -qF "${#CREDENTIAL_SENTINEL} chars" <<<"$rendered"; then
    fail "secret descriptor: the rendering omits the length that makes it debuggable (got '$rendered')"
  else
    pass "describe_secret reports class and length only, never the value ($rendered)"
  fi
}

# --- #1550: resume an in-flight request instead of re-posting it ----------

RESUME_TRIGGER_AT="2026-06-04T00:00:00Z"

seed_codex_summary() { # <fixture-dir> <status-cell> <commit> <updated-at> [extra-text]
  local dir=$1 status=$2 commit=$3 updated=$4 body
  body=$(printf '<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | %s | `%s` | Manual request |\n%s' "$status" "$commit" "${5:-}")
  jq -cn --arg body "$body" --arg updated "$updated" \
    '{id:3001,user:{login:"chatgpt-codex-connector[bot]"},body:$body,created_at:$updated,updated_at:$updated}' \
    >>"$dir/state/comments.jsonl"
}

# Put the fake clock <seconds> after the seeded request was posted.
set_clock_after_request() { # <fixture-dir> <seconds>
  local epoch
  epoch=$(jq -rn --arg t "$RESUME_TRIGGER_AT" '$t | fromdateiso8601')
  printf '%s\n' $((epoch + $2)) >"$1/state/fake-time"
}

test_resume_running_request_posts_nothing() {
  local dir rc count before=$FAIL
  dir=$(make_case "resume-running" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_case "$dir" resume-running 1)
  count=$(trigger_count "$dir")
  [ "$rc" = 0 ] || fail "#1550 resume: exit $rc, expected 0 from the resumed request's response; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#1550 resume: posted $count trigger(s), expected none while Codex reports HEAD Running"
  [ "$(jq -r '.request_resumed' "$dir/out.json")" = true ] || fail "#1550 resume: JSON request_resumed is not true"
  grep -q 'resuming pending request 900' "$dir/err.log" || fail "#1550 resume: no resume log"
  [ "$FAIL" -ne "$before" ] || pass "#1550: an unanswered request with Codex Running on HEAD is resumed, not re-posted"
}

test_resume_requires_provider_evidence() {
  local name summary_status summary_commit summary_updated expect dir rc count
  while IFS='|' read -r name summary_status summary_commit summary_updated expect; do
    dir=$(make_case "resume-$name" 0 0 60)
    seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
    [ "$summary_status" = none ] \
      || seed_codex_summary "$dir" "$summary_status" "$summary_commit" "$summary_updated"
    set_clock_after_request "$dir" 30
    rc=$(run_case "$dir" absent 1)
    count=$(trigger_count "$dir")
    if [ "$count" != 1 ] || grep -q 'resuming pending request' "$dir/err.log" \
       || [ "$(jq -r '.request_resumed' "$dir/out.json")" != false ]; then
      fail "#1550 no-resume ($name): exit $rc, $count trigger(s); expected exactly one new trigger and no resume ($expect); stderr=$(cat "$dir/err.log")"
    else
      pass "#1550: posts a new request when $expect"
    fi
  done <<'CASES'
no-summary|none|||no Codex summary ties the pending request to HEAD
other-head|⏳ **Running**|bbbbbbb|2026-06-04T00:00:10Z|Codex is running on a different commit
before-request|⏳ **Running**|aaaaaaa|2026-06-03T23:59:00Z|the Running summary predates the pending request
completed|✅ **Completed**|aaaaaaa|2026-06-04T00:00:10Z|the summary reports Completed rather than Running
CASES
}

# A request Codex already answered with a required-tier finding needs a new
# request for the next round, even while a Running summary is on HEAD.
test_answered_request_is_not_resumed() {
  local dir rc count
  dir=$(make_case "resume-answered" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:30Z"
  set_clock_after_request "$dir" 40
  rc=$(run_case "$dir" answered-running 1)
  count=$(trigger_count "$dir")
  if [ "$count" = 1 ] && ! grep -q 'resuming pending request' "$dir/err.log"; then
    pass "#1550: a pending request Codex already answered with a P1 is not resumed"
  else
    fail "#1550 answered: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# A resumed poll that ends on a provider block must not exit 0 on an older
# review the resumed request was asking Codex to reconsider.
test_resumed_block_does_not_clear_on_stale_review() {
  local dir rc before=$FAIL
  dir=$(make_case "resume-blocked" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 20
  rc=$(run_case "$dir" resume-blocked 1)
  grep -q 'resuming pending request 900' "$dir/err.log" || fail "#1550 resumed block: request was not resumed; stderr=$(cat "$dir/err.log")"
  [ "$rc" = 4 ] || fail "#1550 resumed block: exit $rc, expected 4 (FALLBACK_REQUIRED), not a clearance from the stale review"
  [ "$(jq -r '.blocked_reason' "$dir/out.json")" = usage_limit ] || fail "#1550 resumed block: blocked_reason is not usage_limit"
  [ "$(trigger_count "$dir")" = 0 ] || fail "#1550 resumed block: posted a trigger into a provider block"
  [ "$FAIL" -ne "$before" ] || pass "#1550: a resumed request ending on a provider block exits 4, not 0 on an older review"
}

# A request that already minted a Phase 4a timeout marker is settled.
test_request_with_timeout_marker_is_not_resumed() {
  local dir rc count
  dir=$(make_case "resume-marked" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  jq -cn '{id:901,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=900 -->",created_at:"2026-06-04T00:00:05Z"}' \
    >>"$dir/state/comments.jsonl"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  if [ "$count" = 1 ] && grep -q "has a current Phase 4a timeout marker — not resuming" "$dir/err.log"; then
    pass "#1550: a request that already holds a current timeout marker is not resumed"
  else
    fail "#1550 marked: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# The reaction-freshness window is a separate knob that may be shorter than
# the reply deadline; a request inside its own deadline stays resumable.
test_resume_survives_short_freshness_window() {
  local dir rc count
  dir=$(make_case "resume-short-freshness" 0 0 1800)
  sed -i.bak 's/reaction_freshness_window_seconds: .*/reaction_freshness_window_seconds: 600/' \
    "$dir/.github/review-policy.yml" "$dir/state/base-review-policy.yml"
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 700
  rc=$(run_case "$dir" resume-running 1)
  count=$(trigger_count "$dir")
  if [ "$rc" = 0 ] && [ "$count" = 0 ] && grep -q 'resuming pending request 900' "$dir/err.log"; then
    pass "#1550: a request older than a shorter reaction-freshness window is still resumed inside its own deadline"
  else
    fail "#1550 short freshness: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# The committer date is author-controlled; a future one must not hide the
# pending request from the resume check.
test_resume_survives_future_committer_date() {
  local dir rc count
  dir=$(make_case "resume-future-commit" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(CODEX_TEST_COMMIT_DATE="2099-01-01T00:00:00Z" run_case "$dir" resume-running 1)
  count=$(trigger_count "$dir")
  if [ "$rc" = 0 ] && [ "$count" = 0 ] && grep -q 'resuming pending request 900' "$dir/err.log"; then
    pass "#1550: a future committer date does not hide the pending request from the resume check"
  else
    fail "#1550 future committer date: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# Unreadable resume evidence is not absent evidence: a transient failure is
# retried, and one that persists fails closed instead of posting a duplicate.
test_resume_read_failure_is_retried_not_reposted() {
  local dir rc count before=$FAIL
  dir=$(make_case "resume-read-502-once" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" resume-read-502-once 1)
  count=$(trigger_count "$dir")
  [ "$rc" = 0 ] || fail "#1550 resume read retry: exit $rc, expected 0; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#1550 resume read retry: posted $count trigger(s) after one transient read failure"
  grep -q 'resume-check issue comments read hit a transient GitHub read failure' "$dir/err.log" \
    || fail "#1550 resume read retry: no retry log"
  [ "$FAIL" -ne "$before" ] || pass "#1550: a transient failure reading resume evidence is retried, not turned into a new trigger"

  before=$FAIL
  dir=$(make_case "resume-read-502-always" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" resume-read-502-always 1)
  count=$(trigger_count "$dir")
  [ "$rc" = 3 ] || fail "#1550 resume read persistent: exit $rc, expected 3; stderr=$(cat "$dir/err.log")"
  [ "$count" = 0 ] || fail "#1550 resume read persistent: posted $count trigger(s) on unreadable evidence"
  [ "$FAIL" -ne "$before" ] || pass "#1550: resume evidence that stays unreadable fails closed (exit 3) without posting"
}

# Malformed trusted timeout-marker evidence fails closed, as it does for the
# cap path's preserve_final_request_timeout, instead of posting.
test_malformed_timeout_marker_fails_closed_on_resume() {
  local dir rc count
  dir=$(make_case "resume-malformed-marker" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  jq -cn '{id:901,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=abc -->",created_at:"2026-06-04T00:00:05Z"}' \
    >>"$dir/state/comments.jsonl"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  if [ "$rc" = 3 ] && [ "$count" = 0 ] && grep -q 'trusted terminal-marker evidence is malformed' "$dir/err.log"; then
    pass "#1550: malformed trusted timeout-marker evidence fails closed on the resume check"
  else
    fail "#1550 malformed marker: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# The re-run after an expired resume disables resuming outright, so the chain
# cannot loop even if a pending request still looked resumable.
test_expired_rerun_never_resumes() {
  local dir rc count
  dir=$(make_case "resume-rerun-guard" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(MERGEPATH_CODEX_RESUME_EXPIRED=1 run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  if [ "$count" = 1 ] && ! grep -q 'resuming pending request' "$dir/err.log"; then
    pass "#1550: the post-expiry re-run posts instead of resuming, so the chain cannot loop"
  else
    fail "#1550 re-run guard: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

# A current marker bound to an OLDER lowercase request does not settle a newer
# case-variant request the selector picked.
test_marker_for_older_request_does_not_block_resume() {
  local dir rc count
  dir=$(make_case "resume-marker-older" 0 0 60)
  jq -cn '{id:899,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-06-03T23:59:00Z"}' >>"$dir/state/comments.jsonl"
  jq -cn '{id:901,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa trigger_comment_id=899 -->",created_at:"2026-06-03T23:59:30Z"}' >>"$dir/state/comments.jsonl"
  jq -cn --arg created "$RESUME_TRIGGER_AT" '{id:900,user:{login:"nathanjohnpayne"},body:"@CODEX REVIEW",created_at:$created}' >>"$dir/state/comments.jsonl"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_case "$dir" resume-running 1)
  count=$(trigger_count "$dir")
  if [ "$rc" = 0 ] && [ "$count" = 0 ] && grep -q 'resuming pending request 900' "$dir/err.log"; then
    pass "#1550: a current marker bound to an older request does not block resuming a newer case-variant request"
  else
    fail "#1550 older-marker: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

test_resume_past_deadline_posts_new_request() {
  local dir rc count
  dir=$(make_case "resume-past-deadline" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 90
  rc=$(run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  if [ "$count" = 1 ] && grep -q 'past its 60s wait' "$dir/err.log"; then
    pass "#1550: a pending request already past its own deadline is not resumed"
  else
    fail "#1550 past deadline: exit $rc, $count trigger(s); stderr=$(cat "$dir/err.log")"
  fi
}

test_resumed_request_expiry_posts_new_request() {
  local dir rc count before=$FAIL
  dir=$(make_case "resume-expires" 0 0 60)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_case "$dir" absent 1)
  count=$(trigger_count "$dir")
  grep -q 'resuming pending request 900' "$dir/err.log" || fail "#1550 resume expiry: request was not resumed first"
  grep -q 'resumed request 900 drew no Codex response.*re-running as a fresh request' "$dir/err.log" || fail "#1550 resume expiry: no expiry log"
  [ "$(grep -c 'resuming pending request' "$dir/err.log")" = 1 ] || fail "#1550 resume expiry: the fresh re-run resumed again"
  [ "$(grep -c 'fetching HEAD commit metadata' "$dir/err.log")" = 2 ] \
    || fail "#1550 resume expiry: the replacement did not run as a fresh invocation that re-reads the live head"
  [ "$(jq -r '.request_resumed' "$dir/out.json")" = true ] || fail "#1550 resume expiry: the re-run did not report the invocation's resume"
  [ "$count" = 1 ] || fail "#1550 resume expiry: $count trigger(s), expected exactly one replacement request"
  # Only the replacement, which this run posted, may mint the timeout marker.
  [ "$rc" = 4 ] || fail "#1550 resume expiry: exit $rc, expected 4 after the replacement also timed out; stderr=$(cat "$dir/err.log")"
  [ "$(jq -r '.terminal_determination.outcome // "none"' "$dir/out.json")" = timeout ] \
    || fail "#1550 resume expiry: the replacement's timeout was not recorded"
  [ "$FAIL" -ne "$before" ] || pass "#1550: a resumed request that expires unanswered is replaced, and only the replacement records a timeout"
}

# --- #1550: transient poll-read failures are retried ----------------------

test_transient_poll_failure_is_retried() {
  local dir rc before=$FAIL
  dir=$(make_case "poll-502-once" 0 0 60)
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" poll-502-once)
  [ "$rc" = 0 ] || fail "#1550 transient: exit $rc, expected 0 after one retried 502; stderr=$(cat "$dir/err.log")"
  grep -q 'transient GitHub read failure (attempt 1/3)' "$dir/err.log" || fail "#1550 transient: no retry log"
  [ "$(trigger_count "$dir")" = 1 ] || fail "#1550 transient: retry posted another trigger"
  [ "$FAIL" -ne "$before" ] || pass "#1550: one HTTP 502 during the review wait is retried, not fatal"
}

test_persistent_transient_failure_fails_closed() {
  local dir rc
  dir=$(make_case "poll-502-always" 0 0 60)
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" poll-502-always)
  if [ "$rc" = 3 ] && grep -q 'persisted across 3 attempt(s)' "$dir/err.log"; then
    pass "#1550: a transient failure that persists across every retry still exits 3"
  else
    fail "#1550 persistent transient: exit $rc; stderr=$(cat "$dir/err.log")"
  fi
}

test_permanent_poll_failure_is_not_retried() {
  local dir rc
  dir=$(make_case "poll-404" 0 0 60)
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" poll-404)
  if [ "$rc" = 3 ] && ! grep -q 'transient GitHub read failure' "$dir/err.log"; then
    pass "#1550: a permanent read failure (HTTP 404) exits 3 without a retry"
  else
    fail "#1550 permanent: exit $rc; stderr=$(cat "$dir/err.log")"
  fi
}

test_missing_classifier_degrades_to_fail_closed() {
  local dir rc
  dir=$(make_case "poll-502-no-classifier" 0 0 60)
  rm -f "$dir/scripts/lib/gh-retry-helpers.sh"
  rc=$(MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS=0 run_case "$dir" poll-502-once)
  if [ "$rc" = 3 ] && ! grep -q 'transient GitHub read failure' "$dir/err.log"; then
    pass "#1550: without gh-retry-helpers.sh a failed poll read exits 3 at once (pre-#1550 behaviour, never weaker)"
  else
    fail "#1550 missing classifier: exit $rc; stderr=$(cat "$dir/err.log")"
  fi
}

test_default_reply_deadline_is_1800() {
  local dir
  dir=$(make_case "default-deadline" 0 0 0)
  sed -i.bak '/review_timeout_seconds/d' "$dir/.github/review-policy.yml"
  run_case "$dir" skip_review >/dev/null
  if grep -q 'timeout = 1800s' "$dir/err.log"; then
    pass "#1550: an absent codex.review_timeout_seconds defaults to 1800s"
  else
    fail "#1550 default deadline: $(grep 'timeout =' "$dir/err.log")"
  fi
}

test_prior_reaction_cannot_clear_backdated_ordinary_push
# Drive the shipped author wrapper and its canonical trigger authorization.
# The existing transport fake remains only the final GH write sink.
make_real_wrapper_case() {
  local dir=$1 name
  mv "$dir/scripts/gh-as-author.sh" "$dir/scripts/fixture-author-transport.sh"
  cp "$ROOT/scripts/gh-as-author.sh" "$dir/scripts/gh-as-author-real.sh"
  for name in gh-token-resolver.sh gh-command-classifier.sh pr-body-contract.sh reviewers-helpers.sh credential-class.sh gh-comment-trigger-guard.sh gh-rest-transport.sh; do
    cp "$ROOT/scripts/lib/$name" "$dir/scripts/lib/$name"
  done
  for name in gh-comment-trigger-guard.py owner-admin-override.py merge-writer.py; do
    cp "$ROOT/scripts/workflow/$name" "$dir/scripts/workflow/$name"
  done
  printf '#!/bin/sh\nexit 0\n' > "$dir/scripts/identity-check.sh"
  chmod +x "$dir/scripts/identity-check.sh"
  mv "$dir/bin/gh" "$dir/bin/fixture-read-gh"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  exec "$here/../scripts/fixture-author-transport.sh" -- gh "$@"
fi
# #1362: the wrapper reads its posted comment back by id, inside its claim.
if [ "${1:-}" = api ] && [ "$#" -eq 2 ] && [[ "$2" =~ ^repos/owner/repo/issues/comments/([0-9]+)$ ]]; then
  jq -ce --argjson id "${BASH_REMATCH[1]}" 'select(.id == $id) + {issue_url: "https://api.github.com/repos/owner/repo/issues/999"}' \
    "$CODEX_TEST_STATE_DIR/comments.jsonl" | head -1 | grep .
  exit
fi
# #2664: optionally land a web-UI request during the wrapper's claimed
# recount, once, so that authorization refuses the write it was decided for.
if [ "${CODEX_TEST_WEB_REQUEST_AT_RECOUNT:-0}" = 1 ] && [ -n "${MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION:-}" ] \
   && [ -f "$CODEX_TEST_STATE_DIR/trigger-count" ] && [ ! -f "$CODEX_TEST_STATE_DIR/web-request" ] && printf '%s\n' "$@" | grep -qx 'repos/owner/repo/issues/999/comments'; then
  touch "$CODEX_TEST_STATE_DIR/web-request"
  jq -cn '{id:5000,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-06-04T00:03:00Z"}' >>"$CODEX_TEST_STATE_DIR/comments.jsonl"
fi
# Optionally hold the wrapper's authorization recount (the only reads made
# with an observed request generation) until the gate file exists.
if [ -n "${CODEX_TEST_RECOUNT_GATE:-}" ] && [ -n "${MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION:-}" ] \
   && printf '%s\n' "$@" | grep -qx 'repos/owner/repo/issues/999/comments'; then
  : > "$CODEX_TEST_STATE_DIR/recount.${CODEX_TEST_WRAPPER_ID:-x}"
  while [ ! -e "$CODEX_TEST_RECOUNT_GATE" ]; do sleep 0.05; done
fi
exec "$here/fixture-read-gh" "$@"
SH
  cat > "$dir/scripts/gh-as-author.sh" <<'SH'
#!/usr/bin/env bash
rc=0
export MERGEPATH_CODEX_REQUEST_CLAIM_DIR="$CODEX_TEST_STATE_DIR/claims" CODEX_TEST_WRAPPER_ID=$$
: > "$CODEX_TEST_STATE_DIR/wrapper-entered.$$"
if [ "${CODEX_TEST_SCENARIO:-}" = wrapper-other-failure ] && [ -f "$CODEX_TEST_STATE_DIR/trigger-count" ]; then
  echo 'unrelated wrapper transport failure' >&2
  exit 42
fi
output=$("$(dirname "$0")/gh-as-author-real.sh" "$@" 2>&1) || rc=$?
printf '%s\n' "$output"
if [ "$rc" -ne 0 ] && grep -Fqx '[codex-review-request] ERROR: trigger not authorized: existing-trigger' <<< "$output"; then
  touch "$CODEX_TEST_STATE_DIR/authorization-refused"
  if [ "${CODEX_TEST_SCENARIO:-}" = wrapper-superseded ]; then
    jq -cn '{id:9001,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-06-04T00:00:10Z"}' \
      >> "$CODEX_TEST_STATE_DIR/comments.jsonl"
  fi
fi
exit "$rc"
SH
  chmod +x "$dir/bin/gh" "$dir/scripts/gh-as-author.sh"
}

test_real_wrapper_duplicate_ack_retry_keeps_polling() {
  local scenario dir rc expected before count
  for scenario in wrapper-slow-ack wrapper-no-response wrapper-other-failure wrapper-superseded; do
    before=$FAIL
    dir=$(make_case "$scenario" 0 1)
    make_real_wrapper_case "$dir"
    rc=$(MERGEPATH_GH_TRANSPORT=gh run_case "$dir" "$scenario" 0 ghp_fixture_author)
    count=$(trigger_count "$dir")
    case "$scenario" in wrapper-slow-ack) expected=0 ;; wrapper-no-response) expected=4 ;; *) expected=3 ;; esac
    [ "$rc" = "$expected" ] || fail "#2582 $scenario: exit $rc, expected $expected; stderr=$(cat "$dir/err.log")"
    [ "$count" = 1 ] || fail "#2582 $scenario: expected only the confirmed original trigger, got $count"
    if [ "$scenario" = wrapper-slow-ack ] || [ "$scenario" = wrapper-no-response ]; then
      [ -f "$dir/state/authorization-refused" ] || fail "#2582 $scenario: real wrapper did not exercise canonical duplicate refusal"
      grep -q 'existing trigger.*continuing normal review poll' "$dir/err.log" \
        || fail "#2582 $scenario: missing bounded-poll recovery diagnostic"
    elif [ "$scenario" = wrapper-other-failure ]; then
      grep -q 'unrelated wrapper transport failure' "$dir/err.log" || fail '#2582 unrelated error was hidden'
    else
      [ -f "$dir/state/authorization-refused" ] || fail '#2582 superseded: canonical refusal was not exercised'
      if grep -q 'existing trigger.*continuing normal review poll' "$dir/err.log"; then
        fail '#2582 superseded: a newer request inherited the original poll recovery'
      fi
    fi
    [ "$FAIL" -ne "$before" ] || pass "#2582 real wrapper: $scenario keeps its intended poll/error disposition"
  done
}

test_real_wrapper_duplicate_ack_retry_keeps_polling

# #1362: two requesters for the same PR both decide to post against an empty
# timeline. The first wrapper is held at its authorization recount; the second
# must wait for the per-PR claim instead of recounting the same timeline, and
# then refuse. Exactly one trigger is posted, in either request mode.
test_real_wrapper_claim_lets_one_of_two_requesters_post() {
  local mode flag dir before n rc_a rc_b pid_a pid_b
  for mode in trigger-only poll; do
    before=$FAIL
    dir=$(make_case "wrapper-claim-$mode" 0 0 0)
    make_real_wrapper_case "$dir"
    flag=""; [ "$mode" = poll ] || flag=--trigger-only
    for n in a b; do
      (
        cd "$dir"
        unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
        # shellcheck disable=SC2086 # flag is empty or one word
        PATH="$dir/bin:$PATH" GH_TOKEN=ghp_fixture_author CODEX_TEST_STATE_DIR="$dir/state" CODEX_TEST_FAKE_CLOCK=0 \
          CODEX_TEST_SCENARIO=absent CODEX_TEST_RECOUNT_GATE="$dir/state/recount-gate" MERGEPATH_GH_TRANSPORT=gh \
          ./scripts/codex-review-request.sh $flag 999 owner/repo >"$dir/out.$n.json" 2>"$dir/err.$n.log"
      ) &
      if [ "$n" = a ]; then pid_a=$!; else pid_b=$!; fi
    done
    wait_for_count() { # <glob-prefix> <count>
      local i=0
      while [ "$(find "$dir/state" -name "$1*" | wc -l | tr -d ' ')" -lt "$2" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
    }
    wait_for_count recount. 1
    wait_for_count wrapper-entered. 2
    sleep 1.5
    [ "$(find "$dir/state" -name 'recount.*' | wc -l | tr -d ' ')" = 1 ] \
      || fail "#1362 $mode: the second wrapper recounted while the first held the claim"
    [ "$(find "$dir/state" -name 'wrapper-entered.*' | wc -l | tr -d ' ')" = 2 ] \
      || fail "#1362 $mode: both requesters must reach the wrapper for the race to be real"
    touch "$dir/state/recount-gate"
    rc_a=0; wait "$pid_a" || rc_a=$?
    rc_b=0; wait "$pid_b" || rc_b=$?
    [ "$(trigger_count "$dir")" = 1 ] || fail "#1362 $mode: $(trigger_count "$dir") triggers posted, expected exactly one"
    if [ "$rc_a" != 3 ] && [ "$rc_b" != 3 ]; then
      fail "#1362 $mode: one requester must refuse (rc a=$rc_a b=$rc_b)"
    elif ! grep -q 'posted first (#1362)' "$dir/err.a.log" "$dir/err.b.log"; then
      fail "#1362 $mode: the refused requester must name the concurrent request; $(cat "$dir/err.a.log" "$dir/err.b.log")"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#1362 real wrapper ($mode): two requesters held at the recount post exactly one trigger"
  done
}

test_real_wrapper_claim_lets_one_of_two_requesters_post

# #2582: polling mode posts a new request while an earlier trigger is on HEAD
# by design. The real wrapper's authorization must apply that mode, not refuse
# the write as a #489 duplicate: a pending request with no provider evidence,
# and the replacement for a resumed request that expired.
test_real_wrapper_authorizes_polling_mode_new_requests() {
  local scenario dir rc count before
  for scenario in unproven-pending resumed-expiry; do
    before=$FAIL
    dir=$(make_case "wrapper-$scenario" 0 0 60)
    make_real_wrapper_case "$dir"
    seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
    [ "$scenario" != resumed-expiry ] || seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
    set_clock_after_request "$dir" 30
    rc=$(MERGEPATH_GH_TRANSPORT=gh run_case "$dir" absent 1 ghp_fixture_author)
    count=$(trigger_count "$dir")
    case "$scenario" in
      unproven-pending)
        grep -q 'pending request 900 has no Codex Running summary' "$dir/err.log" \
          || fail "#2582 $scenario: the pending request was not considered for resume" ;;
      resumed-expiry)
        grep -q 'resumed request 900 drew no Codex response.*re-running as a fresh request' "$dir/err.log" \
          || fail "#2582 $scenario: the resumed request did not expire into a fresh run" ;;
    esac
    [ ! -f "$dir/state/authorization-refused" ] && ! grep -q 'trigger not authorized' "$dir/err.log" \
      || fail "#2582 $scenario: the real authorization refused a polling-mode new request; stderr=$(cat "$dir/err.log")"
    [ "$count" = 1 ] || fail "#2582 $scenario: $count trigger(s), expected exactly one new request"
    [ "$rc" = 4 ] && [ "$(jq -r '.terminal_determination.outcome // "none"' "$dir/out.json")" = timeout ] \
      || fail "#2582 $scenario: exit $rc, expected 4 with the new request's recorded timeout; stderr=$(cat "$dir/err.log")"
    [ "$FAIL" -ne "$before" ] || pass "#2582 real wrapper: $scenario posts its new request through the canonical authorization"
  done
}

test_real_wrapper_authorizes_polling_mode_new_requests

test_eyes_ack_does_not_retrigger_or_clear
test_missing_ack_retriggers_once
test_ack_retry_ignores_blocking_budget_value
test_retry_cap_respected
test_request_attempt_cap_suppresses_ack_retry_but_polls
test_reused_final_slot_trigger_polls_arriving_response
test_reused_final_slot_polls_on_a_young_head
test_reused_final_slot_polls_despite_unreadable_ledger
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
test_candidate_author_cannot_reset_governing_request_cap
test_invalid_governing_author_refuses_new_write
test_non_author_token_is_not_bridged
test_non_bridge_path_passes_configured_identity
test_missing_identity_checker_skips_bridge
test_ambient_author_pat_is_not_inherited_or_echoed
test_secret_descriptor_never_reveals_the_value
test_resume_running_request_posts_nothing
test_resume_requires_provider_evidence
test_answered_request_is_not_resumed
test_resumed_block_does_not_clear_on_stale_review
test_resume_survives_short_freshness_window
test_resume_survives_future_committer_date
test_resume_read_failure_is_retried_not_reposted
test_malformed_timeout_marker_fails_closed_on_resume
test_expired_rerun_never_resumes
test_marker_for_older_request_does_not_block_resume
test_request_with_timeout_marker_is_not_resumed
test_resume_past_deadline_posts_new_request
test_resumed_request_expiry_posts_new_request
test_transient_poll_failure_is_retried
test_persistent_transient_failure_fails_closed
test_permanent_poll_failure_is_not_retried
test_missing_classifier_degrades_to_fail_closed
test_default_reply_deadline_is_1800

# --- #2664 bounded automatic retry -------------------------------------------
# The fake clock drives every timing: the poll sleeps 15 s per step, the retry
# backoff is 60 s (or the provider's longer window), the diagnostic is at 300
# s and an active or unknown run is reported at the 1800 s review timeout.

run_retry_case() { # <fixture-dir> <scenario> [VAR=value ...]
  local dir=$1 scenario=$2 rc=0
  shift 2
  (
    cd "$dir"
    unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
    env CODEX_TEST_EYES=1 PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_FAKE_CLOCK=1 CODEX_TEST_SCENARIO="$scenario" "$@" \
      ./scripts/codex-review-request.sh 999 owner/repo >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

retry_markers() { # <fixture-dir> -> the retry markers the requester posted
  [ -f "$1/state/comments.jsonl" ] || return 0
  jq -r 'select(.body | startswith("<!-- mergepath-codex-retry:v1 ")) | .body | split("\n")[0]' "$1/state/comments.jsonl"
}

trigger_gap() { # <fixture-dir> -> seconds between the first two triggers
  sed -n '1p;2p' "$1/state/trigger-times" | paste -sd' ' - | awk '{print $2 - $1}'
}

seed_old_triggers() { # <fixture-dir> <count>
  local i
  for i in $(seq 1 "$2"); do
    seed_author_trigger "$1" "$((800 + i))" "2026-06-03T00:00:0${i:0:1}Z"
  done
}

FAILED_ROW='❌ **Failed**'

test_retry_after_confirmed_failure() {
  local label status dir rc before scenario
  while IFS='|' read -r label status; do
    before=$FAIL
    dir=$(make_case "retry-$label" 0 0 400)
    seed_codex_summary "$dir" "$status" aaaaaaa "2026-06-04T00:00:10Z"
    # completed: seen Running first, then Completed with no result.
    scenario=review_after_retry; [ "$label" != completed ] || scenario=retry-completes
    rc=$(run_retry_case "$dir" "$scenario")
    [ "$rc" = 0 ] || fail "#2664 $label: exit $rc, expected the retry's response; stderr=$(tail -5 "$dir/err.log")"
    [ "$(trigger_count "$dir")" = 2 ] || fail "#2664 $label: $(trigger_count "$dir") triggers, expected the original and one retry"
    jq -e --arg reason "$label" '.retry.state == "posted" and .retry.reason == $reason and .retry.backoff_seconds == 60
        and .retry.original_comment_id == 1001 and .retry.retry_comment_id == 1003' "$dir/out.json" >/dev/null \
      || fail "#2664 $label: retry JSON $(jq -c .retry "$dir/out.json" 2>/dev/null)"
    [ "$(retry_markers "$dir")" = "<!-- mergepath-codex-retry:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa original=1001 -->
<!-- mergepath-codex-retry:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa original=1001 retry=1003 -->" ] \
      || fail "#2664 $label: expected the intent marker for 1001, then its binding to retry 1003; got $(retry_markers "$dir")"
    # Seen failed by the scan right after the post (completed: two polls
    # later), then 60 s of backoff.
    [ "$(trigger_gap "$dir")" -ge 60 ] && [ "$(trigger_gap "$dir")" -le 105 ] \
      || fail "#2664 $label: retry posted $(trigger_gap "$dir")s after the original, expected 60-105"
    [ "$FAIL" -ne "$before" ] || pass "#2664: a $label run is retried once, 60 s after it is confirmed"
  done <<'CASES'
failed|❌ **Failed**
canceled|🚫 **Cancelled**
completed|⏳ **Running**
CASES
}

# A Completed row that this run never saw Running may describe an earlier
# request's run that finished after this request was posted: no retry.
test_retry_withheld_for_unproven_completion() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-unproven-completed" 0 0 400)
  seed_codex_summary "$dir" '✅ **Completed**' aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" absent)
  [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 unproven completion: $(trigger_count "$dir") triggers, expected no retry"
  [ -z "$(retry_markers "$dir")" ] || fail "#2664 unproven completion: a retry marker was recorded"
  jq -e '.retry.state == "escalated" and .retry.reason == "unknown"' "$dir/out.json" >/dev/null \
    || fail "#2664 unproven completion: $(jq -c .retry "$dir/out.json" 2>/dev/null)"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a Completed row never seen Running for this request is not proof of inactivity"
}

test_retry_honors_longer_provider_window() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-window" 0 0 600)
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z" 'Codex is busy. Please try again in 3 minutes.'
  rc=$(run_retry_case "$dir" review_after_retry)
  [ "$rc" = 0 ] && [ "$(trigger_count "$dir")" = 2 ] || fail "#2664 window: exit $rc, $(trigger_count "$dir") triggers"
  jq -e '.retry.backoff_seconds == 180' "$dir/out.json" >/dev/null || fail "#2664 window: $(jq -c .retry "$dir/out.json")"
  [ "$(trigger_gap "$dir")" -ge 180 ] && [ "$(trigger_gap "$dir")" -le 195 ] \
    || fail "#2664 window: retry posted $(trigger_gap "$dir")s after the original, expected 180-195"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a provider retry window longer than 60 s sets the backoff"
}

# The provider states a longer window while the retry is already scheduled.
test_retry_window_lengthened_while_scheduled() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-window-late" 0 0 600)
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" retry-window-late)
  [ "$rc" = 0 ] && [ "$(trigger_count "$dir")" = 2 ] || fail "#2664 late window: exit $rc, $(trigger_count "$dir") triggers"
  jq -e '.retry.backoff_seconds == 180' "$dir/out.json" >/dev/null || fail "#2664 late window: $(jq -c .retry "$dir/out.json")"
  [ "$(trigger_gap "$dir")" -ge 180 ] && [ "$(trigger_gap "$dir")" -le 195 ] \
    || fail "#2664 late window: retry posted $(trigger_gap "$dir")s after the original, expected 180-195"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a provider window stated during the backoff moves the scheduled retry out"
}

# A resumed request that is itself a retry and then fails is reported, never
# replaced by the resumed-expiry fresh request (which would retry the retry).
test_resumed_retry_is_not_replaced() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-resumed-retry" 0 0 400)
  seed_author_trigger "$dir" 880 "2026-06-03T23:50:00Z"
  jq -cn '{id:899,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-codex-retry:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa original=880 retry=900 -->\nBound.",created_at:"2026-06-04T00:00:01Z"}' \
    >>"$dir/state/comments.jsonl"
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_retry_case "$dir" retry-concurrent)
  [ "$(trigger_count "$dir")" = 0 ] || fail "#2664 resumed retry: $(trigger_count "$dir") requests posted, expected none"
  grep -q 'not posted: retry-of-retry' "$dir/err.log" || fail "#2664 resumed retry: $(tail -5 "$dir/err.log")"
  ! grep -q 're-running as a fresh request' "$dir/err.log" || fail "#2664 resumed retry: the fresh-request replacement ran"
  [ "$rc" = 4 ] && jq -e '.retry.state == "refused" and .retry.reason == "retry-of-retry"' "$dir/out.json" >/dev/null \
    || fail "#2664 resumed retry: exit $rc, $(jq -c .retry "$dir/out.json" 2>/dev/null)"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a resumed retry that fails is reported, not replaced by a fresh request"
}

# A resumed request fails less than a backoff before its own deadline: the
# retry is still scheduled at the deadline, so it is reported, and the #1550
# fresh replacement does not run ahead of the backoff.
test_scheduled_retry_at_deadline_is_reported() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-scheduled-at-deadline" 0 0 400)
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  rc=$(run_retry_case "$dir" retry-concurrent CODEX_TEST_FAIL_AT=360)
  [ "$(trigger_count "$dir")" = 0 ] || fail "#2664 scheduled at deadline: $(trigger_count "$dir") requests posted, expected none"
  ! grep -q 're-running as a fresh request' "$dir/err.log" || fail "#2664 scheduled at deadline: the fresh-request replacement ran"
  [ "$rc" = 4 ] && jq -e '.retry.state == "escalated" and (.retry.reason | startswith("retry-not-due"))' "$dir/out.json" >/dev/null \
    || fail "#2664 scheduled at deadline: exit $rc, $(jq -c .retry "$dir/out.json" 2>/dev/null)"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a retry still scheduled at the deadline is reported, not replaced"
}

# The binding names the retry that actually posted, so a losing handler's
# intent marker cannot mark a later ordinary request as a retry.
test_retry_marker_binding() {
  local before=$FAIL h=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa comments got
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/codex-request-evidence.sh"
  comments=$(jq -nc --arg h "$h" '[
    {id:10,user:{login:"a"},created_at:"2026-01-01T00:00:00Z",body:"@codex review"},
    {id:11,user:{login:"a"},created_at:"2026-01-01T00:05:00Z",body:("<!-- mergepath-codex-retry:v1 head=" + $h + " original=10 -->\nintent")},
    {id:12,user:{login:"a"},created_at:"2026-01-01T00:05:01Z",body:"@codex review"},
    {id:13,user:{login:"a"},created_at:"2026-01-01T00:05:02Z",body:("<!-- mergepath-codex-retry:v1 head=" + $h + " original=10 -->\nloser")},
    {id:14,user:{login:"a"},created_at:"2026-01-01T00:05:03Z",body:("<!-- mergepath-codex-retry:v1 head=" + $h + " original=10 retry=12 -->\nbound")},
    {id:15,user:{login:"a"},created_at:"2026-01-01T00:06:00Z",body:"@codex review"}]')
  got="$(crqe_request_is_retry "$comments" a 10) $(crqe_request_is_retry "$comments" a 12) $(crqe_request_is_retry "$comments" a 15)"
  [ "$got" = "false true false" ] || fail "#2664 binding: original/retry/next-round classified '$got', expected 'false true false'"
  # The handler stopped before binding: the intent still marks its retry.
  comments=$(printf '%s' "$comments" | jq -c '[.[] | select(.id != 13 and .id != 14)]')
  got="$(crqe_request_is_retry "$comments" a 12) $(crqe_request_is_retry "$comments" a 15)"
  [ "$got" = "true false" ] || fail "#2664 binding: an unbound intent classified '$got', expected 'true false'"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a retry is bound to the request that posted; a loser's intent marks nothing"
}

# A failure this run never saw Codex acknowledge may belong to an earlier,
# overlapping run: the row names no request. No retry.
test_retry_needs_codex_acknowledgement() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-unacknowledged" 0 0 400)
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" absent CODEX_TEST_EYES=0)
  [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 unacknowledged: $(trigger_count "$dir") triggers, expected no retry"
  [ -z "$(retry_markers "$dir")" ] || fail "#2664 unacknowledged: a retry marker was recorded"
  jq -e '.retry.state == "escalated" and .retry.reason == "unknown"' "$dir/out.json" >/dev/null \
    || fail "#2664 unacknowledged: exit $rc, $(jq -c .retry "$dir/out.json" 2>/dev/null)"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a failure is attributed to a request only after Codex acknowledged that request"
}

# A restarted session finds the latest request already failed. It resumes it
# instead of posting at once: an original waits out its own deadline before
# the #1550 replacement, and a retry is reported and never replaced.
test_restarted_session_resumes_failed_request() {
  local label dir rc before epoch first
  for label in original retry; do
    before=$FAIL
    dir=$(make_case "retry-restart-$label" 0 0 400)
    if [ "$label" = retry ]; then
      seed_author_trigger "$dir" 880 "2026-06-03T23:50:00Z"
      jq -cn '{id:899,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-codex-retry:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa original=880 retry=900 -->\nBound.",created_at:"2026-06-04T00:00:01Z"}' \
        >>"$dir/state/comments.jsonl"
    fi
    seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
    seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
    set_clock_after_request "$dir" 30
    rc=$(run_retry_case "$dir" absent CODEX_TEST_EYES=0)
    grep -q 'resuming it under the bounded retry rules' "$dir/err.log" || fail "#2664 restart $label: the failed request was not resumed; $(tail -3 "$dir/err.log")"
    epoch=$(jq -rn --arg t "$RESUME_TRIGGER_AT" '$t | fromdateiso8601')
    case "$label" in
      original)
        first=$(head -1 "$dir/state/trigger-times" 2>/dev/null || echo 0)
        [ "$(trigger_count "$dir")" = 1 ] && [ "$first" -ge $((epoch + 400)) ] \
          || fail "#2664 restart original: $(trigger_count "$dir") requests, first at +$((first - epoch))s, expected one after the 400 s deadline" ;;
      retry)
        [ "$(trigger_count "$dir")" = 0 ] && [ "$rc" = 4 ] && ! grep -q 're-running as a fresh request' "$dir/err.log" \
          && jq -e '.retry.state == "refused" and .retry.reason == "retry-of-retry"' "$dir/out.json" >/dev/null \
          || fail "#2664 restart retry: exit $rc, $(trigger_count "$dir") requests, $(jq -c .retry "$dir/out.json" 2>/dev/null)" ;;
    esac
    [ "$FAIL" -ne "$before" ] || pass "#2664: a restarted session resumes a failed $label request instead of posting at once"
  done
}

# The intent was recorded but the claimed authorization refused the retry (a
# web request landed during the recount). The intent is withdrawn by its id,
# so it never marks that web request as a retry.
test_refused_retry_withdraws_its_intent() {
  local dir rc before=$FAIL intent
  dir=$(make_case "retry-withdraw" 0 0 400)
  make_real_wrapper_case "$dir"
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" absent CODEX_TEST_WEB_REQUEST_AT_RECOUNT=1 MERGEPATH_GH_TRANSPORT=gh GH_TOKEN=ghp_fixture_author)
  [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 withdraw: $(trigger_count "$dir") requests posted by the requester, expected only the original"
  grep -q 'not posted: concurrent-request' "$dir/err.log" || fail "#2664 withdraw: $(grep '2664' "$dir/err.log" | tail -3)"
  intent=$(jq -r 'select(.body | startswith("<!-- mergepath-codex-retry:v1 ") and (test("retry=|withdrawn=") | not)) | .id' "$dir/state/comments.jsonl" | head -1)
  retry_markers "$dir" | grep -q "withdrawn=$intent -->" || fail "#2664 withdraw: no withdrawal for intent $intent; $(retry_markers "$dir")"
  (
    # shellcheck source=/dev/null
    . "$ROOT/scripts/lib/codex-request-evidence.sh"
    [ "$(crqe_request_is_retry "$(jq -sc . "$dir/state/comments.jsonl")" nathanjohnpayne 5000)" = false ]
  ) || fail "#2664 withdraw: the web request was classified as a retry"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a refused retry withdraws its intent, which then marks nothing"
}

test_retry_refused_by_late_result_or_moved_head() {
  local scenario dir rc want before
  for scenario in retry-late-at-fence retry-head-changed; do
    before=$FAIL
    dir=$(make_case "$scenario" 0 0 400)
    seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
    rc=$(run_retry_case "$dir" "$scenario")
    case "$scenario" in retry-late-at-fence) want=late-result ;; *) want=head-changed ;; esac
    [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 $scenario: $(trigger_count "$dir") triggers, expected no retry"
    [ -z "$(retry_markers "$dir")" ] || fail "#2664 $scenario: a retry marker was recorded"
    grep -q "automatic Codex retry for request 1001 not posted: $want" "$dir/err.log" \
      || fail "#2664 $scenario: expected refusal '$want'; stderr=$(tail -5 "$dir/err.log")"
    if [ "$scenario" = retry-late-at-fence ]; then
      [ "$rc" = 0 ] || fail "#2664 late result: exit $rc, expected the late response to end the wait"
    fi
    [ "$FAIL" -ne "$before" ] || pass "#2664: $want immediately before posting prevents the retry"
  done
}

test_retry_never_chains() {
  local dir rc before=$FAIL
  dir=$(make_case "retry-no-chain" 0 0 400)
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" absent)
  [ "$rc" = 4 ] || fail "#2664 chain: exit $rc, expected the retry's own timeout"
  [ "$(trigger_count "$dir")" = 2 ] || fail "#2664 chain: $(trigger_count "$dir") triggers, expected exactly one retry"
  [ "$(retry_markers "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "#2664 chain: $(retry_markers "$dir" | wc -l) markers, expected one intent and one binding"
  jq -e '.retry.state == "posted"' "$dir/out.json" >/dev/null || fail "#2664 chain: $(jq -c .retry "$dir/out.json")"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a failed retry is never retried"
}

test_retry_withheld_from_a_retry_request() {
  # A marker just before this run's own request marks that request as a
  # retry (another handler, or an earlier session, already retried).
  local dir rc before=$FAIL
  dir=$(make_case "retry-of-retry" 0 0 400)
  jq -cn '{id:999,user:{login:"nathanjohnpayne"},body:"<!-- mergepath-codex-retry:v1 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa original=990 -->\nAutomatic retry.",created_at:"2026-06-03T23:59:59Z"}' \
    >>"$dir/state/comments.jsonl"
  seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
  rc=$(run_retry_case "$dir" absent)
  [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 retry-of-retry: $(trigger_count "$dir") triggers"
  grep -q 'not posted: retry-of-retry' "$dir/err.log" || fail "#2664 retry-of-retry: $(tail -5 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "#2664: a request that is itself a retry is never retried (persisted across sessions)"
}

test_retry_withheld_while_active_or_unknown() {
  local label status updated dir rc want before
  while IFS='|' read -r label status updated want; do
    before=$FAIL
    dir=$(make_case "retry-$label" 0 0 1800)
    seed_codex_summary "$dir" "$status" aaaaaaa "$updated"
    rc=$(run_retry_case "$dir" absent)
    [ "$rc" = 4 ] || fail "#2664 $label: exit $rc, expected the 1800 s escalation"
    [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 $label: $(trigger_count "$dir") triggers, expected no retry"
    [ -z "$(retry_markers "$dir")" ] || fail "#2664 $label: a retry marker was recorded"
    jq -e --arg want "$want" '.retry.state == "escalated" and .retry.reason == $want
        and .retry.diagnostic.after_seconds >= 300 and .retry.diagnostic.after_seconds < 315
        and .rounds_waited_seconds >= 1800' "$dir/out.json" >/dev/null \
      || fail "#2664 $label: $(jq -c '{retry, rounds_waited_seconds}' "$dir/out.json" 2>/dev/null)"
    [ "$FAIL" -ne "$before" ] || pass "#2664: a $label run gets a 300 s diagnostic and is reported at 1800 s, never retried"
  done <<'CASES'
active|⏳ **Running**|2026-06-04T00:00:10Z|active
stale-placeholder|⏳ **Running**|2026-06-03T23:00:00Z|unknown
unknown-status|❓ **Queued**|2026-06-04T00:00:10Z|unknown
CASES
}

test_retry_respects_request_and_blocking_budgets() {
  local label prior spend dir rc before
  while IFS='|' read -r label prior spend; do
    before=$FAIL
    dir=$(make_case "retry-budget-$label" 0 0 400)
    seed_old_triggers "$dir" "$prior"
    seed_codex_summary "$dir" "$FAILED_ROW" aaaaaaa "2026-06-04T00:00:10Z"
    if [ "$spend" = spend ]; then
      rc=$(run_retry_case "$dir" review_after_retry CODEX_LEDGER_STUB_SPEND_POLICY="$dir/state/base-review-policy.yml")
    else
      rc=$(run_retry_case "$dir" review_after_retry)
    fi
    case "$label" in
      tenth-allowed)
        [ "$rc" = 0 ] && [ "$(trigger_count "$dir")" = 2 ] \
          || fail "#2664 $label: the tenth request may be the retry (exit $rc, $(trigger_count "$dir") triggers)" ;;
      ceiling)
        [ "$rc" = 4 ] && [ "$(trigger_count "$dir")" = 1 ] && jq -e '.retry.reason == "request-ceiling"' "$dir/out.json" >/dev/null \
          || fail "#2664 $label: exit $rc, $(trigger_count "$dir") triggers, $(jq -c .retry "$dir/out.json" 2>/dev/null)" ;;
      blocking|both)
        [ "$rc" = 7 ] && [ "$(trigger_count "$dir")" = 1 ] && jq -e '.cap_exhausted.kind == "blocking-reviews"' "$dir/out.json" >/dev/null \
          || fail "#2664 $label: exit $rc, $(trigger_count "$dir") triggers, $(jq -c .cap_exhausted "$dir/out.json" 2>/dev/null)" ;;
    esac
    [ -z "$(retry_markers "$dir")" ] || [ "$label" = tenth-allowed ] \
      || fail "#2664 $label: a retry marker was recorded although the budget refused the retry"
    [ "$FAIL" -ne "$before" ] || pass "#2664 budgets: $label"
  done <<'CASES'
tenth-allowed|8|no
ceiling|9|no
blocking|0|spend
both|9|spend
CASES
}

# Two sessions resumed on the same request both see its run fail. Retry
# deduplication through the guarded, claimed path posts exactly one retry.
test_concurrent_handlers_post_one_retry() {
  local dir before=$FAIL n pid_a pid_b rc_a=0 rc_b=0 posted
  dir=$(make_case "retry-concurrent" 0 0 400)
  make_real_wrapper_case "$dir"
  seed_author_trigger "$dir" 900 "$RESUME_TRIGGER_AT"
  seed_codex_summary "$dir" '⏳ **Running**' aaaaaaa "2026-06-04T00:00:10Z"
  set_clock_after_request "$dir" 30
  for n in a b; do
    (
      cd "$dir"
      unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
      PATH="$dir/bin:$PATH" GH_TOKEN=ghp_fixture_author CODEX_TEST_STATE_DIR="$dir/state" CODEX_TEST_FAKE_CLOCK=1 \
        CODEX_TEST_SCENARIO=retry-concurrent MERGEPATH_GH_TRANSPORT=gh CODEX_TEST_EYES=1 \
        ./scripts/codex-review-request.sh 999 owner/repo >"$dir/out.$n.json" 2>"$dir/err.$n.log"
    ) &
    if [ "$n" = a ]; then pid_a=$!; else pid_b=$!; fi
  done
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?
  [ "$(trigger_count "$dir")" = 1 ] || fail "#2664 concurrent: $(trigger_count "$dir") retries posted, expected one"
  posted=$(jq -s '[.[] | select(.retry.state == "posted")] | length' "$dir/out.a.json" "$dir/out.b.json" 2>/dev/null || echo error)
  [ "$posted" = 1 ] || fail "#2664 concurrent: $posted handlers report a posted retry (rc a=$rc_a b=$rc_b); $(tail -3 "$dir/err.a.log" "$dir/err.b.log")"
  # The other stands down at whichever check sees the winner first: the
  # latest-request check, the claimed generation fence, or the result.
  jq -s -e '[.[] | select(.retry.state == "refused") | .retry.reason] | length == 1 and (.[0] | IN("superseded", "concurrent-request", "existing-trigger", "already-cleared"))' \
    "$dir/out.a.json" "$dir/out.b.json" >/dev/null || fail "#2664 concurrent: the other handler must stand down; $(jq -c .retry "$dir/out.a.json" "$dir/out.b.json" 2>/dev/null)"
  [ "$(retry_markers "$dir" | grep -c 'retry=')" = 1 ] \
    && retry_markers "$dir" | grep -q "original=900 retry=$(jq -r 'select(.body == "@codex review" and .id > 1000) | .id' "$dir/state/comments.jsonl" | head -1) -->" \
    || fail "#2664 concurrent: expected one binding naming the posted retry; $(retry_markers "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "#2664: two concurrent handlers post exactly one retry for the same request"
}

test_retry_after_confirmed_failure
test_retry_withheld_for_unproven_completion
test_retry_honors_longer_provider_window
test_retry_window_lengthened_while_scheduled
test_resumed_retry_is_not_replaced
test_retry_marker_binding
test_scheduled_retry_at_deadline_is_reported
test_retry_needs_codex_acknowledgement
test_restarted_session_resumes_failed_request
test_refused_retry_withdraws_its_intent
test_retry_refused_by_late_result_or_moved_head
test_retry_never_chains
test_retry_withheld_from_a_retry_request
test_retry_withheld_while_active_or_unknown
test_retry_respects_request_and_blocking_budgets
test_concurrent_handlers_post_one_retry

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
