#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's --trigger-only mode (#489),
# used by coderabbit-wait.sh's rate-limit failover.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# trigger-only path is deterministic and makes no GitHub writes. Verifies:
#   - fresh HEAD: posts exactly ONE @codex trigger, exits 0 WITHOUT polling and
#     WITHOUT an ack-retry (the trigger-only exit is before run_trigger_ack_gate
#     — Codex P2 #3 on #512); JSON carries trigger_only:true, trigger_posted:true.
#   - idempotent: an existing author @codex trigger on HEAD → skips the post
#     (trigger_posted:false), exits 0.
#   - author-scoped (Codex P2 #1 on #512): a *reviewer*-authored @codex review
#     does NOT count as a valid trigger → still posts.
#
# Bash 3.2 portable. Mirrors tests/test_codex_review_request_ack.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-trigger-only.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"

  cat >"$dir/.github/review-policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  review_timeout_seconds: 0
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: 0
  max_ack_retries: 2
EOF

  # gh-as-author stub: records each @codex trigger post.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
if [ "${9:-}" != "@codex review" ]; then
  echo "trigger body was not exact '@codex review': $*" >&2; exit 98
fi
count=0
[ -f "$state_dir/trigger-count" ] && count=$(cat "$state_dir/trigger-count")
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/trigger-count"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$((1000 + count))"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${CODEX_TEST_SCENARIO:?}
author='nathanjohnpayne'
reviewer='nathanpayne-codex'
t='2026-06-04T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
[ "${1:-}" = "--paginate" ] && shift
endpoint=${1:-}
case "$endpoint" in
  repos/owner/repo/pulls/999)            printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)     printf '%s\n' "$t" ;;
  repos/owner/repo/issues/999/timeline)  printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)    printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)   printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    case "$scenario" in
      dup_author)    printf '[{"id":7001,"user":{"login":"%s"},"created_at":"%s","body":"@codex review"}]\n' "$author" "$t" ;;
      reviewer_only) printf '[{"id":7002,"user":{"login":"%s"},"created_at":"%s","body":"@codex review"}]\n' "$reviewer" "$t" ;;
      *)             printf '[]\n' ;;
    esac
    ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s\n' "$dir"
}

run_trigger_only() {
  local dir=$1 scenario=$2 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

trig_count() { if [ -f "$1/state/trigger-count" ]; then cat "$1/state/trigger-count"; else printf '0\n'; fi; }
jqf() { jq -r "$2" "$1/out.json"; }

# A: fresh HEAD → posts once, exits 0, no poll, no ack-retry (#3), JSON shape
test_fresh_posts_once_no_poll() {
  local dir rc before=$FAIL
  dir=$(make_case "fresh")
  rc=$(run_trigger_only "$dir" fresh)
  [ "$rc" = "0" ] || fail "A: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "A: expected exactly 1 @codex post (no ack-retry), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_only')" = "true" ] || fail "A: trigger_only=$(jqf "$dir" '.trigger_only'), expected true"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "A: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$(jqf "$dir" '.rounds_waited_seconds')" = "0" ] || fail "A: rounds_waited_seconds=$(jqf "$dir" '.rounds_waited_seconds'), expected 0 (no poll)"
  [ "$FAIL" -ne "$before" ] || pass "A: fresh HEAD posts one @codex trigger, exits 0 without polling/ack-retry"
}

# B: existing AUTHOR trigger on HEAD → idempotent skip
test_dup_author_skips() {
  local dir rc before=$FAIL
  dir=$(make_case "dup")
  rc=$(run_trigger_only "$dir" dup_author)
  [ "$rc" = "0" ] || fail "B: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "B: expected 0 posts (idempotent skip), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "B: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "B: existing author @codex trigger on HEAD → idempotent skip (no duplicate)"
}

# C: only a REVIEWER-authored trigger → not a valid trigger, still posts (#1)
test_reviewer_trigger_does_not_count() {
  local dir rc before=$FAIL
  dir=$(make_case "reviewer")
  rc=$(run_trigger_only "$dir" reviewer_only)
  [ "$rc" = "0" ] || fail "C: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "C: reviewer-authored @codex must NOT count → expected 1 post, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "C: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$FAIL" -ne "$before" ] || pass "C: reviewer-authored @codex is not a valid trigger (author-scoped dedupe) → still posts"
}

test_fresh_posts_once_no_poll
test_dup_author_skips
test_reviewer_trigger_does_not_count

echo "----"
echo "test_codex_review_request_trigger_only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
