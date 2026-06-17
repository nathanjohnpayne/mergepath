#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's Phase 4a entry
# decision (#486): codex.request_by_default + codex.enabled gating of
# whether an `@codex review` trigger is posted at all.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so
# the tests exercise the production entry-gate without touching GitHub.
# The skip cases (exit 5) short-circuit BEFORE any gh call, so the stubs
# only matter on the trigger-posting cases.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-entry.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
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

  mkdir -p "$dir/scripts" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"

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

  # gh-as-author records each trigger post (proves a trigger was sent).
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
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
now='2026-06-17T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
[ "${1:-}" = "--paginate" ] && shift
endpoint=${1:-}
case "$endpoint" in
  repos/owner/repo/pulls/999)                printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)         printf '%s\n' "$now" ;;
  repos/owner/repo/issues/999/timeline)      printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)        printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)       printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions)     printf '[]\n' ;;
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
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="test-token" \
      CODEX_TEST_STATE_DIR="$dir/state" \
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

# --- defaults: absent keys ⇒ request on every PR (backward compat) ----------
test_defaults_request_on_every_pr() {
  local dir rc count requested
  dir=$(make_case "defaults" "  bot_login: \"chatgpt-codex-connector[bot]\"")
  rc=$(run_case "$dir")
  count=$(trigger_count "$dir")
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  if [ "$rc" != "4" ]; then
    fail "defaults: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "defaults: trigger count $count, expected 1"
  elif [ "$requested" != "true" ]; then
    fail "defaults: trigger_requested=$requested, expected true"
  else
    pass "absent enabled/request_by_default ⇒ trigger posted on every PR"
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
  local dir rc count requested head
  dir=$(make_case "rbd-false" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  head=$(jq -r '.head_sha' "$dir/out.json")
  if [ "$rc" != "5" ]; then
    fail "rbd false ungated: exit $rc, expected 5 (NO_TRIGGER_REQUESTED); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "rbd false ungated: trigger count $count, expected 0 (no trigger)"
  elif [ "$requested" != "false" ]; then
    fail "rbd false ungated: trigger_requested=$requested, expected false"
  elif [ "$head" != "null" ]; then
    fail "rbd false ungated: head_sha=$head, expected null (skipped before PR fetch)"
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

test_defaults_request_on_every_pr
test_request_by_default_true_triggers_under_threshold
test_single_quoted_booleans_trigger_under_threshold
test_request_by_default_false_skips_under_threshold
test_request_by_default_false_triggers_when_gated
test_enabled_false_never_triggers

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
