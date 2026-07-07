#!/usr/bin/env bash
# tests/test_codex_usage_limit_marker.sh
#
# Regression coverage for Codex App account-/connection-level failure-marker
# detection (#722):
#
#   - scripts/lib/codex-failure-markers.sh — the shared usage-limit /
#     not-connected regexes + codex_failure_marker_of() classifier, factored
#     out of scripts/audit-codex-latency.sh so the live Phase 4a scripts test
#     the IDENTICAL patterns instead of drifting (proposal 1).
#   - scripts/codex-review-request.sh — scan_codex_state's `blocked` signal
#     and the poll-loop short-circuit that turns a quota/not-connected comment
#     into an immediate exit-4 (FALLBACK_REQUIRED) with a named
#     `blocked_reason` instead of a full-timeout wait (proposals 2–4).
#   - scripts/codex-review-check.sh — the gate (c) diagnostic that names the
#     block in its failure message.
#
# The regexes match against the REAL Codex quota / not-connected comment
# wording quoted in #722; the inline jq filters below are kept literal and
# marked KEEP IN SYNC with the scripts, the same pattern
# test_codex_review_request_verdict.sh uses.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/codex-failure-markers.sh"
REQUEST="$ROOT/scripts/codex-review-request.sh"
CHECK="$ROOT/scripts/codex-review-check.sh"
# audit-codex-latency.sh is HUB-ONLY (not propagated); on a consumer checkout
# it is absent, so it is required conditionally (§6 skips when it is missing).
AUDIT="$ROOT/scripts/audit-codex-latency.sh"
for f in "$LIB" "$REQUEST" "$CHECK"; do
  [ -r "$f" ] || { echo "missing $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The verbatim comment bodies from #722 (quota) and the #570 not-connected
# class, so the patterns are pinned against the wording they must catch.
QUOTA_BODY='You have reached your Codex usage limits for code reviews. You can see your limits in the Codex usage dashboard. To continue using code reviews, you can upgrade your account or add credits to your account and enable them for code reviews in your settings.'
NOT_CONNECTED_BODY='To use Codex here, create a Codex account and connect to GitHub, then comment @codex review.'
CLEAN_VERDICT_BODY='Codex Review: Didn'"'"'t find any major issues. Swish!
Reviewed commit: d05ff4d0'

# ── 1. Lib: the shared classifier + constants ───────────────────────────────
# shellcheck source=../scripts/lib/codex-failure-markers.sh
. "$LIB"

[ -n "${CODEX_USAGE_LIMIT_MARKER_RE:-}" ] \
  && pass "lib defines CODEX_USAGE_LIMIT_MARKER_RE" \
  || fail "lib does not define CODEX_USAGE_LIMIT_MARKER_RE"
[ -n "${CODEX_NOT_CONNECTED_MARKER_RE:-}" ] \
  && pass "lib defines CODEX_NOT_CONNECTED_MARKER_RE" \
  || fail "lib does not define CODEX_NOT_CONNECTED_MARKER_RE"

# The stored patterns must be free of a leading (?i) inline flag — callers
# apply "i" explicitly, which is what lets jq and grep share the one literal.
case "$CODEX_USAGE_LIMIT_MARKER_RE" in
  '(?i)'*) fail "usage-limit pattern must not carry a leading (?i) flag" ;;
  *) pass "usage-limit pattern is flag-free (callers apply case-insensitivity)" ;;
esac

marker_of() { codex_failure_marker_of "$1"; }
[ "$(marker_of "$QUOTA_BODY")" = "usage_limit" ] \
  && pass "classifier: real quota comment → usage_limit" \
  || fail "classifier: quota comment misclassified as '$(marker_of "$QUOTA_BODY")'"
[ "$(marker_of "$NOT_CONNECTED_BODY")" = "not_connected" ] \
  && pass "classifier: real not-connected comment → not_connected" \
  || fail "classifier: not-connected comment misclassified as '$(marker_of "$NOT_CONNECTED_BODY")'"
