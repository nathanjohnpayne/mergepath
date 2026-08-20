#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's write-token resolution
# (#737): the `@codex review` trigger must succeed whenever EITHER a fresh
# op-preflight cache OR the gh keyring author account is available, and must
# fail LOUD (not silently no-op) when neither resolves.
#
# Background: the script used to hard-guard on GH_TOKEN and exit 3 BEFORE ever
# posting the trigger. The op-preflight auto-source only sets GH_TOKEN from a
# FRESH cache (TTL 36000s = 10h since #765); on a long session it lapses, GH_TOKEN
# unsets, the guard trips, and `@codex review` silently no-ops even though
# `gh auth token --user nathanjohnpayne` resolves fine. Callers pipe the script
# through `| tail -1` and ignore the exit code, so the no-op is invisible and
# the PR proceeds as if Codex was asked (observed on gaycruisebingo #78/#79).
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# token-resolution path is deterministic and makes no GitHub writes. The gh
# stub handles BOTH `gh auth token --user <author>` (the keyring fallback) and
# the `gh api` reads; it records whether the keyring branch was consulted.
# Bash 3.2 portable. Mirrors tests/test_codex_review_request_trigger_only.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-fallback.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a case dir. $2 (keyring_ok): "1" => `gh auth token --user` returns a
# token; "0" => it exits 1 (empty). The gh stub touches state/keyring-called
# whenever the keyring branch runs so a test can assert it was NOT consulted
# when GH_TOKEN is already set (backward compat).
make_case() {
  local name=$1
  local keyring_ok=$2
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced

  cat >"$dir/.github/review-policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  review_timeout_seconds: 0
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: 0
  max_ack_retries: 0
EOF

  # gh-as-author stub: records each @codex trigger post and returns a
  # comment URL so TRIGGER_COMMENT_ID extraction (and the #737 readback)
  # sees an id.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
c=0; [ -f "$state_dir/trigger-count" ] && c=$(cat "$state_dir/trigger-count")
c=$((c + 1)); printf '%s\n' "$c" >"$state_dir/trigger-count"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$((1000 + c))"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
now='2026-06-04T00:00:00Z'
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "token" ]; then
  touch "$dir/state/keyring-called"
  if [ "$keyring_ok" = "1" ]; then printf 'ghp_FAKEKEYRINGTOKEN\n'; exit 0; else exit 1; fi
fi
[ "\${1:-}" = "api" ] || { echo "unexpected gh command: \$*" >&2; exit 99; }
shift
[ "\${1:-}" = "--paginate" ] && shift
ep=\${1:-}
case "\$ep" in
  repos/owner/repo/pulls/999)                   printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)            printf '%s\n' "\$now" ;;
  repos/owner/repo/issues/999/timeline)         printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)           printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)          printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions)        printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)         printf '[]\n' ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*)           printf '%s\n' "\$now" ;;
  *) echo "unexpected gh api endpoint: \$ep" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s\n' "$dir"
}

# Run the script (--trigger-only so a successful post exits 0 without polling).
# $2 = "unset" | "set": whether GH_TOKEN is exported. OP_PREFLIGHT_* are always
# unset so no fresh cache exists (preflight-helpers.sh is not copied into the
# case, so the auto-source is a no-op anyway). Echoes the exit code.
run() {
  local dir=$1
  local token_mode=$2
  local rc=0
  (
    cd "$dir"
    if [ "$token_mode" = "set" ]; then
      env -u OP_PREFLIGHT_AUTHOR_PAT -u OP_PREFLIGHT_REVIEWER_PAT \
        PATH="$dir/bin:$PATH" GH_TOKEN="preset-token" \
        CODEX_TEST_STATE_DIR="$dir/state" \
        ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    else
      env -u GH_TOKEN -u OP_PREFLIGHT_AUTHOR_PAT -u OP_PREFLIGHT_REVIEWER_PAT \
        PATH="$dir/bin:$PATH" \
        CODEX_TEST_STATE_DIR="$dir/state" \
        ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    fi
  ) || rc=$?
  printf '%s\n' "$rc"
}

trig_count() { if [ -f "$1/state/trigger-count" ]; then cat "$1/state/trigger-count"; else printf '0\n'; fi; }
keyring_called() { [ -f "$1/state/keyring-called" ] && printf 'yes\n' || printf 'no\n'; }

# A: GH_TOKEN unset + keyring resolves → keyring fallback posts once, exit 0.
# This is the exact case that used to silently exit 3 without posting.
test_keyring_fallback_posts() {
  local dir rc before=$FAIL
  dir=$(make_case "keyring-ok" 1)
  rc=$(run "$dir" unset)
  [ "$rc" = "0" ] || fail "A: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "A: expected exactly 1 @codex post, got $(trig_count "$dir")"
  [ "$(keyring_called "$dir")" = "yes" ] || fail "A: keyring token was not consulted"
  [ "$(jq -r '.trigger_posted' "$dir/out.json")" = "true" ] || fail "A: trigger_posted != true"
  grep -q "gh keyring" "$dir/err.log" || fail "A: missing keyring-resolution log line"
  [ "$FAIL" -ne "$before" ] || pass "A: GH_TOKEN unset + keyring resolves → author token from keyring, trigger posted (was the silent exit-3 no-op)"
}

# B: GH_TOKEN unset + keyring empty → FAIL LOUD (exit 3, 0 posts, #737 banner).
test_no_token_fails_loud() {
  local dir rc before=$FAIL
  dir=$(make_case "keyring-empty" 0)
  rc=$(run "$dir" unset)
  [ "$rc" = "3" ] || fail "B: expected exit 3, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "B: expected 0 posts, got $(trig_count "$dir")"
  grep -q "NOT posted" "$dir/err.log" || fail "B: missing loud 'NOT posted' banner"
  grep -q "#737" "$dir/err.log" || fail "B: missing #737 marker in the failure banner"
  [ "$FAIL" -ne "$before" ] || pass "B: GH_TOKEN unset + keyring empty → fails loud (exit 3, no silent no-op)"
}

# C: GH_TOKEN already set → keyring branch is NEVER consulted (backward compat),
# trigger still posts once through gh-as-author.sh.
test_preset_token_skips_keyring() {
  local dir rc before=$FAIL
  dir=$(make_case "preset-set" 1)
  rc=$(run "$dir" set)
  [ "$rc" = "0" ] || fail "C: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "C: expected exactly 1 @codex post, got $(trig_count "$dir")"
  [ "$(keyring_called "$dir")" = "no" ] || fail "C: keyring was consulted despite a preset GH_TOKEN (backward-compat break)"
  [ "$FAIL" -ne "$before" ] || pass "C: preset GH_TOKEN → keyring fallback not consulted, trigger posted (backward compat)"
}

test_keyring_fallback_posts
test_no_token_fails_loud
test_preset_token_skips_keyring

echo "----"
echo "test_codex_review_request_token_fallback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