[ -z "$(marker_of "$CLEAN_VERDICT_BODY")" ] \
  && pass "classifier: a clean verdict body carries no marker" \
  || fail "classifier: clean verdict body wrongly flagged as '$(marker_of "$CLEAN_VERDICT_BODY")'"
[ -z "$(marker_of 'Codex Review: Found 2 issues to address.')" ] \
  && pass "classifier: an ordinary findings verdict carries no marker" \
  || fail "classifier: findings verdict wrongly flagged"

# ── 2. The `blocked` jq filter from scan_codex_state (codex-review-request.sh).
#      KEEP IN SYNC with the `blocked=$(echo "$issue_comments" | jq -c ...)`
#      filter. Selects the LATEST non-verdict bot comment matching a marker,
#      usage_limit before not_connected.
BOT="chatgpt-codex-connector[bot]"
BLOCKED_FILTER='
      [ .[]
        | select(.user.login == $bot)
        | select(((.body // "") | test("(?im)^\\s*codex review:")) | not)
        | ( if ((.body // "") | test($usage_re; "i")) then "usage_limit"
            elif ((.body // "") | test($nc_re; "i")) then "not_connected"
            else null end ) as $reason
        | select($reason != null)
        | { reason: $reason, created_at: .created_at, comment_id: .id }
      ]
      | max_by(.created_at) // null'

mk() { jq -n --arg login "$1" --arg body "$2" --arg t "$3" --argjson id "$4" \
  '[{user:{login:$login},body:$body,created_at:$t,id:$id}]'; }
run_blocked() {
  printf '%s' "$1" | jq -c --arg bot "$BOT" \
    --arg usage_re "$CODEX_USAGE_LIMIT_MARKER_RE" \
    --arg nc_re "$CODEX_NOT_CONNECTED_MARKER_RE" "$BLOCKED_FILTER"
}
check_blocked() { # desc expected fixture
  local desc="$1" expected="$2" got
  got="$(run_blocked "$3")"
  if [ "$got" = "$expected" ]; then pass "blocked filter: $desc"; else fail "blocked filter: $desc — expected '$expected', got '$got'"; fi
}

check_blocked "quota comment → usage_limit" \
  '{"reason":"usage_limit","created_at":"2026-07-07T01:10:19Z","comment_id":900}' \
  "$(mk "$BOT" "$QUOTA_BODY" "2026-07-07T01:10:19Z" 900)"
check_blocked "not-connected comment → not_connected" \
  '{"reason":"not_connected","created_at":"2026-07-07T01:10:19Z","comment_id":901}' \
  "$(mk "$BOT" "$NOT_CONNECTED_BODY" "2026-07-07T01:10:19Z" 901)"
check_blocked "a real verdict is NOT a marker (precedence: verdict first)" \
  "null" \
  "$(mk "$BOT" "$CLEAN_VERDICT_BODY" "2026-07-07T01:10:19Z" 902)"
check_blocked "a non-bot comment quoting the quota text is ignored" \
  "null" \
  "$(mk "nathanjohnpayne" "$QUOTA_BODY" "2026-07-07T01:10:19Z" 903)"
# Latest-wins: an older not_connected superseded by a newer usage_limit.
older_nc="$(mk "$BOT" "$NOT_CONNECTED_BODY" "2026-07-07T01:00:00Z" 904)"
newer_ul="$(mk "$BOT" "$QUOTA_BODY" "2026-07-07T02:00:00Z" 905)"
check_blocked "newest marker wins (usage_limit @ 02:00 over not_connected @ 01:00)" \
  '{"reason":"usage_limit","created_at":"2026-07-07T02:00:00Z","comment_id":905}' \
  "$(jq -s 'add' <(printf '%s' "$older_nc") <(printf '%s' "$newer_ul"))"

# ── 3. current_blocked_reason's post-trigger anchoring (codex-review-request.sh).
#      KEEP IN SYNC with the TRIGGER_POSTED=true branch of current_blocked_reason.
ANCHOR_FILTER='if (.blocked != null and .blocked.created_at >= $after) then .blocked.reason else "" end'
anchor() { printf '%s' "$1" | jq -r --arg after "$2" "$ANCHOR_FILTER"; }
ca() { # desc expected scan after
  local got; got="$(anchor "$2" "$3")"
  if [ "$got" = "$1" ]; then pass "anchor: $4"; else fail "anchor: $4 — expected '$1' got '$got'"; fi
}
ca "usage_limit" '{"blocked":{"reason":"usage_limit","created_at":"2026-07-07T01:10:19Z"}}' "2026-07-07T01:08:39Z" "post-trigger marker (>= threshold) surfaces"
ca "" '{"blocked":{"reason":"usage_limit","created_at":"2026-07-07T01:00:00Z"}}' "2026-07-07T01:08:39Z" "pre-trigger (stale) marker is ignored"
ca "" '{"blocked":null}' "2026-07-07T01:08:39Z" "no marker → empty"

# ── 4. Structural: codex-review-request.sh short-circuits + emits blocked_reason.
if grep -q 'current_blocked_reason()' "$REQUEST" \
   && grep -q 'BLOCKED_REASON_NOW=\$(current_blocked_reason "\$FINAL_SCAN")' "$REQUEST" \
   && grep -q 'blocked_reason:' "$REQUEST" \
   && grep -q '#722' "$REQUEST"; then
  pass "codex-review-request.sh short-circuits on a marker and emits blocked_reason (#722)"
else
  fail "codex-review-request.sh is missing the marker short-circuit / blocked_reason emission"
fi

# The short-circuit must live in the poll loop BEFORE the deadline check, so a
# marker ends the wait immediately rather than after the full timeout.
SHORTCIRCUIT_LN=$(grep -n 'BLOCKED_REASON_NOW=\$(current_blocked_reason "\$FINAL_SCAN")' "$REQUEST" | head -1 | cut -d: -f1)
DEADLINE_LN=$(grep -n 'if \[ "\$NOW" -ge "\$DEADLINE" \]; then' "$REQUEST" | head -1 | cut -d: -f1)
if [ -n "$SHORTCIRCUIT_LN" ] && [ -n "$DEADLINE_LN" ] && [ "$SHORTCIRCUIT_LN" -lt "$DEADLINE_LN" ]; then
  pass "marker short-circuit (line $SHORTCIRCUIT_LN) precedes the poll-loop deadline check (line $DEADLINE_LN)"
else
  fail "marker short-circuit is not positioned before the poll-loop deadline check (short-circuit=$SHORTCIRCUIT_LN deadline=$DEADLINE_LN)"
fi

# ── 5. Structural: codex-review-check.sh names the block in its gate (c) message.
if grep -q 'CODEX_BLOCKED_REASON' "$CHECK" \
   && grep -q 'BLOCKED_SUFFIX' "$CHECK" \
   && grep -q 'codex-failure-markers.sh' "$CHECK" \
   && grep -q '#722' "$CHECK"; then
  pass "codex-review-check.sh surfaces the block reason in gate (c) diagnostics (#722)"
else
  fail "codex-review-check.sh is missing the gate (c) block diagnostic"
fi

# ── 6. Drift guard: the audit sources the SAME lib (proposal 1). HUB-ONLY —
#      audit-codex-latency.sh is not propagated, so skip when absent (a
#      consumer checkout, e.g. the check_repo_lint_consumer_safety fixture).
if [ ! -r "$AUDIT" ]; then
  pass "audit drift guard: SKIP (hub-only audit-codex-latency.sh absent — consumer checkout)"
else
  if grep -q 'codex-failure-markers.sh' "$AUDIT" \
     && grep -q 'test(\$rate_re; "i")' "$AUDIT" \
     && grep -q 'test(\$nc_re; "i")' "$AUDIT"; then
    pass "audit-codex-latency.sh sources the shared lib (no pattern drift)"
  else
    fail "audit-codex-latency.sh does not use the shared marker lib"
  fi

  # The audit must NOT still carry the old inline literal patterns (proving the
  # refactor actually removed the duplication).
  if grep -q '(?i)(rate.?limit' "$AUDIT" || grep -q '(?i)to use codex here' "$AUDIT"; then
    fail "audit-codex-latency.sh still carries an inline marker literal (drift risk)"
  else
    pass "audit-codex-latency.sh no longer carries the inline marker literals"
  fi
fi

# ── 7. End-to-end: the real script short-circuits a blocked round to exit 4
#      with blocked_reason set, instead of running out the review timeout.
#      Runs codex-review-request.sh from a temp repo with stubbed gh +
#      gh-as-author (no GitHub network), modeled on
#      tests/test_codex_review_request_trigger_only.sh.
E2E_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-blocked-e2e.XXXXXX")"
trap 'rm -rf "$E2E_WORKDIR"' EXIT

# Build a temp repo whose stubbed gh returns a bot marker comment (created
# after the trigger). $1 = marker body → drives usage_limit vs not_connected.
run_blocked_e2e() { # marker_body → prints "rc|blocked_reason|elapsed"
  local body="$1" dir="$E2E_WORKDIR/case.$RANDOM" rc=0 start elapsed
  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin"
  cp "$REQUEST" "$dir/scripts/codex-review-request.sh"; chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$LIB" "$dir/scripts/lib/codex-failure-markers.sh"
  cat >"$dir/.github/review-policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  review_timeout_seconds: 120
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: 0
  max_ack_retries: 1
EOF
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'https://github.com/owner/repo/pull/999#issuecomment-1001\n'
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
bot='chatgpt-codex-connector[bot]'
t0='2026-07-07T01:08:39Z'
t1='2026-07-07T01:10:19Z'
[ "\${1:-}" = "api" ] || { echo "unexpected gh command: \$*" >&2; exit 99; }
shift
[ "\${1:-}" = "--paginate" ] && shift
endpoint=\${1:-}
case "\$endpoint" in
  repos/owner/repo/pulls/999)            printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)     printf '%s\n' "\$t0" ;;
  repos/owner/repo/issues/999/timeline)  printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)    printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)   printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/1001) printf '%s\n' "\$t0" ;;
  repos/owner/repo/issues/comments/1001/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    jq -cn --arg bot "\$bot" --arg t "\$t1" --arg body "$body" \
      '[{id:8001,user:{login:\$bot},created_at:\$t,body:\$body}]' ;;
  *) echo "unexpected gh api endpoint: \$endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  start=$(date +%s)
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      ./scripts/codex-review-request.sh 999 owner/repo >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  printf '%s|%s|%s' "$rc" "$(jq -r '.blocked_reason // "null"' "$dir/out.json" 2>/dev/null)" "$elapsed"
}

check_e2e() { # desc marker_body expected_reason
  local desc="$1" res rc reason elapsed
  res=$(run_blocked_e2e "$2")
  rc=${res%%|*}; reason=$(echo "$res" | cut -d'|' -f2); elapsed=${res##*|}
  if [ "$rc" = "4" ] && [ "$reason" = "$3" ] && [ "$elapsed" -lt 60 ]; then
    pass "e2e: $desc → exit 4, blocked_reason=$reason, short-circuited in ${elapsed}s"
  else
    fail "e2e: $desc → rc=$rc reason=$reason elapsed=${elapsed}s (want rc=4 reason=$3 elapsed<60)"
  fi
}

check_e2e "quota comment short-circuits to Phase 4b" \
  'You have reached your Codex usage limits for code reviews. You can upgrade your account or add credits.' \
  "usage_limit"
check_e2e "not-connected comment short-circuits to Phase 4b" \
  'To use Codex here, connect your GitHub account at chatgpt.com.' \
  "not_connected"

echo ""
echo "test_codex_usage_limit_marker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
